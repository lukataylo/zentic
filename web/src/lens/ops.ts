import { resolveFingerprint } from "./fingerprint.js";
import { HarvestStore, LENS_NODE_ATTR, buildInsertion, harvestItems } from "./harvest.js";
import {
  coversPageByShape,
  safeItemSelector,
  safeRegionSelector,
  withoutControlChars,
} from "./selectors.js";
import { cssPath } from "../skeleton.js";
import type {
  ItemPredicate,
  Lens,
  LensOp,
  LensOpResult,
  LensRegion,
  LensReport,
  RegionStyle,
  SortSpec,
} from "../wire.js";

// The op runner: two phases, because one of them has to happen before paint.
//
// ## Why the split
//
// A lens that hides the suggestions rail must hide it *before* the user sees it,
// and that means committing to the effect at `document-start`, when there is no
// DOM to query. So everything expressible as CSS — `hide`, `keep`, `width`,
// `restyle` — compiles to a stylesheet with no DOM access at all, and gets
// injected first. Everything that has to touch nodes — `move`, `reorder`,
// `filter`, `label`, `harvest`, `insert` — runs after DOM ready.
//
// The sheet is written against **one** selector per region: the first candidate
// that resolves against the live DOM, and the region's preferred anchor when
// there is no DOM yet. Naming every candidate at once used to look free — a
// selector that matches nothing is inert — but `regions.ts` ships bare landmark
// tags as alternates, so `["#related", "aside"]` compiled to a rule that hid
// every `<aside>` on the page while the report said one element matched.
//
// The union survived that as a special case, restricted to candidates that all
// resolved to one and the same single element. Which is a no-op, provably: when
// every candidate names exactly the same one element, `a,b,c` selects precisely
// what `a` selects. It could not widen a rule and it could not narrow one, and it
// cost a scan of every candidate on every compile to arrive back where it
// started. One selector, the one the report will name in `usedSelector`, which is
// what makes the report true of the sheet.
//
// At `document-start` nothing resolves yet, so the preferred anchor is used
// alone: under-hiding for a few milliseconds is a flash, over-hiding is a page
// with its content missing. `runPass()` recompiles once the DOM exists and the
// sheet converges on whichever anchor is actually holding the lens together.
//
// ## The one selector that is not the lens's own
//
// A best-first list degrades gracefully only when a stale anchor matches
// *nothing*. Measured across five live sites, the preferred anchor is a
// structural path or a build hash on four of them, and those keep matching after
// a redesign — a *different* element. So the failure that actually happens is a
// lens quietly hiding or restyling the wrong box and reporting `applied`.
//
// `RegionResolver.rescue` is the answer: when no candidate names exactly one
// element, the region's stored fingerprint is scored against the page, and either
// it recognises one element or — far more often, and by design — it declines and
// the op reports `missed`. When it does recognise one, the sheet is written
// against a path minted from *that* element, because every anchor the lens
// carries now names something else. The report leaves `usedSelector` unset and
// says the region was found by structure. See `fingerprint.ts` and `DRIFTED`.
//
// ## Why the structural pass still reports on CSS ops
//
// A stylesheet cannot tell you whether it matched anything, and "did this lens
// still find the thing it was written against" is the single most useful fact the
// UI has. So the structural pass resolves every op's selectors — including the
// ones it does not execute — purely to produce an accurate `LensOpResult`. That
// is where drift is detected, and `missed` is only trustworthy because the check
// happens against the live DOM rather than against the sheet we hoped would bite.
//
// ## Why nothing here throws
//
// A lens is a saved artefact that outlives the page it was written for. Ops go
// stale, sites rename things, a hand-edited `Lenses.json` can hold anything. So
// each op is wrapped: it either does its work or reports `failed`, and either way
// the next op still runs and the page is still a page. One bad op must never be
// able to take the other nine with it.

/** The one stylesheet a page ever gets from us. `clear()` removes it by id. */
export const LENS_STYLE_ID = "zentic-lens-style";

/** Marks an item a `filter` op is hiding. An attribute rather than an inline
 * style so undo is exact — remove the attribute and the site's own `style`
 * attribute is untouched, byte for byte. */
export const LENS_HIDDEN_ATTR = "data-zentic-lens-hidden";

/**
 * Marks an item a `filter` op has already judged this page load.
 *
 * `LENS_HIDDEN_ATTR` cannot carry this: an item the filter decided to *show* has
 * the attribute removed, so "shown" and "never looked at" are the same DOM. The
 * distinction is what keeps an infinite feed working — once a feed passes the
 * per-pass item budget, the window has to prefer cards nothing has judged yet or
 * every later pass re-decides the same first four hundred and new cards are never
 * filtered at all. Removed by undo along with everything else we write.
 */
export const LENS_ITEM_ATTR = "data-zentic-lens-item";

export interface OpBudget {
  /** `Budget.lensOpPassCeiling`. */
  passCeilingMs: number;
  /** `Budget.lensMaxItemsPerPass`. */
  maxItemsPerPass: number;
  /** `Budget.lensMaxOpsPerLens`. */
  maxOpsPerLens: number;
}

export const DEFAULT_OP_BUDGET: OpBudget = {
  passCeilingMs: 120,
  maxItemsPerPass: 400,
  maxOpsPerLens: 40,
};

// MARK: - Token validation

/** `#rrggbb` and nothing else — the shape check *is* the defence. */
function safeColour(value: string | undefined): string | undefined {
  if (typeof value !== "string") return undefined;
  return /^#[0-9a-fA-F]{6}$/.test(value) ? value.toLowerCase() : undefined;
}

function clamp(value: number, low: number, high: number): number {
  if (!Number.isFinite(value)) return low;
  return Math.min(Math.max(value, low), high);
}

/** Prose bound for a text node we insert: capped, and stripped of anything that
 * could disturb the layout it is labelling. */
function safeText(value: string | undefined, limit = 120): string {
  if (typeof value !== "string") return "";
  return withoutControlChars(value).trim().slice(0, limit);
}

/** A harvest bucket name. Mirrors Swift's `LensToken.identifier`: buckets are
 * only ever compared to each other, so the alphabet can be tiny — and a name
 * that is not in it names nothing, which is a `missed`, not a repair. */
function safeBucket(value: string | undefined): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.length > 48) return undefined;
  return /^[A-Za-z0-9_-]+$/.test(trimmed) ? trimmed : undefined;
}

// MARK: - Planning

interface PlannedOp {
  lens: Lens;
  op: LensOp;
  /** Set when the lens is over its op budget, which is the only reason an op is
   * dropped before it is tried. Carries the sentence the UI shows. */
  skip?: string;
  /** Set when the op cannot run at all — today, only a harvest whose bucket a
   * later harvest also claims. Reported `failed`, because it is the lens asking
   * for something incoherent rather than us doing less on purpose. */
  fail?: string;
  /** Whether the compile put a rule in the sheet for this op. `undefined` for a
   * structural op, which has nothing to do with the sheet either way. Consulted
   * by the pass so a `keep` that compiled to nothing cannot report `applied`. */
  emitted?: boolean;
}

function describe(lens: Lens, op: LensOp): string {
  const note = safeText(op.note, 80);
  return note ? `"${note}" in lens "${lens.name}"` : `${op.kind} in lens "${lens.name}"`;
}

/**
 * Flatten the active lenses into the op sequence that will actually run.
 *
 * Lens order then op order, and every op runs. There used to be an arbitration
 * model here — a conflict class per kind, a key per region, a second pass that
 * asked the DOM whether two differently-named regions had landed on one element
 * — and it existed to decide which of two clashing ops the user would see. The
 * browser already decides that, in public, by the specificity of the selectors
 * involved and by the order the nodes end up in. Two `hide` rules on one box both
 * reach the cascade and the box is hidden; two structural ops both run and DOM
 * order settles it. Arbitrating on top of that was answering a question twice,
 * and the second answer is how an op came to be reported `skipped` by a rule the
 * page had never applied.
 *
 * One thing the cascade cannot decide, so it stays: two harvests into one bucket.
 * `HarvestStore` is a single store keyed by bucket name, so `posts` is one slot
 * and two lenses filling it are two answers to one question — a data-integrity
 * rule rather than a precedence one. See `claimBuckets`.
 *
 * The plan is shared by both phases, so the stylesheet and the report are built
 * from the same list of ops. Deciding twice, separately, is how a rule in the
 * sheet comes to belong to an op the report says never ran.
 */
function planOps(lenses: Lens[], budget: OpBudget): PlannedOp[] {
  const planned: PlannedOp[] = [];

  for (const lens of lenses) {
    for (const [index, op] of lens.ops.entries()) {
      if (index >= budget.maxOpsPerLens) {
        planned.push({
          lens,
          op,
          skip: `over the ${budget.maxOpsPerLens}-op budget for one lens`,
        });
        continue;
      }
      planned.push({ lens, op });
    }
  }

  claimBuckets(planned);
  return planned;
}

/**
 * One harvest per bucket, page-wide.
 *
 * Every other kind of clash is left to the browser, because every other kind of
 * clash is about a *page*: two rules on one element, two moves of one node, and
 * the cascade and DOM order are the public, inspectable answer. A bucket is not
 * on the page. It is a key in `HarvestStore`, there is exactly one store for the
 * whole page, and `put` overwrites — so two lenses harvesting into `posts` do not
 * stack, they clobber. Whichever ran last is what every `insert` reading `posts`
 * renders, including the `insert` that belongs to the other lens.
 *
 * Left alone, the loser reported `applied` with a count of the items it read,
 * while nothing it read was on the page. That is invariant 8 exactly: a number
 * that is true of the function and false of what the user is looking at. So the
 * later harvest keeps the bucket — same "the lens you edited most recently wins"
 * rule the stack has everywhere else — and the earlier one says whose bucket it
 * is now, which is a sentence the user can act on by renaming one of them.
 *
 * Needs no document: a bucket name is a string in the lens, so this is decided
 * identically at `document-start` and on every later pass.
 */
function claimBuckets(planned: PlannedOp[]): void {
  const winner = new Map<string, PlannedOp>();

  // Backwards, so the first time a bucket is seen is the harvest that keeps it.
  for (let index = planned.length - 1; index >= 0; index -= 1) {
    const entry = planned[index];
    if (!entry || entry.skip || entry.op.kind !== "harvest") continue;

    // An unusable name is not a collision — `applyHarvest` fails it on its own
    // terms, and two ops that both name nothing are not both naming one bucket.
    const bucket = safeBucket(entry.op.harvest?.into);
    if (!bucket) continue;

    const held = winner.get(bucket);
    if (!held) {
      winner.set(bucket, entry);
      continue;
    }
    entry.fail = `${describe(held.lens, held.op)} harvests into "${bucket}" as well`;
  }
}

// MARK: - Phase one: the stylesheet

const PREAMBLE = [
  // Set by `filter`. `!important` because a feed's own rules are specific and we
  // are hiding one of its own children with an attribute it has never heard of.
  `[${LENS_HIDDEN_ATTR}]{display:none!important}`,
  // Custom elements are inline by default, which would put a harvested list on
  // one line. This is the only styling our own nodes get: the surrounding page
  // owns the design, and a lens is not a theme.
  "zentic-lens-label,zentic-lens-insert,zentic-lens-row{display:block}",
].join("\n");

/**
 * One compile of one lens set: the sheet, the plan, and the resolver that
 * produced both.
 *
 * The sheet half is pure of layout and measurement, which is what makes it safe
 * to run at `document-start` before `document.body` exists. That is the whole
 * point of it — it is what prevents a flash of the un-lensed page, and it is why
 * `hide` is CSS rather than a `display:none` assignment in the structural pass.
 * Nothing here hides the *document*: invariant 1 belongs to the reader, and a
 * lens that could delay a reveal would be trading a guaranteed paint for a
 * cosmetic improvement.
 *
 * All three come back together because the pass that follows needs every one of
 * them, and needs them to be the *same* ones. `runPass()` used to build a
 * resolver for the sheet, throw it away, build a second one inside
 * `runStructuralOps`, and then build a third *per region* for the live watchers —
 * three full sweeps of the same questions, and two of them completed before
 * `passCeilingMs` was so much as read, so the ceiling that is supposed to protect
 * the frame governed about a thirtieth of the work done in it.
 *
 * Sharing the plan matters for correctness rather than only for cost: the compile
 * decides which ops are over budget and which harvest keeps a contested bucket,
 * and a rule in the sheet for an op the report says never ran is exactly the lie
 * this file exists to avoid.
 */
export interface LensPass {
  css: string;
  /** Every op, in application order, carrying the reason it will not run — if it
   * will not — and whether the sheet ended up with a rule for it. */
  plan: PlannedOp[];
  /** The selector cache both halves resolved against. */
  resolver: RegionResolver;
}

/**
 * Compile, and say what was compiled.
 *
 * The `emitted` flag on each planned op is the fix for a specific lie. A `keep`
 * on a descendant selector deliberately compiles to nothing, and a `restyle`
 * carrying an empty `RegionStyle` emits nothing either — but the status was
 * decided by whether the region *resolved*, which it did, so both reported
 * `applied` for an effect that was never in the cascade. The pass now asks the
 * compile rather than guessing, which is the only way the two can agree.
 */
export function compilePass(
  lenses: Lens[],
  budget: OpBudget,
  doc: Document | undefined,
  /** An existing cache to resolve against, when the caller already has one. */
  resolver: RegionResolver = new RegionResolver(doc),
): LensPass {
  const rules: string[] = [PREAMBLE];
  const plan = planOps(lenses, budget);

  for (const entry of plan) {
    const { lens, op, skip, fail } = entry;
    if (skip || fail) continue;

    const region = lens.regions.find((candidate) => candidate.id === op.region);
    const subject = regionSelector(region, resolver);

    switch (op.kind) {
      case "hide":
        entry.emitted = false;
        if (!subject) break;
        rules.push(`${subject}{display:none!important}`);
        entry.emitted = true;
        break;

      case "keep": {
        entry.emitted = false;
        if (!subject) break;
        const kept = keepRule(subject);
        if (!kept || !resolver.keepable(subject, kept.parent)) break;
        rules.push(`${kept.rule}{display:none!important}`);
        entry.emitted = true;
        break;
      }

      case "width": {
        entry.emitted = false;
        if (!subject) break;
        const fraction = clamp(op.fraction ?? 1, 0.1, 1);
        rules.push(
          `${subject}{max-width:${(fraction * 100).toFixed(1)}%!important;` +
            "margin-left:auto!important;margin-right:auto!important}",
        );
        entry.emitted = true;
        break;
      }

      case "restyle": {
        entry.emitted = false;
        if (!subject) break;
        const declarations = compileStyle(op.style);
        if (declarations) {
          rules.push(`${subject}{${declarations}}`);
          entry.emitted = true;
        }
        if (op.style?.hideImages) {
          rules.push(`${subject} img,${subject} picture,${subject} video{display:none!important}`);
          entry.emitted = true;
        }
        break;
      }

      default:
        // Structural. Phase two, and the sheet has nothing to say about it.
        break;
    }
  }

  return { css: rules.join("\n"), plan, resolver };
}

/** Every declaration a `RegionStyle` is allowed to become. Tokens in, CSS out —
 * the model never writes a declaration, which is invariant 5 extended to lenses. */
function compileStyle(style: RegionStyle | undefined): string {
  if (!style) return "";
  const out: string[] = [];

  const background = safeColour(style.background);
  if (background) out.push(`background-color:${background}!important`);

  const foreground = safeColour(style.foreground);
  if (foreground) out.push(`color:${foreground}!important`);

  if (typeof style.fontScale === "number") {
    out.push(`font-size:${clamp(style.fontScale, 0.5, 2).toFixed(2)}em!important`);
  }
  if (typeof style.maxWidthPx === "number") {
    out.push(`max-width:${Math.round(clamp(style.maxWidthPx, 200, 4000))}px!important`);
  }
  if (typeof style.paddingPx === "number") {
    out.push(`padding:${Math.round(clamp(style.paddingPx, 0, 200))}px!important`);
  }
  if (typeof style.radiusPx === "number") {
    out.push(`border-radius:${Math.round(clamp(style.radiusPx, 0, 64))}px!important`);
  }
  if (typeof style.columns === "number") {
    // A grid template, not `column-count`.
    //
    // `column-count` is CSS multicol: it flows *inline content* into columns, and
    // the spec makes it inert on any element that is already a grid or a flex
    // container. Every box a user asks to see in two columns is one of those —
    // a feed, a rail, a card list — so the declaration reached the sheet, changed
    // nothing on any page it was written for, and the op reported `applied`.
    // Invariant 8, arrived at through CSS rather than through a count.
    //
    // `grid-template-columns` says what the token means: put this box's children
    // in N tracks. It works on a block container as well as on one that was
    // already grid or flex, which is why `display` is set alongside it rather
    // than left to whatever the site chose.
    const columns = Math.round(clamp(style.columns, 1, 4));
    out.push("display:grid!important");
    out.push(`grid-template-columns:repeat(${columns},minmax(0,1fr))!important`);
  }

  return out.join(";");
}

/**
 * `parent > *:not(sel)` — hide everything beside the kept region.
 *
 * The parent is not known at compile time, so it has to be expressed from the
 * selector itself, and how depends on the selector's shape:
 *
 *  - **A compound selector** (`#content`, `aside.rail`) has no parent in it, so
 *    `:has(> sel)` *is* the parent: the element with this region as a direct
 *    child. That reads exactly as "in whatever box holds it, hide its siblings".
 *  - **A path** (`body>div:nth-of-type(2)>article`, which is what the catalog
 *    falls back to) already names the parent — everything before the last `>`.
 *    Using `:has()` here would be wrong rather than merely clumsy: `:has(>
 *    body>article)` matches `<html>`, and the rule would hide the page.
 *  - **Anything else** — a descendant combinator, `+`, `~` — has no parent that
 *    can be recovered from the text, so it compiles to nothing. A `keep` that
 *    silently hid the wrong siblings would be a page the user cannot read.
 *
 * The parent comes back beside the rule because it is the thing that has to be
 * checked. There used to be a bare-tag ban right here — `nav`, `aside`, `main`
 * refused outright, on the grounds that `:has(> nav) > *:not(nav)` matches
 * `<body>` and the rule then hides the whole page but the nav. Which is a
 * description of `keep` working: hiding what surrounds the kept box is the op.
 * What the ban was actually standing in for is that a bare tag names *several*
 * boxes in several parents, and it could not see that fact when it was true of a
 * class or an attribute either, nor see `:is(body)` reaching `<html>` by the same
 * route. `RegionResolver.keepable` asks the DOM both questions instead.
 */
function keepRule(selector: string): { parent: string; rule: string } | undefined {
  if (!/[\s+~>]/.test(selector)) {
    const parent = `:has(> ${selector})`;
    return { parent, rule: `${parent} > *:not(${selector})` };
  }

  if (/[\s+~]/.test(selector)) return undefined;

  const cut = selector.lastIndexOf(">");
  const parent = selector.slice(0, cut).trim();
  const last = selector.slice(cut + 1).trim();
  if (!parent || !last) return undefined;
  return { parent, rule: `${parent}>*:not(${last})` };
}

/**
 * How many candidates a region may offer.
 *
 * `regions.ts` derives at most six, best-first, and past the third the marginal
 * anchor is the structural path — so this is a bound on a lens that arrived from
 * somewhere other than our own authoring path rather than on anything we write.
 * Five hundred selectors per region across forty ops builds a multi-megabyte
 * stylesheet, and it rebuilds it on every SPA navigation. The cap is silent
 * because a truncated candidate list still works: the entries that matter are at
 * the front by construction.
 *
 * It bounds the *scan* and not only the result, because validating a candidate
 * runs a `querySelector` — five hundred unusable ones would be paid for in full
 * on every compile, and never produce a selector to show for it.
 */
const MAX_REGION_SELECTORS = 8;

/**
 * The one selector a rule for this region may be written against.
 *
 * The first candidate that resolves, and the region's preferred anchor when
 * nothing does — `document-start`, or a lens that has drifted off this page
 * entirely. It is the same selector the structural pass will name in
 * `usedSelector`, which is what makes the report true of the sheet.
 *
 * With one exception, and it is the reason a fingerprint is stored at all. When
 * no candidate names exactly one element, `resolve` falls through to the
 * fingerprint, and a rescued element is one **no selector on the lens names any
 * more**. The sheet cannot be written against a stale candidate then: the rule
 * would hide whatever that candidate still matches — the impostor a redesign left
 * at the same path — while the report described the box the fingerprint found.
 * So the rule is written against a path minted from the rescued element, for this
 * pass only. The compile and the pass name the same box or the whole mechanism is
 * a louder version of the lie it exists to end.
 */
function regionSelector(
  region: LensRegion | undefined,
  resolver: RegionResolver,
): string | undefined {
  if (!region) return undefined;

  const { resolution, anchor } = resolver.regionMatch(region);

  if (resolution.matchedCount !== 1) {
    const rescued = resolver.rescue(region);
    // `cssPath` is `nth-of-type` all the way down, so it names this element and
    // no other — checked against the page anyway, because a path that somehow
    // reaches `<body>` is a rule over the whole document.
    const minted = rescued ? cssPath(rescued) : "";
    if (minted && !resolver.coversPage(minted)) return minted;
  }

  return resolution.usedSelector ?? anchor;
}

/**
 * One resolution of each selector and each region, shared by the compile and the
 * pass that follows it.
 *
 * Two reasons, and the second is the load-bearing one. Resolving is a
 * whole-document `querySelectorAll` per candidate, and the compile now needs the
 * same answers the structural pass needs. But more than that: the compile writes
 * the rule and the pass writes the report, and both name a `usedSelector`. If the
 * two halves resolved separately they could disagree, and a report naming an
 * anchor the sheet did not use is exactly the lie this file exists to avoid. One
 * cache, one answer.
 *
 * Cached for the life of one pass rather than across passes: the pass moves
 * nodes, but it never removes one, so an element resolved at plan time is the
 * same element when an op reaches it. The next pass gets a new resolver, which is
 * what makes a region the router replaced resolve to the new element.
 */
export class RegionResolver {
  private readonly bySelector = new Map<string, Element[]>();
  private readonly byRegion = new Map<string, Resolution>();
  private readonly byCandidates = new Map<LensRegion, string[]>();
  private readonly byRegionMatch = new Map<LensRegion, RegionMatch>();
  /** `null` is "asked and found nothing", which is a different answer from "not
   * asked yet" — and the common one, so it must not be re-asked per op. */
  private readonly byRescue = new Map<LensRegion, Element | null>();

  constructor(private readonly doc: Document | undefined) {}

  /**
   * A region's candidate selectors, best first, shape-gated and nothing more.
   *
   * Deliberately free of the document. The breadth check that used to happen
   * here is the platform's — a candidate whose match set contains `<html>` or
   * `<body>` names the page rather than a part of it — but asking it of *every*
   * candidate costs a whole-document `querySelectorAll` for each, including all
   * the ones that were never going to be used. It is asked at the point of use
   * instead, of the one candidate that actually resolved, which is both cheaper
   * and no weaker: a selector matching nothing cannot be naming the page.
   */
  candidates(region: LensRegion): string[] {
    const held = this.byCandidates.get(region);
    if (held) return held;

    const out: string[] = [];
    for (const candidate of region.selectors.slice(0, MAX_REGION_SELECTORS)) {
      const safe = safeRegionSelector(candidate);
      if (!safe || out.includes(safe)) continue;
      out.push(safe);
    }
    this.byCandidates.set(region, out);
    return out;
  }

  /**
   * Could this element be this region, judged without touching the document?
   *
   * `Element.matches()` walks one element; `querySelectorAll` walks the page. An
   * observer fires for one region, and answering "which of my regions is this?"
   * by resolving all of them is 480 whole-document sweeps to find one element
   * that is already in hand. Asking each region "could you be this?" first is
   * 480 local tests and then one sweep, for the region that said yes.
   *
   * A screen rather than an answer: `.rail` matching this element does not make
   * this element the region, because an earlier candidate may resolve to a
   * different box entirely. The caller confirms with `resolve`.
   *
   * The fingerprint is the second question because a rescued region matches none
   * of its own selectors — that is what being rescued *means*. Screening on the
   * selectors alone would reject the very element the pass just resolved this
   * region to, so a `filter` on a drifted feed would apply once and then quietly
   * stop working as the user scrolled: applied, badged green, and wrong within a
   * screenful. Second because it is the expensive one, and a region whose anchors
   * still name this element never reaches it.
   */
  couldBe(element: Element, region: LensRegion): boolean {
    const named = this.candidates(region).some((selector) => {
      try {
        return element.matches(selector);
      } catch {
        return false;
      }
    });
    return named || this.rescue(region) === element;
  }

  /** Does this selector's match set contain the page itself? Shape alone before
   * the DOM exists, which is `coversPageByShape`'s whole job. */
  coversPage(selector: string): boolean {
    if (coversPageByShape(selector)) return true;
    const doc = this.doc;
    if (!doc) return false;
    return this.matches(selector).some(
      (element) => element === doc.documentElement || element === doc.body,
    );
  }

  /**
   * May a `keep` rule be written against this subject and the parent it
   * synthesises?
   *
   * `keep` hides what it does not keep, so it is the one op where being right
   * about *how many* boxes are involved is the whole safety story. Two DOM
   * questions, replacing a ban on bare tag names that stood in for both and
   * answered neither:
   *
   *  - **The subject must name exactly one element.** `nav` is a fallback anchor
   *    `regions.ts` really does ship, and a page with a nav in the header and a
   *    nav in the footer makes `:has(> nav)` two parents — each of which loses
   *    every child but its nav. Hiding the siblings of one box the user pointed
   *    at is what `keep` means; doing it to three boxes they did not is a
   *    wrecked page from a legal lens.
   *  - **The parent must not be `<html>`.** `keepRule(":is(body)")` synthesises
   *    `:has(> :is(body))`, which is the document element — so the rule's whole
   *    effect is to hide `<head>`, and the "region" being kept is the page. The
   *    old ban could not see this at all: `:is(body)` is a narrow-looking
   *    compound right up until `:has(> …)` is wrapped around it. `<body>` as the
   *    parent is the ordinary case and stays allowed — "keep only the article"
   *    means exactly "hide body's other children".
   *
   * With no document, the shape check alone, which refuses the `:has(> tag)`
   * spelling because a bare tag is the shape most likely to be the many-parents
   * case and there is nothing here to ask.
   */
  keepable(subject: string, parent: string): boolean {
    const doc = this.doc;
    if (!doc) return !coversPageByShape(parent);
    if (this.matches(subject).length !== 1) return false;
    return !this.matches(parent).includes(doc.documentElement);
  }

  /** Every element a selector currently names. Empty when the engine rejects it
   * — the alternates exist precisely so one unusable candidate costs nothing. */
  matches(selector: string): Element[] {
    const held = this.bySelector.get(selector);
    if (held) return held;

    let found: Element[] = [];
    if (this.doc) {
      try {
        found = Array.from(this.doc.querySelectorAll(selector));
      } catch {
        found = [];
      }
    }
    this.bySelector.set(selector, found);
    return found;
  }

  /**
   * What this region's own selectors say about this page, and nothing else.
   *
   * First candidate that matches anything wins — that ordering is the drift
   * strategy: `#comments` is tried before `div.comment-list` is tried before the
   * structural path, so a site that changes its markup but keeps its ids costs
   * the lens nothing. `usedSelector` comes back so the UI can show *which* anchor
   * is holding the lens together, which is how a user learns a lens is one
   * redesign from breaking.
   *
   * Cached on the region object rather than on `lens.id|regionID`, because it is
   * a fact about the selector list and nothing about which lens is asking.
   * Public because the compile and the pass both need it and must not answer it
   * twice — a rule written against one box and a report naming another is the
   * lie this whole file is arranged to prevent. See `regionSelector`.
   */
  regionMatch(region: LensRegion): RegionMatch {
    const held = this.byRegionMatch.get(region);
    if (held) return held;

    let resolution = MISSED;
    let anchor: string | undefined;

    for (const candidate of this.candidates(region)) {
      const found = this.matches(candidate);
      const element = found[0];
      if (!element) {
        // Nothing for the DOM to be asked about, so shape is the whole gate. Kept
        // as the anchor for `document-start`, where *no* candidate resolves and
        // the region's preferred selector is the honest guess. A candidate that
        // resolves to the page is never kept, which is why this is a running
        // fallback rather than `list[0]`.
        if (!coversPageByShape(candidate)) anchor ??= candidate;
        continue;
      }
      // Asked only of a candidate that resolved to something, and answered from
      // the match set that is already in hand.
      if (this.coversPage(candidate)) continue;
      resolution = { element, matchedCount: found.length, usedSelector: candidate };
      break;
    }

    const match: RegionMatch = { resolution, anchor };
    this.byRegionMatch.set(region, match);
    return match;
  }

  /**
   * The element this region's fingerprint still recognises, when its selectors no
   * longer name it.
   *
   * Asked **only** when no candidate resolved to exactly one element, which is
   * both halves of the drift the selector list cannot survive on its own: a
   * region whose anchors now match nothing, and one whose anchors match several
   * boxes and would otherwise be applied to whichever happens to come first in
   * document order. A candidate that names one element is believed — the lens
   * still fits, and scoring the whole document to agree with it would cost a
   * `getElementsByTagName` sweep per region for no answer.
   *
   * `undefined` is the ordinary answer and the one the mechanism is built around:
   * `resolveFingerprint` declines rather than guessing, and a decline becomes an
   * honest `missed` in the report and an amber badge the user can act on.
   */
  rescue(region: LensRegion): Element | undefined {
    const held = this.byRescue.get(region);
    if (held !== undefined) return held ?? undefined;

    const print = region.fingerprint;
    const doc = this.doc;
    const found =
      // No document at `document-start`, and no fingerprint on a lens written
      // before there were any — both fall back to the selectors alone.
      doc && print && this.regionMatch(region).resolution.matchedCount !== 1
        ? resolveFingerprint(doc, print)
        : undefined;

    this.byRescue.set(region, found ?? null);
    return found;
  }

  /**
   * Find a region in the live DOM: its selectors first, its structure second.
   *
   * `usedSelector` is unset on a rescue, because none of the lens's selectors
   * matched — the element was found by what it *is*, not by what the lens calls
   * it. `drifted` says so out loud, so the op that follows reports a rescue as a
   * rescue instead of as an ordinary hit.
   */
  resolve(lens: Lens, regionID: string): Resolution {
    const key = `${lens.id}|${regionID}`;
    const held = this.byRegion.get(key);
    if (held) return held;

    const resolution = this.lookUp(lens, regionID);
    this.byRegion.set(key, resolution);
    return resolution;
  }

  private lookUp(lens: Lens, regionID: string): Resolution {
    const region = lens.regions.find((entry) => entry.id === regionID);
    if (!region) return MISSED;

    const { resolution } = this.regionMatch(region);
    if (resolution.matchedCount === 1) return resolution;

    const rescued = this.rescue(region);
    if (rescued) {
      return { element: rescued, matchedCount: 1, usedSelector: undefined, drifted: true };
    }

    // Whatever the selectors did say, which is `missed` when they said nothing
    // and `ambiguous` when they named several. A fingerprint that declines must
    // not make a lens *worse* than it was without one.
    return resolution;
  }
}

/** What a region's own selectors currently say about the page. */
interface RegionMatch {
  /** The first candidate that names something that is not the page itself. */
  resolution: Resolution;
  /** The preferred candidate by shape alone, for when nothing resolves — most of
   * all at `document-start`, where nothing can. */
  anchor: string | undefined;
}

const MISSED: Resolution = { element: undefined, matchedCount: 0, usedSelector: undefined };


// MARK: - Undo

interface ChildSnapshot {
  parent: Node;
  children: Node[];
}

/**
 * Everything needed to put the page back exactly as it was found.
 *
 * Structure is restored from *snapshots of child order*, not from per-node
 * "where did this come from" records. A per-node record has to name a sibling to
 * reinsert before, and after a dozen moves the named sibling may itself have
 * moved — so undo would depend on replaying in exactly the right order and would
 * break the first time it did not. A snapshot of a parent's children is a fact
 * about that parent that stays true no matter what happened afterwards.
 *
 * Snapshots are restored back-to-front, walking each list in reverse and
 * inserting before the sibling already restored. That places every original node
 * exactly where it was relative to the others, and leaves anything the *site*
 * added during our pass at the end rather than silently deleting it — we may
 * undo our own edits, never the page's.
 *
 * Attributes are not recorded at all. The only two this engine ever writes are
 * its own, so nothing else can have written them and the undo is always a
 * removal — which a pair of `querySelectorAll` sweeps does exactly, without
 * holding a reference to a single card. See `undo`.
 */
export class LensJournal {
  private readonly snapshots: ChildSnapshot[] = [];
  private readonly snapshotted = new Set<Node>();
  private readonly inserted: Element[] = [];

  constructor(private readonly doc: Document) {}

  /** Record a parent's child order before disturbing it. Idempotent per parent:
   * the *first* snapshot is the original, and later ones would record our own work. */
  snapshotChildren(parent: Node | null | undefined): void {
    if (!parent || this.snapshotted.has(parent)) return;
    this.snapshotted.add(parent);
    this.snapshots.push({ parent, children: Array.from(parent.childNodes) });
  }

  recordInserted(node: Element): void {
    this.inserted.push(node);
  }

  /** Put the page back. Safe to call twice; the second call is a no-op. */
  undo(): void {
    // Our own nodes first, so they are not in the way when child order is
    // restored — and so a snapshot taken before we inserted them stays accurate.
    for (const node of this.inserted.splice(0).reverse()) {
      try {
        node.remove();
      } catch {
        // Already gone, because the site replaced the subtree. Nothing owed.
      }
    }

    // Then our own two attributes, swept off the document rather than replayed
    // from a list.
    //
    // The list was a `{element, name, previous}` record per marked item, and
    // `previous` was structurally always null: the only two attributes ever
    // recorded are ours, so nothing else can have written them and the undo is
    // always a `removeAttribute`. Which left an array of strong element
    // references doing the work of a `querySelectorAll` — and doing it worse,
    // because a strong array is a retention. The WeakMap beside it deduped
    // nothing the array was not already pinning, `rerunLive` re-marks items pass
    // after pass without an undo in between, and a five-thousand-card scroll
    // therefore held every virtualised subtree the feed had ever recycled: tens
    // to hundreds of megabytes, for a page the user is still reading.
    //
    // Two queries against the live document instead. They find exactly the marks
    // that are still on the page, which is the set that matters — a card the site
    // recycled took its attributes with it, and a record of one is a record of
    // nothing.
    for (const name of [LENS_HIDDEN_ATTR, LENS_ITEM_ATTR]) {
      for (const element of Array.from(this.doc.querySelectorAll(`[${name}]`))) {
        element.removeAttribute(name);
      }
    }

    for (const snapshot of this.snapshots.splice(0).reverse()) {
      // A parent the *site* detached after we snapshotted it is not on the page
      // any more, and `insertBefore` into a detached node succeeds silently. So
      // restoring into it would take every child of that snapshot off the page
      // with it — including children that are visible right now, because the site
      // moved them somewhere that survived. That is the failure direction that
      // costs the user content rather than merely leaving it out of place, so the
      // whole snapshot is abandoned and its children stay where they are.
      if (!snapshot.parent.isConnected) continue;

      let cursor: Node | null = null;
      for (let index = snapshot.children.length - 1; index >= 0; index -= 1) {
        const child = snapshot.children[index];
        if (!child) continue;
        // `insertBefore` **re-attaches** a detached node rather than throwing, so
        // the catch below never fires for one the site deleted — it resurrects
        // it. A virtualised feed that recycled six cards would get them back on
        // ⌘\, and a cookie banner the strip layer dismissed would return, undoing
        // work that was not ours to undo. We restore *position*, never existence:
        // a node the page no longer holds is not a node we may put back.
        if (!child.isConnected && !snapshot.parent.contains(child)) continue;
        try {
          snapshot.parent.insertBefore(child, cursor);
          cursor = child;
        } catch {
          // A hierarchy request the DOM refuses — the site reparented this node
          // above its old parent. Keep going: the rest of the order is still
          // restorable, and a partly restored page beats a half-lensed one.
        }
      }
    }

    this.snapshotted.clear();
  }
}

// MARK: - Phase two: structural ops

export interface StructuralOptions {
  budget?: OpBudget;
  /** Where undo information accumulates. One journal per applied lens set. */
  journal?: LensJournal;
  /** Harvest buckets, shared across ops so `insert` can read what `harvest` wrote. */
  harvests?: HarvestStore;
  /** Injectable clock, so a budget test does not have to be slow to be real. */
  now?: () => number;
  /**
   * A compile the caller already made, for the whole of `lenses`.
   *
   * The engine compiles once per pass and uses the sheet from it, so re-compiling
   * here would be a second full sweep of the same questions — and, worse, a
   * second answer: the compile decides which ops are over budget and which
   * harvest keeps a contested bucket, and two independent answers to that is a
   * rule in the sheet for an op the report says never ran.
   */
  pass?: LensPass;
  /**
   * A selector cache to share without sharing a plan.
   *
   * The live path re-runs a *subset* of the ops, so the pass's plan is not the
   * plan it wants — but the resolutions are the same resolutions, and rebuilding
   * them is what made an observer callback cost a whole-document
   * `querySelectorAll` per region per op.
   */
  resolver?: RegionResolver;
  /**
   * When this pass's clock started, if it started before this call.
   *
   * `passCeilingMs` is a promise about a frame, and the frame includes the
   * compile the caller has just paid for. Reading the clock here instead meant
   * the ceiling began after the most expensive part of the pass had already
   * happened.
   */
  startedAt?: number;
}

interface RunContext {
  doc: Document;
  budget: OpBudget;
  journal: LensJournal;
  harvests: HarvestStore;
  resolver: RegionResolver;
  /**
   * How many items the *whole pass* may still touch.
   *
   * Per-pass rather than per-op, because the budget is a promise about frame
   * time and frame time is spent by the pass, not by any one op in it. Twelve
   * watched regions with a filter each used to be twelve times the budget — 4,800
   * items of predicate matching inside a ceiling written for 400.
   */
  items: number;
  /**
   * The share of the pass allowance each item op is guaranteed.
   *
   * A pass allowance spent strictly in plan order is worse than the per-op budget
   * it replaced. `filter(timeline)` followed by `filter(sidebar)` on a page whose
   * timeline is longer than the allowance means the first op takes all of it and
   * the second is skipped — not once, but on every pass for the life of the page,
   * so the sidebar filter never runs at all. And `skipped` is not `missed`, so
   * `LensReport.isDrifted` is false: the badge reads a calm `1/2` and offers no
   * Re-fit. A lens doing half of what it says, with nothing in the UI to say so.
   *
   * So the allowance is reserved rather than consumed first-come. Each item op
   * may take everything left over *after* the floor still owed to the item ops
   * behind it, which means an op that needs little leaves the rest to the others
   * and an op that would eat the lot cannot.
   */
  itemFloor: number;
  /** Item ops in this plan that have not been reached yet. Counts down as the
   * pass walks the plan, so the reservation shrinks as the queue empties. */
  pendingItemOps: number;
}

/** Ops that walk a region's repeated children, and therefore spend the pass's
 * item allowance. The three of them share one budget because they cost the frame
 * the same way — a predicate match and a field read are both per item. */
function isItemOp(op: LensOp): boolean {
  return op.kind === "filter" || op.kind === "reorder" || op.kind === "harvest";
}

/**
 * How many items the op now being applied may touch.
 *
 * Everything left, minus the floor still owed to the item ops behind it — and
 * never less than one floor, so the last op in a plan is as entitled as the
 * first. With one item op that is the whole allowance, which is the common case
 * and the behaviour that was already right.
 *
 * When a plan carries more item ops than the allowance has items (480 ops is
 * reachable: twelve lenses of forty), the floor bottoms out at one and the pass
 * may touch one item per op rather than `maxItemsPerPass` in total. That is the
 * deliberate trade: a pass slightly over an item count is bounded work, and
 * `passCeilingMs` is the ceiling that actually protects the frame — whereas an op
 * permanently allowed zero items is a lens silently not doing its job.
 */
function itemAllowance(context: RunContext): number {
  const reserved = context.pendingItemOps * context.itemFloor;
  return Math.max(context.itemFloor, context.items - reserved);
}

interface Resolution {
  element: Element | undefined;
  matchedCount: number;
  usedSelector: string | undefined;
  /** Found by fingerprint because no selector named it. The effect is real, so
   * the status stays `applied` — but the lens is running on borrowed time and the
   * report has to say so. See `DRIFTED`. */
  drifted?: boolean;
}

function result(
  op: LensOp,
  status: LensOpResult["status"],
  matchedCount: number,
  usedSelector?: string,
  message?: string,
): LensOpResult {
  return {
    opID: op.id,
    status,
    matchedCount,
    ...(usedSelector ? { usedSelector } : {}),
    ...(message ? { message } : {}),
  };
}

/**
 * Run the structural ops and report on every op, structural or not.
 *
 * The pass has a hard ceiling. When it runs out, the current op finishes and
 * every remaining op is reported `skipped` with a budget message — rather than
 * being dropped silently, because a lens that quietly stops halfway looks like a
 * broken site rather than a busy one. A lens must never make a page janky, and
 * the honest way to keep that promise is to do less and say so.
 */
export function runStructuralOps(
  doc: Document,
  lenses: Lens[],
  options: StructuralOptions = {},
): LensReport[] {
  const budget = options.budget ?? DEFAULT_OP_BUDGET;
  const now = options.now ?? (() => performance.now());
  const startedAt = options.startedAt ?? now();

  // What this pass needs from a compile is the *plan* — which ops will not be
  // tried, and which ops the compile could actually write a rule for. Deciding
  // either of those a second time, differently, is how a report comes to describe
  // a page nobody is looking at, so the caller's compile is preferred to one of
  // our own whenever there is one.
  const compiled = options.pass ?? compilePass(lenses, budget, doc, options.resolver);
  const plan = compiled.plan;

  const context: RunContext = {
    doc,
    budget,
    journal: options.journal ?? new LensJournal(doc),
    harvests: options.harvests ?? new HarvestStore(),
    resolver: compiled.resolver,
    items: budget.maxItemsPerPass,
    itemFloor: 1,
    pendingItemOps: 0,
  };

  // The denominator for the item reservation: only ops that will actually be
  // attempted, so an op the plan already ruled out does not hold back a share of
  // the allowance from the ops that survived it.
  context.pendingItemOps = plan.filter(
    (entry) => !entry.skip && !entry.fail && isItemOp(entry.op),
  ).length;
  context.itemFloor = Math.max(
    1,
    Math.floor(budget.maxItemsPerPass / Math.max(1, context.pendingItemOps)),
  );

  const generatedAt = new Date().toISOString();
  const url = currentPath();
  const byLens = new Map<string, LensOpResult[]>();
  for (const lens of lenses) byLens.set(lens.id, []);

  const deadline = startedAt + budget.passCeilingMs;
  let exhausted = false;

  for (const planned of plan) {
    const { lens, op, skip, fail } = planned;
    const results = byLens.get(lens.id);
    if (!results) continue;

    if (skip) {
      results.push(result(op, "skipped", 0, undefined, skip));
      continue;
    }

    if (fail) {
      results.push(result(op, "failed", 0, undefined, fail));
      continue;
    }

    // Claimed as the op is reached rather than as it spends, so an op that misses
    // its region or fails its spec releases its reservation to the ops behind it
    // instead of holding a share of the allowance nothing will ever use.
    if (isItemOp(op)) context.pendingItemOps -= 1;

    if (exhausted || now() > deadline) {
      exhausted = true;
      results.push(
        result(op, "skipped", 0, undefined, `op pass exceeded ${budget.passCeilingMs}ms`),
      );
      continue;
    }

    try {
      results.push(applyOp(context, planned));
    } catch (error) {
      // The last line of defence. Anything an op can throw — a selector jsdom
      // rejects, a hierarchy request error from a move into a descendant — lands
      // here as one `failed` result and nothing else changes.
      results.push(result(op, "failed", 0, undefined, messageOf(error)));
    }
  }

  return lenses.map((lens) => ({
    lensID: lens.id,
    url,
    results: byLens.get(lens.id) ?? [],
    generatedAt,
  }));
}

/**
 * The page a report says a lens ran on — path only, no query, no fragment.
 *
 * A `LensReport` is persisted into `Lenses.json`, so this one string is the only
 * piece of browsing history the feature writes to disk, and the query is where
 * the session tokens, the search terms and the mail message ids live. A path is
 * enough to say which page a lens last ran on. Invariant 7 is about the network,
 * but a file sitting in Application Support deserves the same answer.
 *
 * Exported because `index.ts` writes the same string into a suppressed report and
 * had a second copy of this function to do it — two identical answers to a
 * privacy question is one answer and one place for it to drift.
 */
export function currentPath(): string {
  try {
    return location.pathname;
  } catch {
    return "";
  }
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** What a CSS op reports when its region is right there on the page and the
 * compile still had nothing it could legally write. */
const NO_RULE = "no rule could be compiled for this selector shape";

/**
 * What an op says when its region had to be found by fingerprint.
 *
 * Still `applied`: the element was found and the effect landed on it, and calling
 * that a miss would be its own lie. But it landed on a box no anchor the lens
 * carries can name any more, so the next redesign has nothing left to fall back
 * to. Reported as a rescue rather than as an ordinary hit, because a badge that
 * cannot tell "fits" from "held together by structure" is the same silence this
 * whole mechanism was built to break.
 */
const DRIFTED = "the region's selectors no longer match; the element was found by its structure";

function applyOp(context: RunContext, planned: PlannedOp): LensOpResult {
  const outcome = runOp(context, planned);
  const { lens, op } = planned;

  // Only on an effect. A `missed` or a `failed` already says the lens did not
  // work here, and adding "found by structure" to it would describe a rescue that
  // did not happen.
  if (outcome.status !== "applied" && outcome.status !== "ambiguous") return outcome;
  if (!rescuedRegions(op).some((id) => context.resolver.resolve(lens, id).drifted === true)) {
    return outcome;
  }

  return { ...outcome, message: [DRIFTED, outcome.message].filter(Boolean).join("; ") };
}

/** The regions an op's *effect* actually landed on, so a rescue elsewhere in the
 * lens does not get reported against an op that never touched it. `insert` reads
 * only its destination; its `region` is where the values were harvested, and
 * `harvest`'s own result is where that region is answered for. */
function rescuedRegions(op: LensOp): string[] {
  switch (op.kind) {
    case "insert":
      return op.target ? [op.target] : [];
    case "move":
      return op.target ? [op.region, op.target] : [op.region];
    default:
      return [op.region];
  }
}

function runOp(context: RunContext, planned: PlannedOp): LensOpResult {
  const { lens, op } = planned;
  const target = context.resolver.resolve(lens, op.region);

  switch (op.kind) {
    // Already in the stylesheet — or not, which is the point. Resolved anyway,
    // because that resolution is the only honest source of "does this lens still
    // fit this page"; but resolution alone used to *decide* the status, so a
    // `keep` on a descendant selector and a `restyle` carrying an empty style both
    // reported `applied` for a rule that was never written. The compile is asked
    // instead, so the badge counts effects rather than selectors.
    case "hide":
    case "keep":
    case "width":
    case "restyle": {
      if (!target.element) return result(op, "missed", 0, undefined, missMessage(lens, op.region));
      if (planned.emitted !== true) {
        return result(op, "failed", target.matchedCount, target.usedSelector, NO_RULE);
      }
      // Through `singleStatus` like every other op. This branch used to return a
      // flat `applied`, so `hide` on NYT's `div.jXhsNG_gridCell.jXhsNG_positioned`
      // — the preferred anchor for one box, and a class 160 elements share —
      // removed 160 elements and badged green. A rule is the worst place for that
      // silence: a structural op applies to the first match and leaves the rest,
      // while the cascade hits every one of them.
      return result(
        op,
        singleStatus(target.matchedCount),
        target.matchedCount,
        target.usedSelector,
        ruleAmbiguityMessage(target.matchedCount),
      );
    }

    case "move":
      return applyMove(context, lens, op, target);
    case "reorder":
      return applyReorder(context, op, target);
    case "filter":
      return applyFilter(context, op, target);
    case "label":
      return applyLabel(context, op, target);
    case "harvest":
      return applyHarvest(context, op, target);
    case "insert":
      return applyInsert(context, lens, op);
  }
}

function missMessage(lens: Lens, regionID: string): string {
  const region = lens.regions.find((entry) => entry.id === regionID);
  const intent = region ? safeText(region.intent, 80) : "";
  return intent ? `no match for ${intent}` : `region ${regionID} matched nothing`;
}

/** A single-element op that matched several: apply to the first, and say so, so
 * the UI can offer a tighter selector rather than pretending it was unambiguous. */
function singleStatus(matchedCount: number): "applied" | "ambiguous" {
  return matchedCount > 1 ? "ambiguous" : "applied";
}

function ambiguityMessage(matchedCount: number): string | undefined {
  return matchedCount > 1 ? `${matchedCount} elements matched; applied to the first` : undefined;
}

/** The same thing said honestly about a *rule*. A stylesheet is not applied "to
 * the first": the selector goes into the cascade and every element it names is
 * hidden, widened or restyled. */
function ruleAmbiguityMessage(matchedCount: number): string | undefined {
  return matchedCount > 1
    ? `${matchedCount} elements matched; the rule applies to all of them`
    : undefined;
}

function applyMove(
  context: RunContext,
  lens: Lens,
  op: LensOp,
  source: Resolution,
): LensOpResult {
  if (!source.element) return result(op, "missed", 0, undefined, missMessage(lens, op.region));
  if (!op.target) return result(op, "failed", 0, source.usedSelector, "move without a destination");

  const destination = context.resolver.resolve(lens, op.target);
  if (!destination.element) {
    return result(op, "missed", source.matchedCount, source.usedSelector, missMessage(lens, op.target));
  }

  if (source.element === destination.element || source.element.contains(destination.element)) {
    // Moving a box into itself detaches the destination with it. The DOM would
    // throw; refusing first means the page is never briefly missing a landmark.
    return result(
      op,
      "failed",
      source.matchedCount,
      source.usedSelector,
      "destination is inside the moved region",
    );
  }

  context.journal.snapshotChildren(source.element.parentNode);
  context.journal.snapshotChildren(destination.element);

  const children = Array.from(destination.element.children);
  const index = Math.round(clamp(op.index ?? children.length, 0, children.length));
  destination.element.insertBefore(source.element, children[index] ?? null);

  const matched = Math.max(source.matchedCount, destination.matchedCount);
  return result(
    op,
    singleStatus(matched),
    source.matchedCount,
    source.usedSelector,
    ambiguityMessage(matched),
  );
}

interface ItemRun {
  parent: Element;
  /** The window this pass may touch. */
  items: Element[];
  /** Every repeated child under `parent`, window or not. `op.limit` is a promise
   * about the whole list, so a filter has to know what it left outside. */
  all: Element[];
  truncated: boolean;
}

/**
 * The repeated children an item op works on.
 *
 * Falls back to the region's own element children when the op names no item
 * selector, which is the right default: "sort this list" almost always means the
 * list's own rows, and failing an op for the want of a selector we can derive
 * would be pedantry with a cost.
 *
 * A selector the op *did* name and this side cannot use is the opposite case, and
 * fails the op. Falling back there turns "drop the cards matching X" into "drop
 * everything directly inside this region", which on a `drop` filter empties a
 * feed — A1.2's rule, and the reason `safeItemSelector` refuses a selector list
 * rather than letting one through to be silently unused.
 *
 * Items are constrained to one parent because reordering across parents is not a
 * reorder, it is a rewrite of the page, and because a filter that reaches into a
 * nested feed hides rows the user never saw as part of the list they pointed at.
 *
 * ## Which items, when there are more than the budget allows
 *
 * `slice(0, limit)` from the top is the obvious answer and it freezes the feed.
 * Past the cap, every later pass re-decides the same first four hundred cards and
 * the ones the user just scrolled to are never looked at — while the op still
 * reports `applied`, so a filter that has silently stopped working looks
 * identical to one that is working. An infinite feed is precisely the shape this
 * feature exists for, so the cap has to bite on the *old* items.
 *
 * So a truncated window prefers items no filter has judged yet (`preferUndecided`)
 * and only then tops up with ones it has. The chosen window is put back into
 * document order afterwards, because `op.limit` means "the first ten headlines"
 * and would otherwise mean "ten of them, in the order we happened to pick".
 *
 * `reorder` opts out and keeps the contiguous top of the list. A sort reinserts
 * its items as one block where the block ended; handed a scattered window it
 * would gather rows from all over the feed into one place, which is not a
 * reordering of anything the user pointed at.
 */
function itemRun(
  region: Element,
  op: LensOp,
  limit: number,
  preferUndecided: boolean,
): ItemRun | undefined {
  const named = typeof op.itemSelector === "string" && op.itemSelector.trim().length > 0;
  const selector = safeItemSelector(op.itemSelector);
  if (named && !selector) return undefined;

  let found: Element[];
  if (selector) {
    try {
      found = Array.from(region.querySelectorAll(selector));
    } catch {
      return undefined;
    }
  } else {
    found = Array.from(region.children);
  }

  const first = found[0];
  if (!first) return { parent: region, items: [], all: [], truncated: false };

  const parent = first.parentElement ?? region;
  const sameParent = found.filter((item) => item.parentElement === parent);
  if (sameParent.length <= limit) {
    return { parent, items: sameParent, all: sameParent, truncated: false };
  }

  if (!preferUndecided) {
    return { parent, items: sameParent.slice(0, limit), all: sameParent, truncated: true };
  }

  const fresh = sameParent.filter((item) => !item.hasAttribute(LENS_ITEM_ATTR));
  const seen = sameParent.filter((item) => item.hasAttribute(LENS_ITEM_ATTR));
  const chosen = new Set([...fresh.slice(0, limit), ...seen.slice(0, Math.max(0, limit - fresh.length))]);

  return {
    parent,
    items: sameParent.filter((item) => chosen.has(item)),
    all: sameParent,
    truncated: true,
  };
}

function applyReorder(context: RunContext, op: LensOp, target: Resolution): LensOpResult {
  if (!target.element) return result(op, "missed", 0, undefined, "region matched nothing");
  if (!op.sort) return result(op, "failed", 0, target.usedSelector, "reorder without a sort");

  const run = itemRun(target.element, op, itemAllowance(context), false);
  if (!run) {
    return result(op, "failed", 0, target.usedSelector, "item selector is not usable");
  }
  if (run.items.length === 0) {
    return result(op, "missed", 0, target.usedSelector, "no items to reorder");
  }
  context.items -= run.items.length;

  context.journal.snapshotChildren(run.parent);

  const sorted = sortItems(context, run.items, op.sort);

  // Reinsert the block where the block already ended, so the rows stay in the
  // slot the page laid out for them instead of jumping to the bottom of it.
  const last = run.items[run.items.length - 1];
  const anchor = last?.nextSibling ?? null;
  for (const item of sorted) run.parent.insertBefore(item, anchor);

  const message = run.truncated
    ? `sorted the first ${run.items.length}; more remain`
    : ambiguityMessage(target.matchedCount);
  return result(op, singleStatus(target.matchedCount), run.items.length, target.usedSelector, message);
}

function sortItems(context: RunContext, items: Element[], sort: SortSpec): Element[] {
  const keyed = items.map((item, index) => ({ item, index, key: sortKey(context, item, sort) }));

  // Direction is applied to the comparator rather than by reversing afterwards:
  // reversing a stable sort also reverses the ties, so a descending sort would
  // scramble the document order of every item that shares a key.
  keyed.sort((a, b) => {
    const primary = compareKeys(a.key, b.key);
    if (primary !== 0) return sort.ascending ? primary : -primary;
    return sort.ascending ? a.index - b.index : b.index - a.index;
  });

  return keyed.map((entry) => entry.item);
}

/** Locale-free: a lens is replayed on every visit and on every device, and must
 * produce the same order each time. */
function compareKeys(left: number | string, right: number | string): number {
  if (typeof left === "number" && typeof right === "number") return left - right;
  const a = String(left);
  const b = String(right);
  return a < b ? -1 : a > b ? 1 : 0;
}

function sortKey(context: RunContext, item: Element, sort: SortSpec): number | string {
  switch (sort.key) {
    case "documentOrder":
      return 0;
    case "textLength":
      return (item.textContent ?? "").trim().length;
    case "linkCount":
      return item.querySelectorAll("a[href]").length;
    case "harvestedField":
      return sort.field ? (context.harvests.fieldOf(item, sort.field) ?? "") : "";
  }
}

function applyFilter(context: RunContext, op: LensOp, target: Resolution): LensOpResult {
  if (!target.element) return result(op, "missed", 0, undefined, "region matched nothing");
  if (!op.predicate || !op.filterMode) {
    return result(op, "failed", 0, target.usedSelector, "filter without a predicate");
  }
  const run = itemRun(target.element, op, itemAllowance(context), true);
  if (!run) {
    return result(op, "failed", 0, target.usedSelector, "item selector is not usable");
  }
  if (run.items.length === 0) {
    return result(op, "missed", 0, target.usedSelector, "no items to filter");
  }
  context.items -= run.items.length;

  const limit = op.limit ?? Number.POSITIVE_INFINITY;
  // `limit` is a promise about the page, not about a pass. `itemRun` deliberately
  // hands a truncated feed a window of items nothing has judged yet, so counting
  // only within the window meant "keep the first ten headlines" kept ten *new*
  // ones every pass while the previously kept ten stayed visible — a hundred
  // visible items from a top-ten filter after ten observer passes. So the items
  // outside the window that this lens is already showing are counted first, and
  // the window's allowance is what remains of the limit.
  let showing = keptOutsideWindow(run);
  let kept = 0;
  let hidden = 0;

  for (const item of run.items) {
    const matches = matchesPredicate(item, op.predicate);
    // `keep` shows what matched, `drop` hides it. Both then honour `limit`, which
    // is how "the first ten headlines" is expressed without a second op.
    let visible = op.filterMode === "keep" ? matches : !matches;
    if (visible && showing >= limit) visible = false;
    if (visible) {
      showing += 1;
      kept += 1;
    } else hidden += 1;

    // Re-evaluated from scratch every pass, including observer passes: an item
    // that stops matching must come back, or a feed would erode as the user
    // scrolls. Nothing is recorded for undo — the journal sweeps these two
    // attributes off the document by name, which is exact and holds no
    // references to the cards a virtualised feed is busy recycling.
    if (visible) item.removeAttribute(LENS_HIDDEN_ATTR);
    else item.setAttribute(LENS_HIDDEN_ATTR, "");

    // Judged. Marked separately from the hiding, because "shown" removes the
    // hiding attribute and would otherwise be indistinguishable from "never
    // looked at" — which is the difference `itemRun` needs to keep a feed that
    // has outgrown the budget from freezing on its first four hundred cards.
    item.setAttribute(LENS_ITEM_ATTR, "");
  }

  const suffix = run.truncated ? `; more items remain this pass` : "";
  return result(
    op,
    singleStatus(target.matchedCount),
    run.items.length,
    target.usedSelector,
    `${hidden} hidden, ${kept} kept${suffix}`,
  );
}

/**
 * Items this filter is already showing that are not in this pass's window.
 *
 * "Judged, and not hidden" is the only record of a decision a previous pass made,
 * and it is enough: at most one `filter` op survives planning per resolved
 * region, so every mark under one parent belongs to the op now looking at them.
 * An untruncated run has no outside, and re-decides the whole list from zero,
 * which is what keeps a shrinking feed from carrying a stale count forever.
 */
function keptOutsideWindow(run: ItemRun): number {
  if (!run.truncated) return 0;

  const window = new Set(run.items);
  return run.all.filter(
    (item) =>
      !window.has(item) &&
      item.hasAttribute(LENS_ITEM_ATTR) &&
      !item.hasAttribute(LENS_HIDDEN_ATTR),
  ).length;
}

/**
 * Does one item satisfy the predicate?
 *
 * Terms come from the user's own words, expanded by the model, and are matched
 * here — on the device, against text that never leaves it. That direction is the
 * whole privacy argument for filtering: the page's content is compared to the
 * user's vocabulary locally, rather than the page's content being sent anywhere
 * to be judged.
 */
function matchesPredicate(item: Element, predicate: ItemPredicate): boolean {
  // Counted only if the predicate asks. `minLinks`/`maxLinks` are the rarest
  // fields a predicate carries, and this ran unconditionally: a subtree scan per
  // item, 400 of them per pass and 3,200 a second at the observer cap, thrown
  // away undiscussed on every predicate that only wanted to match a word.
  let links: number | undefined;
  const linkCount = (): number => (links ??= item.querySelectorAll("a[href]").length);
  const text = (item.textContent ?? "").replace(/\s+/g, " ").trim();

  if (typeof predicate.minLinks === "number" && linkCount() < predicate.minLinks) return false;
  if (typeof predicate.maxLinks === "number" && linkCount() > predicate.maxLinks) return false;
  if (typeof predicate.minChars === "number" && text.length < predicate.minChars) return false;
  if (typeof predicate.maxChars === "number" && text.length > predicate.maxChars) return false;

  const terms = predicate.terms.filter((term) => term.trim().length > 0);
  if (terms.length === 0) return true;

  const haystack = fieldValue(item, predicate.field, text).toLowerCase();
  const hits = terms.filter((term) => haystack.includes(term.toLowerCase().trim()));

  switch (predicate.matchMode) {
    case "any":
      return hits.length > 0;
    case "all":
      return hits.length === terms.length;
    case "none":
      return hits.length === 0;
  }
}

function fieldValue(item: Element, field: ItemPredicate["field"], text: string): string {
  switch (field) {
    case "text":
      return text;
    case "href": {
      const own = item.getAttribute("href") ?? "";
      const nested = Array.from(item.querySelectorAll("a[href]"))
        .map((link) => link.getAttribute("href") ?? "")
        .join(" ");
      return `${own} ${nested}`;
    }
    case "ariaLabel": {
      const own = item.getAttribute("aria-label") ?? "";
      const nested = Array.from(item.querySelectorAll("[aria-label]"))
        .map((node) => node.getAttribute("aria-label") ?? "")
        .join(" ");
      return `${own} ${nested}`;
    }
  }
}

function applyLabel(context: RunContext, op: LensOp, target: Resolution): LensOpResult {
  if (!target.element) return result(op, "missed", 0, undefined, "region matched nothing");

  const text = safeText(op.text);
  if (!text) return result(op, "failed", 0, target.usedSelector, "label without text");

  const label = context.doc.createElement("zentic-lens-label");
  label.setAttribute(LENS_NODE_ATTR, "label");
  // `textContent`, never `innerHTML`: a label is a string the model wrote, and
  // the only safe way to put a model's string in a page is as a text node.
  label.textContent = text;

  context.journal.snapshotChildren(target.element);
  target.element.insertBefore(label, target.element.firstChild);
  context.journal.recordInserted(label);

  return result(
    op,
    singleStatus(target.matchedCount),
    target.matchedCount,
    target.usedSelector,
    ambiguityMessage(target.matchedCount),
  );
}

function applyHarvest(context: RunContext, op: LensOp, target: Resolution): LensOpResult {
  if (!target.element) return result(op, "missed", 0, undefined, "region matched nothing");

  const spec = op.harvest;
  if (!spec || !safeItemSelector(spec.itemSelector) || spec.fields.length === 0) {
    return result(op, "failed", 0, target.usedSelector, "harvest without a usable spec");
  }

  // Harvesting walks items and reads fields off each one, so it spends the same
  // per-pass allowance a filter does; a lens that harvests four hundred rows and
  // then filters a feed is one pass's worth of work, not two.
  const allowance = itemAllowance(context);
  const limit = Math.min(op.limit ?? allowance, allowance);
  const outcome = harvestItems(target.element, spec, limit);
  if (outcome.records.length === 0) {
    return result(op, "missed", 0, target.usedSelector, "no items matched the harvest selector");
  }
  // Charged as soon as the items were walked, whatever the fields came back
  // holding: the frame was spent either way.
  context.items -= outcome.records.length;

  // A wrong field selector reads an empty string, and `readField` has no way to
  // tell "this card has no byline" from "`.byline` is not what this site calls
  // it". Records still came back one per item, so the count was right and the
  // status was `applied` — and then `buildInsertion` skipped every empty cell,
  // the block rendered childless, and a harvest-and-insert pair that put
  // literally nothing on the page badged green. Invariant 8: a field set that
  // read nothing anywhere is drift, and drift is what Re-fit exists for.
  const read = outcome.records.some((record) =>
    Object.values(record.fields).some((value) => value.length > 0),
  );
  if (!read) {
    return result(
      op,
      "missed",
      0,
      target.usedSelector,
      `every field selector read an empty value across ${outcome.records.length} items`,
    );
  }

  context.harvests.put(spec.into, outcome.records, outcome.elements);

  // The count is the only thing that leaves this function. What was harvested
  // stays in the store, on the device — a report carrying harvested text would
  // put page content on the wire, which is the one thing a lens must never do.
  return result(
    op,
    singleStatus(target.matchedCount),
    outcome.records.length,
    target.usedSelector,
    outcome.truncated ? `harvested the first ${outcome.records.length}` : undefined,
  );
}

/**
 * Insert a harvested bucket somewhere else on the page.
 *
 * `op.region` is where the values came from and `op.target` is where the block
 * goes — the same source/destination shape as `move`, which is what the Swift
 * validator enforces (`.insert` requires a `target`, and a target must be a
 * declared region). The payload is named by `op.bucket`, which the validator
 * also requires to match a `HarvestSpec.into` declared in the same lens.
 *
 * That field replaced two things, both broken. The bucket used to ride on
 * `op.text` — the field `label` uses for prose — and the structured-output
 * schema requires every property, so a model dutifully filled `text` with a
 * sentence and every insert reported `missed` for a bucket nobody had written.
 * Failing that, the runner guessed: it used whichever bucket this op's source
 * region happened to harvest into during this pass. That guess is gone too. It
 * is precisely the ambiguity `bucket` exists to remove, and a fallback that
 * quietly renders a *different* list than the one authored is worse than an
 * honest `failed`.
 */
function applyInsert(context: RunContext, lens: Lens, op: LensOp): LensOpResult {
  if (!op.target) return result(op, "failed", 0, undefined, "insert without a destination");

  const destination = context.resolver.resolve(lens, op.target);
  if (!destination.element) {
    return result(op, "missed", 0, undefined, missMessage(lens, op.target));
  }

  const bucket = safeBucket(op.bucket);
  if (!bucket) {
    return result(op, "failed", 0, destination.usedSelector, "insert names no harvest bucket");
  }

  const records = context.harvests.get(bucket);
  if (!records || records.length === 0) {
    return result(op, "missed", 0, destination.usedSelector, `nothing harvested into ${bucket}`);
  }

  const limit = Math.min(op.limit ?? records.length, context.budget.maxItemsPerPass);
  const block = buildInsertion(context.doc, bucket, records, limit);

  // An empty block is a `<zentic-lens-insert>` with nothing in it: invisible,
  // and reported `applied, matchedCount: 0` — a number that says what happened
  // and a status that contradicts it. Not inserted at all, so the page is not
  // carrying one of our nodes for nothing either.
  if (block.childNodes.length === 0) {
    return result(
      op,
      "missed",
      0,
      destination.usedSelector,
      `nothing in ${bucket} had a value to render`,
    );
  }

  context.journal.snapshotChildren(destination.element);
  const children = Array.from(destination.element.children);
  const index = Math.round(clamp(op.index ?? 0, 0, children.length));
  destination.element.insertBefore(block, children[index] ?? null);
  context.journal.recordInserted(block);

  return result(
    op,
    singleStatus(destination.matchedCount),
    block.childNodes.length,
    destination.usedSelector,
    ambiguityMessage(destination.matchedCount),
  );
}

/** Ops that keep working as a feed grows, and therefore need an observer. */
export function isLiveOp(op: LensOp): boolean {
  return op.kind === "filter" || op.kind === "reorder";
}

/**
 * Ops whose whole effect is a rule in the stylesheet.
 *
 * Two things follow from that, and the appearance re-check in `index.ts` needs
 * both. They touch no node, so re-running one is free of consequence — it
 * re-reads the DOM and produces a fresh `LensOpResult`, and that is all. And
 * their report is a claim about the *sheet*: `usedSelector` names the selector
 * the rule was written against, so a recompile that picks a different anchor
 * invalidates the last thing said about them. Recompiling and re-reporting them
 * together is what keeps the two from drifting apart.
 */
export function isCSSOp(op: LensOp): boolean {
  return op.kind === "hide" || op.kind === "keep" || op.kind === "width" || op.kind === "restyle";
}
