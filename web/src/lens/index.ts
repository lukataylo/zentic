import type {
  Lens,
  LensOpResult,
  LensReport,
  ReaderConfiguration,
  RegionCatalog,
} from "../wire.js";
import { safeDecode } from "../skeleton.js";
import { HarvestStore } from "./harvest.js";
import {
  DEFAULT_OBSERVER_BUDGET,
  LensObservers,
  type ObserverBudget,
} from "./observe.js";
import {
  DEFAULT_OP_BUDGET,
  LENS_STYLE_ID,
  LensJournal,
  RegionResolver,
  compilePass,
  currentPath,
  isCSSOp,
  isLiveOp,
  runStructuralOps,
  type LensPass,
  type OpBudget,
} from "./ops.js";
import { buildRegionCatalog } from "./regions.js";

// The lens engine, as one object with a life cycle.
//
// Everything a lens does to a page is owned here, which is what makes "turn it
// off" a single call. The stylesheet, the undo journal, the harvest buckets and
// the feed observers are all held together and torn down together, because a
// partial teardown — a sheet removed but nodes still moved, an observer still
// watching a region that no longer exists — is indistinguishable to the user from
// a broken site.
//
// ## Where this runs
//
// Both paths. Lenses are for apps as much as articles — "YouTube without the
// suggestions rail" is the motivating case, and YouTube is exactly the kind of
// page invariant 2 forbids restructuring. So the engine is constructed and its
// stylesheet injected before the reader decides whether it is eligible, and the
// passthrough path runs the same structural pass the reader path does.
//
// ## What it never does
//
// It never hides the document, never arms a failsafe, never delays a reveal.
// Invariant 1 belongs to the reader; a lens that could keep a page dark would be
// trading a guaranteed paint for a cosmetic improvement.

export interface LensEngineOptions {
  ops: OpBudget;
  observer: ObserverBudget;
  /** `Budget.lensRegionCandidateLimit`. */
  regionCandidateLimit: number;
  /** `Budget.lensMaxLensesPerOrigin`. */
  maxLenses: number;
  debug: boolean;
}

export const DEFAULT_ENGINE_OPTIONS: LensEngineOptions = {
  ops: DEFAULT_OP_BUDGET,
  observer: DEFAULT_OBSERVER_BUDGET,
  regionCandidateLimit: 120,
  maxLenses: 12,
  debug: false,
};

/**
 * The engine's options for one page load.
 *
 * The budgets used to ride down the wire in seven `ReaderConfiguration` fields
 * and be read back here field by field, each with its own fallback — because a
 * missing budget fails *permissively* rather than loudly, and
 * `passCeilingMs: undefined` makes a deadline of `NaN` that `now() >` is false
 * against forever. All seven were compile-time constants on the Swift side, and
 * all seven had a copy of the same constant right here as the fallback: two
 * copies of one number, shipped over a bridge, to arrive at the value the
 * receiver already had. The fallbacks are the values now, so there is nothing
 * left to arrive missing.
 *
 * `debugLogging` is a real setting, and the one thing left to read.
 */
export function engineOptions(config: ReaderConfiguration): LensEngineOptions {
  return { ...DEFAULT_ENGINE_OPTIONS, debug: config.debugLogging === true };
}

/**
 * What the engine needs from the page around it.
 *
 * Two facts it cannot work out for itself: whether the reader is currently
 * showing its own render instead of the page (which decides whether a lens can
 * possibly be visible), and where to send a report that arrives after the pass
 * that produced it.
 */
export interface LensEngineHooks {
  /** True while `ReaderView` is *painting over* the page — `isCovering`, not
   * `isRendered`. A reader that is mounted but hidden (⌘\, an SPA route change)
   * leaves the site's own DOM on screen, and a lens's ops are visible on it. */
  isReaderRendered?: () => boolean;
  /** Re-post a whole-lens report the engine revised after the initial pass. */
  onReport?: (reports: LensReport[]) => void;
}

/**
 * How long a revised report waits before it is posted.
 *
 * Live passes arrive at up to `lensObserverMaxPassesPerSecond`, and a badge that
 * re-renders eight times a second while the user scrolls is noise. A pause long
 * enough to cover a scroll burst, short enough that a region which lazy-renders
 * after first paint stops reading as drift within a moment of appearing.
 */
const REPORT_COALESCE_MS = 500;

/** The sentence a suppressed report carries. See `runPass`. */
const READER_SUPPRESSED =
  "the reader is showing its own render; this lens applies to the original page";

export class LensEngine {
  private readonly journal: LensJournal;
  private readonly harvests = new HarvestStore();
  private readonly observers: LensObservers;
  private style: HTMLStyleElement | undefined;
  private stored: Lens[] = [];
  private active: Lens[] = [];
  /** The last *whole* report for each active lens, kept so a live pass can
   * revise the ops it re-ran without discarding what the others said. */
  private reports = new Map<string, LensReport>();
  private reportTimer: ReturnType<typeof setTimeout> | undefined;
  /**
   * Ops the last full pass reported `missed`, by lens id.
   *
   * The set the appearance watch is waiting on, and it only ever shrinks: an op
   * leaves when it stops missing, and when the map empties the watch stops. It is
   * *not* the same thing as "ops the badge counts as drift" — that stays the
   * report's own business, and stays `missed` for anything still in here.
   */
  private pending = new Map<string, Set<string>>();

  constructor(
    private readonly doc: Document,
    private readonly options: LensEngineOptions = DEFAULT_ENGINE_OPTIONS,
    private readonly hooks: LensEngineHooks = {},
  ) {
    this.journal = new LensJournal(doc);
    this.observers = new LensObservers(options.observer, (target) => this.rerunLive(target));
  }

  /** The lenses that matched the current URL at the last pass, in stacking order. */
  get appliedLenses(): Lens[] {
    return this.active;
  }

  /**
   * Replace the lens set.
   *
   * A full reset rather than a diff: working out which of two op lists still
   * applies is a source of bugs that only show up on the user's page, whereas
   * undo-then-reapply is one code path that is exercised on every SPA navigation.
   */
  setLenses(lenses: Lens[]): void {
    this.clear();
    this.stored = lenses;
    this.injectStylesheet();
  }

  /**
   * Compile and inject the stylesheet for the current URL.
   *
   * Safe at `document-start`: the compile resolves what it can and falls back to
   * each region's preferred anchor when nothing resolves, and the sheet goes on
   * `documentElement` when `head` does not exist yet. This call is the whole
   * no-flash story — by the time the page's own markup parses, the rules that hide
   * the parts the user does not want are already in the cascade.
   *
   * ## Why it is re-appended every time
   *
   * `document.head` is null at `document-start`, so the sheet lands as a direct
   * child of `<html>` — the weakest position in the cascade there is. A page rule
   * of equal specificity, `!important` against our `!important`, then wins on
   * order and the lens quietly does nothing on exactly the sites that fight
   * hardest. Moving the element to the end of `head` on every pass costs one
   * `appendChild` and puts us after the page's own stylesheets.
   */
  injectStylesheet(): void {
    this.compile();
  }

  /**
   * Re-match, compile once, and put the result in the cascade.
   *
   * The compile comes back so the pass that follows can run from the same plan
   * and the same resolver. `runPass()` used to call `injectStylesheet()` and then
   * let `runStructuralOps` compile all over again — the same selectors resolved
   * twice against the same document, and the two answers free to disagree about
   * which anchor a region ended up on.
   *
   * `undefined` when no lens applies to this URL. That is not an empty compile:
   * it is no compile, no `<style>` node and no style recalculation, on every load
   * of every page that has no lens on it — which is nearly all of them.
   */
  private compile(resolver?: RegionResolver): LensPass | undefined {
    this.active = matchingLenses(this.stored, this.currentURL(), this.options.maxLenses);
    if (this.active.length === 0) {
      this.style?.remove();
      this.style = undefined;
      return undefined;
    }

    // Resolved against the engine's own document, never the ambient global: they
    // are the same object in a browser tab and different ones everywhere else.
    //
    // And *no* document before `body` exists. Nothing can resolve at
    // `document-start` — the page has not parsed — so every candidate of every op
    // would be a whole-document `querySelectorAll` against an empty tree,
    // guaranteed to come back empty and be discarded. Handing the resolver
    // nothing makes it skip the queries instead of running them to learn what we
    // already know.
    // A caller with a resolver in hand passes it, so the sheet and the report
    // that follows are two readings of one set of answers. Without one the
    // compile makes its own, which is every path but the appearance re-check.
    const doc = this.doc.body ? this.doc : undefined;
    const pass = compilePass(this.active, this.options.ops, doc, resolver);

    const root = this.doc.head ?? this.doc.documentElement;
    if (!root) return pass;

    if (!this.style || !this.style.isConnected) {
      const style = this.doc.createElement("style");
      style.id = LENS_STYLE_ID;
      this.style = style;
    }

    // `appendChild` moves a connected node, so this is both the first insertion
    // and the re-append. Skipped when the sheet is already last, so a page whose
    // own script watches `head` does not see a mutation on every SPA navigation.
    if (this.style.parentNode !== root || this.style.nextSibling !== null) {
      root.appendChild(this.style);
    }

    // Guarded on an actual change. Assigning `textContent` invalidates style for
    // the whole document whether or not a byte moved, and the common case is that
    // no byte does: an observer-driven page recompiles the same sheet from the
    // same lenses on every SPA navigation and every re-fit.
    if (this.style.textContent !== pass.css) this.style.textContent = pass.css;

    return pass;
  }

  /**
   * Run the structural pass and return one report per applied lens.
   *
   * Idempotent by construction: the previous pass is undone first, so a
   * navigation, a re-apply and a re-fit all land on the same code path and none
   * of them can double a moved node or stack two labels.
   *
   * ## Why the reader path reports nothing applied
   *
   * When `ReaderView` is rendered, the user is looking at our re-render and the
   * site's own DOM is hidden underneath it. Ops still *resolve* against that
   * hidden DOM — the selectors are all still there — so the pass would report
   * `4/4, no drift` for a lens whose every effect is invisible. That is invariant
   * 8's failure exactly: a number that is not true of what is on screen. So the
   * structural pass is skipped and every op is reported `skipped` with the reason.
   *
   * The stylesheet stays in the cascade. It costs nothing against a hidden
   * document, and it is what makes ⌘\ back to the original instant and
   * flash-free; `main.ts` re-runs this pass on that switch, so the structural ops
   * land the moment the original is the thing being looked at.
   */
  runPass(): LensReport[] {
    // Before anything else. `passCeilingMs` is a promise about a frame, and the
    // frame starts here — with the undo, the compile and the resolver sweep in
    // it. The deadline used to be read inside `runStructuralOps`, after two full
    // resolver sweeps had already run, so a ceiling named for the pass governed
    // roughly the last three per cent of it.
    const startedAt = performance.now();

    this.observers.disconnectAll();
    this.journal.undo();
    this.harvests.clear();
    this.cancelReportPost();
    this.pending.clear();

    // Re-matched every pass: an SPA route change can move the page in or out of a
    // lens's path pattern without the app ever being asked for a new lens set.
    const pass = this.compile();
    if (!pass) {
      this.reports.clear();
      return [];
    }

    const reports = this.isReaderRendered()
      ? this.suppressedReports()
      : this.structuralPass(pass, startedAt);
    this.reports = new Map(reports.map((report) => [report.lensID, report]));

    if (this.options.debug) {
      for (const report of reports) {
        const missed = report.results.filter((entry) => entry.status === "missed").length;
        console.info(
          `[zentic] lens ${report.lensID}: ${report.results.length} ops, ${missed} missed`,
        );
      }
    }

    return reports;
  }

  private structuralPass(pass: LensPass, startedAt: number): LensReport[] {
    const reports = runStructuralOps(this.doc, this.active, {
      budget: this.options.ops,
      journal: this.journal,
      harvests: this.harvests,
      pass,
      startedAt,
    }).map(withPathOnly);

    // One resolution per region for the whole pass, reused by the observers —
    // the compile's own resolver, which already holds every answer they need.
    this.watchLiveRegions(this.liveRegions(pass.resolver));
    this.observers.drain();
    this.waitForMissedRegions(reports);

    return reports;
  }

  /**
   * Start waiting for the regions this pass could not find.
   *
   * The pass runs at DOM ready, and on an app that is when the shell exists and
   * the content does not: YouTube renders `#secondary` and `#comments` some way
   * into first paint, so a lens naming them resolves to nothing and reports every
   * op `missed` — while the `document-start` sheet is already hiding both, and
   * goes on hiding them the moment they render. A badge that reads amber `0/3`
   * over a lens doing precisely what it was asked is invariant 8 broken in the
   * pessimistic direction, and pessimistic is the worse one: it teaches the user
   * the feature does not work, at the exact moment it is working.
   *
   * Waiting is not the same as assuming. Nothing is reported `applied` because a
   * rule was emitted — that is the `applied, matchedCount: 0` lie the harvest
   * path already had to unlearn. The report stays `missed` until the region is
   * *found*, and a region that never renders is one that never renders: the watch
   * gives up at `appearanceWindowMs` and the pessimistic answer turns out to have
   * been the true one.
   */
  private waitForMissedRegions(reports: LensReport[]): void {
    this.pending = new Map();
    for (const report of reports) {
      const missed = report.results.filter((entry) => entry.status === "missed");
      if (missed.length > 0) {
        this.pending.set(report.lensID, new Set(missed.map((entry) => entry.opID)));
      }
    }
    if (this.pending.size === 0) return;
    this.observers.watchForAppearance(() => this.recheckPending());
  }

  /**
   * Re-read the page for the ops that were still missing, and correct the report.
   *
   * Returns whether anything is still missing, which is what stops the watch.
   *
   * ## What is re-run, and why it is more than the missing ops
   *
   * The sheet is recompiled first, because a region that has now rendered may
   * resolve through a different candidate than the anchor the `document-start`
   * compile had to guess at — or through the fingerprint, which mints a path
   * belonging to no candidate at all. Reporting `usedSelector` for a rule the
   * sheet does not contain is the one lie `ops.ts` is arranged from end to end to
   * prevent.
   *
   * But a recompile is a recompile: it can just as well move the rule for an op
   * that was reported `applied` half a second ago, and then *that* report names a
   * selector the sheet no longer uses. So every CSS op is re-run alongside the
   * missing ones. It costs nothing — a CSS op touches no node, it only reads —
   * and it means the sheet and the half of the report that describes the sheet
   * are always two readings of one compile. Structural ops are re-run only when
   * they were missing, because re-running one that already landed would move a
   * node twice.
   */
  private recheckPending(): boolean {
    if (this.pending.size === 0) return false;

    const started = performance.now();
    const resolver = new RegionResolver(this.doc);
    const pass = this.compile(resolver);

    // No lens applies here any more — a same-document navigation walked out from
    // under the watch. Nothing left to correct and nothing to keep waiting for.
    if (!pass) {
      this.pending.clear();
      return false;
    }

    const plan = pass.plan.filter(
      (entry) => this.isPending(entry.lens.id, entry.op.id) || isCSSOp(entry.op),
    );
    const lenses = this.active.filter((lens) => plan.some((entry) => entry.lens.id === lens.id));
    if (lenses.length === 0) {
      this.pending.clear();
      return false;
    }

    const reports = runStructuralOps(this.doc, lenses, {
      budget: this.options.ops,
      journal: this.journal,
      harvests: this.harvests,
      pass: { ...pass, plan },
      startedAt: started,
    });

    if (this.absorb(reports)) {
      this.scheduleReportPost();
      // A `filter` whose feed has only now rendered has applied once and would
      // then stop as the user scrolls, because nothing is watching it. The
      // resolver is the one the re-run used, so this asks no selector twice.
      this.watchLiveRegions(this.liveRegions(resolver));
      this.observers.drain();
    }

    return this.pending.size > 0;
  }

  private isPending(lensID: string, opID: string): boolean {
    return this.pending.get(lensID)?.has(opID) === true;
  }

  /**
   * Take a re-check's results into the cached report, and say whether the page's
   * account of itself actually changed.
   *
   * The answer gates the re-post. A watch that finds nothing new runs up to seven
   * times, and seven identical reports crossing the bridge to redraw an identical
   * badge is the report churn the coalescing timer exists to prevent, arriving by
   * another door.
   */
  private absorb(reports: LensReport[]): boolean {
    let changed = false;

    for (const report of reports) {
      // Before the `previous` guard, and deliberately. A lens with no cached
      // report has nothing to correct, but leaving its ops in `pending` would
      // keep the watch running to the deadline for a question already answered.
      const waiting = this.pending.get(report.lensID);
      const previous = this.reports.get(report.lensID);

      for (const entry of report.results) {
        if (entry.status !== "missed") waiting?.delete(entry.opID);
        const held = previous?.results.find((candidate) => candidate.opID === entry.opID);
        if (held && !sameResult(held, entry)) changed = true;
      }

      if (waiting?.size === 0) this.pending.delete(report.lensID);
    }

    if (changed) this.mergeReports(reports);
    return changed;
  }

  /** One report per lens saying, honestly, that nothing ran. */
  private suppressedReports(): LensReport[] {
    const generatedAt = new Date().toISOString();
    const url = currentPath();
    return this.active.map((lens) => ({
      lensID: lens.id,
      url,
      generatedAt,
      results: lens.ops.map((op) => ({
        opID: op.id,
        status: "skipped" as const,
        matchedCount: 0,
        message: READER_SUPPRESSED,
      })),
    }));
  }

  /**
   * Stop the feed observers without undoing anything.
   *
   * Called the moment a same-document navigation is detected. The structural
   * pass for the new route waits for the DOM to settle, and for that whole window
   * the old route's observers would be watching regions the router is tearing
   * down — scheduling passes against nodes nobody can see. Undo waits for the
   * pass, so the page never flashes back to its unlensed state in between.
   */
  stopWatching(): void {
    this.observers.disconnectAll();
  }

  /** A textless description of the page, for the model and the editor overlay. */
  catalog(): RegionCatalog {
    return buildRegionCatalog(this.doc, {
      url: this.currentURL(),
      limit: this.options.regionCandidateLimit,
    });
  }

  /**
   * Undo everything and stop watching.
   *
   * Reversibility is a promise the feature makes to the user — ⌘\ shows the real
   * page — so this has to restore the DOM to what it found, not to something that
   * looks the same. Order matters: observers stop first, so nothing schedules a
   * pass into a half-restored page.
   */
  clear(): void {
    this.observers.disconnectAll();
    this.cancelReportPost();
    this.journal.undo();
    this.harvests.clear();
    this.active = [];
    this.reports.clear();
    this.pending.clear();

    this.style?.remove();
    this.style = undefined;
  }

  /**
   * Where each live op's region is, read off a resolver the caller already has.
   *
   * Only the pass path needs the whole map: it is attaching an observer to every
   * region that carries an op which must survive a scroll, so it genuinely has to
   * resolve all of them — and it does that on the compile's resolver, which has
   * already answered every one of those questions.
   *
   * Taking a resolver rather than making one is the point of the signature. This
   * used to call a `regionElement()` helper that constructed a whole
   * `RegionResolver` **per region**, and the observer callback called it too:
   * twelve lenses of forty ops is 480 regions of up to eight candidates, and the
   * callback measured 3,925 whole-document queries — 31,400 a second at the rate
   * cap, none of it inside `passCeilingMs`, which only ever governed the op
   * runner. The comment that used to sit here claimed the problem was already
   * fixed, and quoted a figure the code beneath it beat by an order of magnitude
   * in the wrong direction. The live path no longer comes through here at all;
   * see `liveOpsFor`.
   *
   * Never cached across passes: the point of the live path is that the page
   * changed, and a region the router replaced must resolve to the new element or
   * the ops would act on a detached one. A resolver lives for exactly one pass.
   */
  private liveRegions(resolver: RegionResolver): Map<string, Element | undefined> {
    const resolved = new Map<string, Element | undefined>();
    for (const lens of this.active) {
      for (const op of lens.ops) {
        if (!isLiveOp(op)) continue;
        const key = regionKey(lens, op.region);
        if (resolved.has(key)) continue;
        resolved.set(key, resolver.resolve(lens, op.region).element);
      }
    }
    return resolved;
  }

  /**
   * The live ops whose region is the element an observer just fired for.
   *
   * The screen is the point. This used to resolve *every* live region and then
   * compare — 480 whole-document `querySelectorAll` sweeps to identify one
   * element the callback was handed. `Element.matches()` walks one element, so
   * each region is first asked whether it could be this one, and only the region
   * that says yes is looked up in the document to be sure. A candidate matching
   * the target is not proof on its own: an earlier candidate may resolve to a
   * different box, and it is that box the ops were written about.
   */
  private liveOpsFor(target: Element, resolver: RegionResolver): Lens[] {
    const live: Lens[] = [];
    const owned = new Map<string, boolean>();

    for (const lens of this.active) {
      const ops = lens.ops.filter((op) => {
        if (!isLiveOp(op)) return false;
        const key = regionKey(lens, op.region);
        let held = owned.get(key);
        if (held === undefined) {
          const region = lens.regions.find((entry) => entry.id === op.region);
          held =
            region !== undefined &&
            resolver.couldBe(target, region) &&
            resolver.resolve(lens, op.region).element === target;
          owned.set(key, held);
        }
        return held;
      });
      if (ops.length > 0) live.push({ ...lens, ops });
    }

    return live;
  }

  /** Attach an observer to every region carrying an op that must survive scroll. */
  private watchLiveRegions(regions: Map<string, Element | undefined>): void {
    for (const element of regions.values()) {
      if (element) this.observers.watch(element);
    }
  }

  /**
   * Re-apply the live ops for one region after the page grew.
   *
   * Only `filter` and `reorder`, and only for this region: a full pass would undo
   * and redo every move on the page for the sake of twenty new cards, which is
   * precisely the jank the budgets exist to prevent.
   *
   * The results are merged into the last whole report rather than posted as they
   * are. A partial report would make the toolbar badge count down as the user
   * scrolls; posting nothing at all, which is what this used to do, leaves the
   * badge showing the DOM-ready answer forever — so a region that lazy-renders
   * after first paint reports `missed` once and stays amber for the life of the
   * page while the observer is quietly applying it on every batch of cards. The
   * merged report is still a whole-lens count, just a current one.
   */
  private rerunLive(target: Element): void {
    // One resolver for the whole callback, shared with the op runner: picking the
    // ops for this region and running them ask the same selectors the same
    // questions. This is why the re-run takes a `resolver` rather than a `pass` —
    // the plan it needs covers a subset of the ops, but the resolutions are
    // identical.
    const started = performance.now();
    const resolver = new RegionResolver(this.doc);
    const live = this.liveOpsFor(target, resolver);

    if (live.length === 0) return;

    const reports = runStructuralOps(this.doc, live, {
      budget: this.options.ops,
      journal: this.journal,
      harvests: this.harvests,
      resolver,
      startedAt: started,
    });

    this.mergeReports(reports);
    this.scheduleReportPost();
  }

  /** Fold a live pass's results into the whole-lens report, leaving the ops it
   * did not re-run exactly as they were last reported. */
  private mergeReports(partial: LensReport[]): void {
    for (const report of partial) {
      const previous = this.reports.get(report.lensID);
      // Nothing to merge into: the lens set changed under us, and inventing a
      // report from two of six ops is the countdown badge this exists to avoid.
      if (!previous) continue;

      const revised = new Map<string, LensOpResult>(
        report.results.map((entry) => [entry.opID, entry]),
      );
      this.reports.set(report.lensID, {
        ...previous,
        generatedAt: report.generatedAt,
        results: previous.results.map((entry) => revised.get(entry.opID) ?? entry),
      });
    }
  }

  private scheduleReportPost(): void {
    if (!this.hooks.onReport || this.reportTimer !== undefined) return;
    this.reportTimer = setTimeout(() => {
      this.reportTimer = undefined;
      const reports = this.active
        .map((lens) => this.reports.get(lens.id))
        .filter((report): report is LensReport => report !== undefined);
      if (reports.length > 0) this.hooks.onReport?.(reports);
    }, REPORT_COALESCE_MS);
  }

  private cancelReportPost(): void {
    if (this.reportTimer === undefined) return;
    clearTimeout(this.reportTimer);
    this.reportTimer = undefined;
  }

  private isReaderRendered(): boolean {
    try {
      return this.hooks.isReaderRendered?.() === true;
    } catch {
      // A view that throws while being asked whether it is on screen is a bug
      // elsewhere; assuming it is not rendered keeps the lens working.
      return false;
    }
  }

  private currentURL(): string {
    try {
      return location.href;
    } catch {
      return "";
    }
  }
}

/** Region ids are lens-local — two models both naming a region `feed` mean two
 * different elements — so anything keyed by one is keyed by its lens as well. */
function regionKey(lens: Lens, regionID: string): string {
  return `${lens.id}:${regionID}`;
}

/**
 * The lenses that apply to one URL, in the order they stack.
 *
 * The app has already matched once, at navigation time, but this runs again on
 * every pass because a same-document navigation changes the path without asking
 * the app for anything. A lens written for `/watch` must stop applying the moment
 * the user clicks through to the home feed, and only this side knows when that
 * happened.
 */
export function matchingLenses(lenses: Lens[], url: string, limit: number): Lens[] {
  let host = "";
  let path = "/";
  try {
    const parsed = new URL(url);
    host = parsed.host.toLowerCase();
    path = parsed.pathname;
  } catch {
    return [];
  }

  const matched = lenses.filter(
    (lens) =>
      lens.isEnabled &&
      normaliseHost(lens.origin) === host &&
      lensPathMatches(lens.pathPattern, path),
  );

  matched.sort(appliesBefore);
  return matched.slice(0, Math.max(0, limit));
}

/**
 * Application order: newest edit last, so the most recently touched lens wins.
 *
 * There used to be an explicit `Lens.order` here, a drag-to-reorder row in the
 * popover to set it, a path-specificity tie-break, and an arbitration model on
 * both sides of the bridge that had to agree about which of two clashing ops the
 * user would see. Nobody reorders lenses. What people do is edit the one that is
 * not doing what they wanted, and "the one I just edited wins" is the rule they
 * already expect from every other stack of rules they use.
 *
 * ## Why this points the opposite way to `LensStore.newestFirst`
 *
 * `LensStore.lenses(for:path:)` in `Sources/ZenticKit/Lens/LensStore.swift`
 * sorts the same field **descending**, and hands the set to the page in that
 * order. That list is *read*: it is the popover's rows and `LensState.entries`,
 * and the lens someone just edited is the one they are thinking about, so it goes
 * at the top. This list is *applied*, and the winner of a clash is whatever the
 * cascade and DOM order reach last. Same rule, seen from two ends — which is also
 * how a divergence hides, so the relationship is pinned by a test rather than
 * left to two comments agreeing with each other: **this order is that list,
 * reversed, whole.**
 *
 * That is why the tie-break points backwards too. Both sides used to break a tie
 * on ascending id, so two lenses saved in the same millisecond were in the *same*
 * order in both lists rather than mirrored, and the popover's first row was not
 * the lens the page was showing.
 *
 * `updatedAt` is compared as text rather than as a date, and locale-free: the
 * wire format is a fixed ISO-8601 spelling, which sorts identically either way,
 * and a lens must stack the same on every device. The id breaks a tie, so the
 * sequence is total — two lenses saved in the same millisecond must not swap
 * places between one page load and the next.
 */
function appliesBefore(a: Lens, b: Lens): number {
  if (a.updatedAt !== b.updatedAt) return a.updatedAt < b.updatedAt ? -1 : 1;
  return a.id < b.id ? 1 : a.id > b.id ? -1 : 0;
}

/**
 * Does this pattern cover this path?
 *
 * A port of `LensPath.matches` in `Sources/ZenticKit/Lens/LensStore.swift`, and
 * it has to stay one. The app matches at navigation time and hands the page the
 * lenses that won; this side matches again on every pass, because a same-document
 * navigation changes the path without asking the app for anything. When the two
 * disagree the app's answer wins silently and no `LensReport` is produced at all
 * — not even a `missed` — so the popover shows a lens with a stale badge and the
 * drift UI has nothing to say about why the page looks untouched.
 *
 * String equality was that disagreement. A wildcard stands for one segment, so a
 * lens saved with two wildcard segments under "/posts" covers
 * `/posts/12345/my-title` in Swift and covered nothing here.
 *
 * Generalising the path and comparing strings is not the same rule either:
 * `/posts/12345/my-title` generalises with `my-title` intact, since it is short
 * and has no digits in it, so a user who chose "pages like this" and got a
 * wildcard-per-segment pattern would never match the page they were looking at.
 */
export function lensPathMatches(pattern: string, path: string): boolean {
  const trimmed = pattern.trim();
  if (trimmed === "*") return true;

  // Both sides decoded segment by segment, after the split: decoding first would
  // let an encoded `%2F` invent a segment boundary, and decoding neither leaves a
  // stored `%E7%8C%AB` failing to match a live path that reads `猫`.
  const expected = segments(trimmed);
  const actual = segments(path);
  if (expected.length !== actual.length) return false;

  return expected.every((segment, index) => segment === "*" || segment === actual[index]);
}

function segments(path: string): string[] {
  return path
    .split("/")
    .filter((segment) => segment.length > 0)
    .map(safeDecode);
}

/** Whether two results say the same thing about one op. Every field the toolbar
 * or the popover draws, which is all of them. */
function sameResult(a: LensOpResult, b: LensOpResult): boolean {
  return (
    a.status === b.status &&
    a.matchedCount === b.matchedCount &&
    a.usedSelector === b.usedSelector &&
    a.message === b.message
  );
}

function withPathOnly(report: LensReport): LensReport {
  return { ...report, url: pathOf(report.url) };
}

function pathOf(url: string): string {
  try {
    return new URL(url).pathname;
  } catch {
    return currentPath();
  }
}

/** Accepts both `example.com` and `https://example.com`, because a lens saved
 * from the editor and one read back off disk have been known to disagree about
 * which of the two the field holds. */
function normaliseHost(origin: string): string {
  const trimmed = origin.trim().toLowerCase();
  const withoutScheme = trimmed.replace(/^[a-z][a-z0-9+.-]*:\/\//, "");
  return withoutScheme.replace(/\/+$/, "");
}
