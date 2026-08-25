import { isOurs, regionIdentifier, stableClasses } from "./regions.js";
import type { RegionFingerprint, RegionRectBand } from "../wire.js";

// Re-finding a region after the site changed under the lens.
//
// ## Why this exists at all
//
// A `LensRegion` carries a best-first selector list, and that list only degrades
// gracefully when a stale selector matches *nothing*: the runner falls through to
// the next one, and if they all miss the op reports `missed` and the drift badge
// tells the truth. Measured across five sites, that is not what happens. On four
// of them the preferred anchor is a structural path or a build hash, and after a
// redesign a path still matches — a *different* element. The second candidate is
// never asked. So the failure that actually occurs is a lens quietly restyling,
// hiding or filtering the wrong box and reporting `applied`, which is invisible to
// the badge, to Re-fit and to the user.
//
// A fingerprint is the answer to "is this still the same region?", asked of a page
// that has moved on. It is scored, and the scoring is built so that **a confident
// wrong answer is impossible**: no amount of positional agreement can carry a
// candidate over the line, a fingerprint with nothing identifying in it declines
// outright, and a winner that is barely ahead of the runner-up is no winner.
// **A threshold nothing clears is a clean `missed`, and that is the point.**
//
// ## Privacy
//
// Same contract as the catalog, and for the same reason — a lens can be read back
// and a fingerprint travels with it. Tags, class tokens, attribute *names*, the
// `role` value (a closed W3C vocabulary, so never something the page wrote),
// counts and doubling bands. Never a character of page text. See the field notes
// on `RegionFingerprint` in `wire.ts` and `PrivacyContractTests` on the Swift side.

/**
 * `floor(log2(1 + value))`, clamped to 0…31.
 *
 * The band definition, shared verbatim with Swift. A fingerprint is compared
 * against a page rendered a month later in a different window, where "1004px from
 * the left" is noise and "roughly a thousand" is signal — and where a feed that
 * gained three cards must not read as a different region.
 */
export function band(value: number): number {
  if (!Number.isFinite(value) || value <= 0) return 0;
  return Math.min(31, Math.floor(Math.log2(1 + value)));
}

/**
 * Attribute *names* worth remembering.
 *
 * `data-*` and `aria-*` are where a site records what a thing is for, and the name
 * survives restyles that rename every class. The excluded ones are state rather
 * than identity: they are added and removed as the user interacts, so a
 * fingerprint taken with a menu open would score its own element down after it
 * closed.
 */
const VOLATILE_ATTRIBUTES = new Set([
  "aria-hidden",
  "aria-selected",
  "aria-current",
  "aria-busy",
  "aria-live",
  "aria-expanded",
]);

const MICRODATA_ATTRIBUTES = ["itemprop", "itemscope", "itemtype"];

const MAX_ATTRIBUTE_NAMES = 16;
const MAX_CLASSES = 12;
const MAX_ANCESTORS = 6;

/**
 * How much each signal is worth.
 *
 * The split is the safety property, not a tuning preference. The identity
 * signals — what the site *calls* this thing — are worth 22 between them; every
 * positional and shape signal together is worth 9.5. So an element that sits in
 * the same place, at the same size, with the same number of children as the
 * region we are looking for, and shares none of its names, tops out at 0.30
 * against a threshold of 0.62. Position can only ever break a tie between
 * candidates that already agree about what they are.
 */
const WEIGHTS = {
  elementID: 8,
  attributeNames: 5,
  classes: 5,
  role: 4,
  ancestorTags: 3,
  childCount: 2,
  textLengthBand: 2,
  rectBand: 1.5,
  siblingIndex: 1,
} as const;

const IDENTITY_KEYS = ["elementID", "attributeNames", "classes", "role"] as const;

/** Below this, no answer. Chosen so that shape and position alone (0.30 of the
 * total when every identity signal is present) cannot reach it. */
const THRESHOLD = 0.62;

/** The winner must be this far clear of the runner-up. Two adjacent cards in a
 * feed differ only by `siblingIndex` and a band or two — about 0.05 — so this is
 * what makes "which of these fifty identical rows did you mean" answer *nothing*
 * instead of answering the first one. */
const MARGIN = 0.12;

/** At least half the identifying evidence the fingerprint carries has to match.
 * A redesign that renames every class but keeps the `data-testid` and the role
 * still clears this; one that changes everything the site called the region does
 * not, and should not. */
const IDENTITY_FLOOR = 0.5;

/** Candidates kept for the second, rect-reading pass. */
const SHORTLIST = 12;

/**
 * A textless structural signature of one element.
 *
 * Built once, when a lens is authored or re-fitted, and stored on the
 * `LensRegion` beside its selectors.
 */
export function buildFingerprint(element: Element): RegionFingerprint {
  const rect = documentRect(element);
  const elementID = regionIdentifier(element);
  const role = roleOf(element);

  return {
    tag: element.localName.toLowerCase(),
    ...(elementID ? { elementID } : {}),
    classes: stableClasses(element).slice(0, MAX_CLASSES),
    attributeNames: attributeNames(element),
    ...(role ? { role } : {}),
    childCount: element.childElementCount,
    textLengthBand: band((element.textContent ?? "").trim().length),
    rectBand: {
      x: band(rect.x),
      y: band(rect.y),
      width: band(rect.width),
      height: band(rect.height),
    },
    siblingIndex: siblingIndex(element),
    ancestorTags: ancestorTags(element),
  };
}

/**
 * The element this fingerprint describes, if the page still contains it.
 *
 * `undefined` is a real answer and the common one after a redesign — the caller
 * should report `missed`, which is what makes the drift badge worth looking at.
 *
 * The tag is a gate rather than a signal: candidates are drawn from
 * `getElementsByTagName`, so a region whose element changed tag is not found. That
 * is deliberate on both counts. It keeps the search to the tens or hundreds of
 * elements that could plausibly be the region instead of the whole document, and a
 * `<div>` where a `<ytd-rich-grid-renderer>` used to be is a rewrite of that part
 * of the page, not the same region wearing a new tag.
 */
export function resolveFingerprint(doc: Document, print: RegionFingerprint): Element | undefined {
  const scale = maxima(print);
  // Nothing to identify it by. A bare `<div>` with no id, no classes, no
  // attributes and no role is not re-findable, and the only thing scoring it
  // could produce is a confident wrong answer from geometry.
  if (scale.identity === 0) return undefined;

  let pool: HTMLCollectionOf<Element>;
  try {
    pool = doc.getElementsByTagName(print.tag);
  } catch {
    return undefined;
  }

  // Top `SHORTLIST` by everything except the rect, which is the one signal that
  // costs a layout read. Held in a small sorted array rather than sorted at the
  // end, so a document with four thousand `<div>`s allocates nothing per element.
  const shortlist: Array<{ element: Element; base: number }> = [];
  let overflow = 0;

  for (let index = 0; index < pool.length; index += 1) {
    const element = pool[index] as Element;
    if (isOurs(element)) continue;
    const base = rawScore(element, print, false).total;

    if (shortlist.length < SHORTLIST) {
      shortlist.push({ element, base });
      shortlist.sort((a, b) => b.base - a.base);
      continue;
    }
    if (base <= (shortlist[SHORTLIST - 1] as { base: number }).base) {
      overflow = Math.max(overflow, base);
      continue;
    }
    overflow = Math.max(overflow, (shortlist.pop() as { base: number }).base);
    shortlist.push({ element, base });
    shortlist.sort((a, b) => b.base - a.base);
  }

  if (shortlist.length === 0) return undefined;

  const scored = shortlist
    .map((entry) => {
      const parts = rawScore(entry.element, print, true);
      return {
        element: entry.element,
        ratio: parts.total / scale.total,
        identityRatio: parts.identity / scale.identity,
      };
    })
    .sort((a, b) => b.ratio - a.ratio);

  const best = scored[0] as { element: Element; ratio: number; identityRatio: number };
  if (best.ratio < THRESHOLD) return undefined;
  if (best.identityRatio < IDENTITY_FLOOR) return undefined;

  // The runner-up is the better of the second shortlisted candidate and a bound on
  // everything that did not make the shortlist: the rect is all such a candidate
  // could still have gained, so adding its full weight cannot understate it.
  const runnerUp = Math.max(
    scored[1]?.ratio ?? 0,
    shortlist.length < SHORTLIST ? 0 : (overflow + WEIGHTS.rectBand) / scale.total,
  );
  if (best.ratio - runnerUp < MARGIN) return undefined;

  return best.element;
}

/**
 * How well one element answers to this fingerprint, from 0 to 1.
 *
 * Exported for tests and for diagnosis. `resolveFingerprint` is the function with
 * an opinion; this one just reports.
 */
export function scoreFingerprint(element: Element, print: RegionFingerprint): number {
  const scale = maxima(print);
  if (scale.total === 0) return 0;
  return rawScore(element, print, true).total / scale.total;
}

interface Score {
  total: number;
  identity: number;
}

/** The most this fingerprint could score — the weights of the signals it actually
 * carries. A print with no role is not penalised for a page with no role, and a
 * print with no id cannot have an id-shaped hole in its denominator. */
function maxima(print: RegionFingerprint): Score {
  let total = 0;
  let identity = 0;
  for (const [key, weight] of Object.entries(WEIGHTS) as Array<[keyof typeof WEIGHTS, number]>) {
    if (!carries(print, key)) continue;
    total += weight;
    if ((IDENTITY_KEYS as readonly string[]).includes(key)) identity += weight;
  }
  return { total, identity };
}

function carries(print: RegionFingerprint, key: keyof typeof WEIGHTS): boolean {
  switch (key) {
    case "elementID":
      return print.elementID !== undefined && print.elementID.length > 0;
    case "attributeNames":
      return print.attributeNames.length > 0;
    case "classes":
      return print.classes.length > 0;
    case "role":
      return print.role !== undefined && print.role.length > 0;
    case "ancestorTags":
      return print.ancestorTags.length > 0;
    default:
      return true;
  }
}

function rawScore(element: Element, print: RegionFingerprint, withRect: boolean): Score {
  let total = 0;
  let identity = 0;
  const add = (key: keyof typeof WEIGHTS, fraction: number) => {
    if (!carries(print, key)) return;
    const earned = WEIGHTS[key] * Math.max(0, Math.min(1, fraction));
    total += earned;
    if ((IDENTITY_KEYS as readonly string[]).includes(key)) identity += earned;
  };

  add("elementID", element.getAttribute("id") === print.elementID ? 1 : 0);
  add("attributeNames", overlap(attributeNames(element), print.attributeNames));
  add("classes", overlap(stableClasses(element).slice(0, MAX_CLASSES), print.classes));
  add("role", roleOf(element) === print.role ? 1 : 0);
  add("ancestorTags", prefixOverlap(ancestorTags(element), print.ancestorTags));
  add("childCount", closeness(element.childElementCount, print.childCount, Math.max(4, print.childCount)));
  add("textLengthBand", closeness(band((element.textContent ?? "").trim().length), print.textLengthBand, 3));
  add("siblingIndex", closeness(siblingIndex(element), print.siblingIndex, 4));

  if (withRect) {
    const rect = documentRect(element);
    const bands: RegionRectBand = {
      x: band(rect.x),
      y: band(rect.y),
      width: band(rect.width),
      height: band(rect.height),
    };
    const parts = (["x", "y", "width", "height"] as const).map((key) =>
      closeness(bands[key], print.rectBand[key], 2),
    );
    add("rectBand", parts.reduce((sum, part) => sum + part, 0) / parts.length);
  }

  return { total, identity };
}

/** Jaccard: shared over combined. Two names in common out of two is a match; two
 * out of twenty is a coincidence, and the denominator is what says so. */
function overlap(left: string[], right: string[]): number {
  if (left.length === 0 && right.length === 0) return 1;
  const seen = new Set(right);
  let shared = 0;
  const union = new Set(right);
  for (const value of left) {
    if (seen.has(value)) shared += 1;
    union.add(value);
  }
  return union.size === 0 ? 1 : shared / union.size;
}

/** How much of the stored ancestor chain the candidate still sits under, counted
 * from the parent outwards — because a wrapper added at the top of the page moves
 * every element down one and should not erase the whole chain. */
function prefixOverlap(left: string[], right: string[]): number {
  if (right.length === 0) return 1;
  let shared = 0;
  while (shared < left.length && shared < right.length && left[shared] === right[shared]) {
    shared += 1;
  }
  return shared / right.length;
}

/** 1 when equal, falling to 0 `tolerance` steps away. */
function closeness(value: number, expected: number, tolerance: number): number {
  if (tolerance <= 0) return value === expected ? 1 : 0;
  return Math.max(0, 1 - Math.abs(value - expected) / tolerance);
}

function attributeNames(element: Element): string[] {
  const names: string[] = [];
  for (const name of element.getAttributeNames()) {
    const lowered = name.toLowerCase();
    if (lowered.startsWith("data-zentic")) continue;
    if (VOLATILE_ATTRIBUTES.has(lowered)) continue;
    if (
      lowered.startsWith("data-") ||
      lowered.startsWith("aria-") ||
      MICRODATA_ATTRIBUTES.includes(lowered)
    ) {
      names.push(lowered);
    }
  }
  return names.sort().slice(0, MAX_ATTRIBUTE_NAMES);
}

function roleOf(element: Element): string | undefined {
  const role = element.getAttribute("role");
  return role === null || role.length === 0 ? undefined : role;
}

function siblingIndex(element: Element): number {
  let index = 0;
  for (
    let sibling = element.previousElementSibling;
    sibling !== null;
    sibling = sibling.previousElementSibling
  ) {
    if (sibling.localName === element.localName) index += 1;
  }
  return index;
}

function ancestorTags(element: Element): string[] {
  const tags: string[] = [];
  for (
    let parent = element.parentElement;
    parent !== null && tags.length < MAX_ANCESTORS;
    parent = parent.parentElement
  ) {
    tags.push(parent.localName.toLowerCase());
  }
  return tags;
}

/** Document coordinates, matching the catalog's rect: a fingerprint taken before
 * the user scrolled must describe the same box as one taken after. */
function documentRect(element: Element): { x: number; y: number; width: number; height: number } {
  try {
    const rect = element.getBoundingClientRect();
    const view = element.ownerDocument.defaultView;
    return {
      x: rect.left + (view?.scrollX ?? 0),
      y: rect.top + (view?.scrollY ?? 0),
      width: rect.width,
      height: rect.height,
    };
  } catch {
    return { x: 0, y: 0, width: 0, height: 0 };
  }
}
