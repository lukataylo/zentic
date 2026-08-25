import { elementArea, viewportSize } from "../dom.js";
import { cssPath, pathPattern } from "../skeleton.js";
import type { ItemFieldCandidate, RegionCandidate, RegionCatalog, RegionRect } from "../wire.js";

// Page segmentation: the addressable parts of a live page, as offered to a model.
//
// **Privacy contract, same one `skeleton.ts` carries and for the same reason: a
// catalog carries no page characters.** Tags, class and id tokens, ARIA roles,
// attribute *names*, geometry, counts, and text *lengths*. Never the text itself.
// A catalog is the artefact that leaves the device when the user asks for a lens,
// so if a single field could carry content, "your reading never goes to a model"
// would be false. `PrivacyContractTests` asserts this from the Swift side;
// `regions.test.ts` asserts it from here, because the field that leaks would be
// added here.
//
// The other job of this file is *addressability*. A lens op names a region, and
// the region is only as good as its selectors: a lens that survives a redesign is
// one anchored to a `#id`, a custom-element name or a landmark, and one anchored
// to a generated class hash drifts within the week. So every candidate carries a
// best-first selector list and the op runner takes the first that still matches.
//
// Two rules learned from running this against fourteen live sites, both of which
// cost more than they look like they cost:
//
//  - **A candidate is only offered if it matches exactly one element.** NYT hands
//    `div.jXhsNG_gridCell.jXhsNG_positioned` — 160 elements — to one outlined box,
//    Substack one matching 125. `found[0] === element` said yes to both, and
//    `hide` then removed 160 boxes and reported `applied`. Worse, an ambiguous
//    anchor never *misses*, so it pre-empts the fingerprint fallback that exists
//    precisely to notice a page that changed underneath.
//  - **Work is done for the survivors, not for the document.** Ranking is by area
//    and text length, both of which are readable without touching a selector
//    engine, so the limit is applied to the ranked list first and selectors,
//    repeated-item detection and item fields are derived for the <=120 that
//    survive. Deriving first and truncating after is how a 500-card page turned
//    into 19,128 document queries over 2.5M matched elements, nearly all of it
//    thrown away by the limit. The same page now costs 130 queries over 6,157.

/** Elements that never *are* a region: they hold no layout of their own. */
const IGNORED_TAGS = new Set([
  "script",
  "style",
  "link",
  "meta",
  "noscript",
  "template",
  "br",
  "wbr",
  "svg",
  "path",
  "circle",
  "rect",
  "g",
  "defs",
  "use",
  "symbol",
  "source",
  "track",
  "col",
  "colgroup",
  "option",
]);

/** Inline elements are never a region — you cannot hide or move half a sentence. */
const INLINE_TAGS = new Set([
  "a",
  "b",
  "i",
  "em",
  "strong",
  "span",
  "small",
  "code",
  "kbd",
  "sub",
  "sup",
  "abbr",
  "time",
  "label",
  "u",
  "s",
  "mark",
  "cite",
  "q",
  "var",
  "samp",
  "bdi",
  "bdo",
  "ruby",
]);

const MEDIA_TAGS = new Set(["video", "audio", "iframe", "canvas", "embed", "object"]);

/** Below this an element is too small to be worth naming, in text or in pixels. */
const MIN_TEXT_LENGTH = 40;
const MIN_AREA = 4000;

/** A repeated-sibling run this long is a feed, and shorter is a coincidence. */
const MIN_REPEATED_ITEMS = 3;

/** Landmarks are always addressable, however small — `<nav>` is often 20 characters. */
const LANDMARK_TAGS = new Set(["header", "nav", "main", "aside", "footer", "form", "section"]);

const LANDMARK_ROLES = new Set([
  "banner",
  "navigation",
  "main",
  "complementary",
  "contentinfo",
  "search",
  "feed",
  "region",
]);

/** id/class tokens that name a comment thread on essentially every CMS. */
const COMMENT_HINT = /(^|[-_])(comments?|disqus|respond|livefyre|coral|discussion)([-_]|$)/i;

/**
 * Attributes a site uses to name a part of itself, best first.
 *
 * These are the anchors that survive a restyle, because they are read by the
 * site's own test suite or by a schema consumer rather than by its stylesheet.
 * X's timeline is addressed almost entirely by `data-testid`
 * (`primaryColumn`, `sidebarColumn`, `cellInnerDiv`) and carries no usable class.
 *
 * `aria-label` is last because it is *localised*: an anchor written against the
 * English label stops matching when the same user opens the site in French. It is
 * also the one attribute here whose value can be page content — an article card's
 * label is its headline — so it is only used on a landmark, where the label is the
 * site's name for the region rather than the text of an item. Invariant 4 has no
 * exception for content that arrived in an attribute.
 */
const STABLE_ATTRIBUTES = [
  "data-testid",
  "data-test-id",
  "data-component-type",
  "data-view-name",
  "itemprop",
  "aria-label",
];

/** Attribute values usable verbatim inside `[attr="…"]`. Deliberately narrow: no
 * quote, backslash or bracket can appear, so the selector cannot be reshaped by
 * the value. */
const ATTRIBUTE_VALUE = /^[A-Za-z0-9][A-Za-z0-9 ._:/-]{0,39}$/;

/** What a `harvest` may read off a field element. The same closed set as the
 * wire's `HarvestAttribute`, minus `text`, which is reported as a length. */
const HARVESTABLE_ATTRIBUTES = ["href", "src", "alt", "title"];

/** Elements that are a field even when their text belongs to a child. Every feed
 * on the web writes a headline as `<h3><a>…</a></h3>`, and "it has no text of its
 * own" would drop the single most useful field on the card. A `<div>` in the same
 * position is a wrapper, which is why this is a list and not a rule. */
const FIELD_TAGS = new Set([
  "h1",
  "h2",
  "h3",
  "h4",
  "h5",
  "h6",
  "time",
  "blockquote",
  "figcaption",
  "caption",
  "summary",
  "cite",
  "dt",
  "dd",
  "th",
  "td",
  "li",
]);

/** Fields offered per item. Twelve is a card's worth: a headline, a link, an
 * image, a byline, a timestamp and change. */
const MAX_ITEM_FIELDS = 12;

export interface RegionCatalogOptions {
  url: string;
  /** `Budget.lensRegionCandidateLimit`. */
  limit: number;
}

/** What the cheap first pass knows about one element. Everything here is readable
 * without a selector engine and without a subtree walk of its own. */
interface Scan {
  element: Element;
  tag: string;
  role: string | undefined;
  textLength: number;
  linkCount: number;
  paragraphCount: number;
  imageCount: number;
  mediaCount: number;
  rect: RegionRect;
  area: number;
}

/**
 * Build the catalog of regions for this document.
 *
 * Two passes, and the split is the whole performance story. The first reads
 * geometry, counts and text lengths — one bottom-up tally for the whole document
 * rather than a `querySelectorAll` per element per counter — and ranks. Only then
 * is the limit applied, and only the survivors pay for selector derivation,
 * repeated-item detection and item fields, each of which touches the selector
 * engine several times.
 *
 * Candidates are ranked by area before truncation, for the same reason the
 * skeleton is: when the list has to be cut, the parts worth keeping are the big
 * structural boxes a user would point at, not the hundredth nested wrapper. Ids
 * are assigned after ranking so `r0` is always the largest thing on the page,
 * which makes a catalog readable in a diff.
 */
export function buildRegionCatalog(doc: Document, options: RegionCatalogOptions): RegionCatalog {
  const view = viewportSize(doc);
  let origin = "";
  let pattern = "/";
  try {
    const url = new URL(options.url);
    // A lens is stored per *host*, not per origin: a site that redirects between
    // http and https is one site to the user, and to their lens.
    origin = url.host;
    pattern = pathPattern(url.pathname);
  } catch {
    // Defaults. A catalog without an origin still describes the page correctly;
    // it just cannot be saved against one.
  }

  const all = Array.from(doc.body?.querySelectorAll("*") ?? []);
  const tallies = tally(all);
  const repeats = new Map<Element, Repeated | undefined>();
  const suppressed = collapseWrapperTowers(all, tallies, repeats);

  const scanned: Scan[] = [];
  for (const element of all) {
    const tag = element.localName.toLowerCase();
    if (IGNORED_TAGS.has(tag) || INLINE_TAGS.has(tag)) continue;
    if (isOurs(element)) continue;
    if (suppressed.has(element)) continue;

    const counts = tallies.get(element);
    if (!counts) continue;

    const role = element.getAttribute("role") ?? undefined;
    const rect = rectOf(element);
    // `elementArea` only when the rect gave nothing: it re-reads the box and then
    // falls back to presentational attributes, which is the only signal a
    // `<canvas>` in an unlaid-out document has. Paying for it per element was
    // paying twice for the same measurement.
    const area = rect.width * rect.height || elementArea(element);
    const mediaCount = MEDIA_TAGS.has(tag) ? 1 : counts.media;

    // Geometry is a bonus, never a requirement: `getBoundingClientRect()` is all
    // zeros in jsdom and in any document that has not been laid out, so an
    // element earns its place structurally and geometry only adds to it.
    //
    // The repeated-children test here is the cheap one — three element children
    // sharing a tag. The real grouping runs on the survivors only, and it is
    // allowed to decline what this admitted.
    const worthNaming =
      LANDMARK_TAGS.has(tag) ||
      (role !== undefined && LANDMARK_ROLES.has(role)) ||
      mediaCount > 0 ||
      counts.text >= MIN_TEXT_LENGTH ||
      area >= MIN_AREA ||
      hasRepeatedChildren(element);
    if (!worthNaming) continue;

    scanned.push({
      element,
      tag,
      role,
      textLength: counts.text,
      linkCount: counts.links,
      paragraphCount: counts.paragraphs,
      imageCount: counts.images,
      mediaCount,
      rect,
      area,
    });
  }

  scanned.sort((a, b) => b.area - a.area || b.textLength - a.textLength);

  const matchCounts = new Map<string, number>();
  const candidates: RegionCandidate[] = scanned
    .slice(0, Math.max(1, options.limit))
    .map((scan, index) => {
      const repeated = repeatedItems(scan.element, repeats);
      const selectors = deriveSelectors(doc, scan.element, repeats, matchCounts);
      const elementID = regionIdentifier(scan.element, repeats);

      return {
        id: `r${index}`,
        selector: selectors[0] ?? cssPath(scan.element),
        alternates: selectors.slice(1),
        tag: scan.tag,
        classes: stableClasses(scan.element).slice(0, 12),
        kindGuess: guessKind(scan.element, {
          tag: scan.tag,
          role: scan.role,
          textLength: scan.textLength,
          linkCount: scan.linkCount,
          mediaCount: scan.mediaCount,
          itemCount: repeated?.count ?? 0,
        }),
        rect: scan.rect,
        depth: depthOf(scan.element),
        textLength: scan.textLength,
        linkCount: scan.linkCount,
        paragraphCount: scan.paragraphCount,
        imageCount: scan.imageCount,
        itemCount: repeated?.count ?? 0,
        itemFields: repeated ? itemFields(scan.element, repeated.selector) : [],
        ...(elementID ? { elementID } : {}),
        ...(scan.role ? { role: scan.role } : {}),
        ...(repeated ? { itemSelector: repeated.selector } : {}),
      };
    });

  return {
    origin,
    pathPattern: pattern,
    viewport: { width: Math.round(view.width), height: Math.round(view.height) },
    candidates,
  };
}

/** Our own overlay and inserted nodes are not part of the page and never a region.
 * Exported so `fingerprint.ts` skips them from one definition rather than two. */
export function isOurs(element: Element): boolean {
  const tag = element.localName.toLowerCase();
  if (tag.startsWith("zentic-")) return true;
  const id = element.getAttribute("id");
  return id !== null && id.startsWith("zentic-");
}

// MARK: - The counting pass

interface Counts {
  /** `element.textContent.trim().length`, computed bottom-up. */
  text: number;
  links: number;
  paragraphs: number;
  images: number;
  media: number;
}

/** Text as it combines: the total length plus the whitespace at each end, which is
 * what lets a trimmed length be summed rather than re-measured. */
interface TextRun {
  total: number;
  lead: number;
  trail: number;
  blank: boolean;
}

const EMPTY_RUN: TextRun = { total: 0, lead: 0, trail: 0, blank: true };

/**
 * Every count the ranking pass needs, for every element, in one bottom-up sweep.
 *
 * The version this replaces asked the document four questions per element —
 * `a[href]`, `p`, `img,picture,figure`, `video,iframe,audio` — each of which walks
 * that element's whole subtree, and then read `textContent`, which builds the
 * subtree's text into a string only to measure it. Both are quadratic in a deep
 * page: on a 500-card feed the counters alone visited well over a million
 * elements, all of it recomputing what a parent's children already knew.
 *
 * Reverse document order means every child is finished before its parent, so a
 * parent is the sum of its children plus its own text nodes.
 */
function tally(all: Element[]): Map<Element, Counts> {
  const counts = new Map<Element, Counts>();
  const runs = new Map<Element, TextRun>();

  for (let index = all.length - 1; index >= 0; index -= 1) {
    const element = all[index] as Element;
    let run = EMPTY_RUN;
    let links = 0;
    let paragraphs = 0;
    let images = 0;
    let media = 0;

    for (let node = element.firstChild; node !== null; node = node.nextSibling) {
      if (node.nodeType === 3 || node.nodeType === 4) {
        run = joinRuns(run, textRun(node.nodeValue ?? ""));
        continue;
      }
      if (node.nodeType !== 1) continue;

      const child = node as Element;
      const inner = counts.get(child);
      run = joinRuns(run, runs.get(child) ?? EMPTY_RUN);
      if (inner) {
        links += inner.links;
        paragraphs += inner.paragraphs;
        images += inner.images;
        media += inner.media;
      }

      const tag = child.localName.toLowerCase();
      if (tag === "a" && child.hasAttribute("href")) links += 1;
      else if (tag === "p") paragraphs += 1;
      else if (tag === "img" || tag === "picture" || tag === "figure") images += 1;
      else if (tag === "video" || tag === "iframe" || tag === "audio") media += 1;
    }

    runs.set(element, run);
    counts.set(element, { text: trimmedLength(run), links, paragraphs, images, media });
  }

  return counts;
}

function textRun(value: string): TextRun {
  const total = value.length;
  if (total === 0) return EMPTY_RUN;
  const lead = total - value.replace(/^\s+/, "").length;
  if (lead === total) return { total, lead: total, trail: total, blank: true };
  const trail = total - value.replace(/\s+$/, "").length;
  return { total, lead, trail, blank: false };
}

/** Concatenation, in the only two quantities that matter: an all-whitespace run
 * merges into its neighbour's edge, so `<b> </b>` between two words does not read
 * as trimmable text. */
function joinRuns(left: TextRun, right: TextRun): TextRun {
  return {
    total: left.total + right.total,
    lead: left.blank ? left.total + right.lead : left.lead,
    trail: right.blank ? right.total + left.trail : right.trail,
    blank: left.blank && right.blank,
  };
}

function trimmedLength(run: TextRun): number {
  return run.blank ? 0 : run.total - run.lead - run.trail;
}

/** Three element children sharing a tag — the cheap precondition for a feed. The
 * real grouping is `repeatedItems`, and it is allowed to say no to this. */
function hasRepeatedChildren(element: Element): boolean {
  if (element.childElementCount < MIN_REPEATED_ITEMS) return false;
  const tags = new Map<string, number>();
  for (let child = element.firstElementChild; child !== null; child = child.nextElementSibling) {
    const tag = child.localName.toLowerCase();
    const next = (tags.get(tag) ?? 0) + 1;
    if (next >= MIN_REPEATED_ITEMS) return true;
    tags.set(tag, next);
  }
  return false;
}

/**
 * One candidate per tower of single-child wrappers.
 *
 * Measured on every site probed: 40-65% of the candidate budget was spent on
 * rungs. GitHub's repository page has fifteen consecutive `div`s, every one with
 * `textLength` 5896 and an eighteen-segment path, and they are the same box to
 * anyone who might point at one. Offering all fifteen spends the budget the model
 * reads on fifteen ways to say one thing, and pushes the actual sidebar off the
 * end of the list.
 *
 * A rung is an element with exactly one element child and no text of its own. The
 * chain keeps the rung with the strongest identity — an id, then stable classes,
 * then the outermost, which is the biggest box and the one a click lands on.
 * Landmarks, roled elements and custom elements are never rungs: those are names
 * the site chose, and a name is exactly what makes a region addressable.
 */
function collapseWrapperTowers(
  all: Element[],
  tallies: Map<Element, Counts>,
  repeats: Map<Element, Repeated | undefined>,
): Set<Element> {
  const suppressed = new Set<Element>();
  const isRung = (element: Element): boolean => {
    if (element.childElementCount !== 1) return false;
    const tag = element.localName.toLowerCase();
    if (tag.includes("-") || LANDMARK_TAGS.has(tag)) return false;
    const role = element.getAttribute("role");
    if (role !== null && LANDMARK_ROLES.has(role)) return false;
    const child = element.firstElementChild as Element;
    const own = tallies.get(element);
    const inner = tallies.get(child);
    return own !== undefined && inner !== undefined && own.text === inner.text;
  };

  for (const element of all) {
    if (!isRung(element)) continue;
    const parent = element.parentElement;
    // Mid-chain: the chain was walked from its top already.
    if (parent && isRung(parent)) continue;

    const chain: Element[] = [];
    for (let rung: Element | null = element; rung !== null && isRung(rung); ) {
      chain.push(rung);
      rung = rung.firstElementChild;
    }
    if (chain.length < 2) continue;

    const keep =
      chain.find((rung) => regionIdentifier(rung, repeats) !== undefined) ??
      chain.find((rung) => stableClasses(rung).length > 0) ??
      (chain[0] as Element);
    for (const rung of chain) {
      if (rung !== keep) suppressed.add(rung);
    }
  }

  return suppressed;
}

// MARK: - Selectors

/**
 * Best-first selectors for one element.
 *
 * The order encodes how long each kind of anchor survives a redesign, and it was
 * reordered against fourteen live sites:
 *
 *  1. **`#id`** — an anchor the site's own JavaScript also depends on, so it is
 *     one of the last things to change. Provided it names a *region* and not an
 *     item; see `regionIdentifier`.
 *  2. **A custom-element tag** — `shreddit-post`, `ytd-rich-grid-renderer`. The
 *     name is passed to the site's own `customElements.define()`, so renaming it
 *     breaks the site's own upgrade path. That is a stronger guarantee than an id,
 *     which only has to satisfy a stylesheet. These were derivable and never
 *     offered, because a bare tag was pushed only for landmarks.
 *  3. **A stable attribute** — `data-testid` and friends, the anchors a site's own
 *     test suite depends on. X's timeline has nothing else.
 *  4. **`[role=…]`** — semantics change less often than markup. Facebook's
 *     `div[role="feed"]` was already being derived and was ranked *fourth*, behind
 *     atomic classes that match a thousand elements each and therefore never stop
 *     matching.
 *  5. **`tag.class.class`** — a hand-written class name ("sidebar", "comments")
 *     outlives a layout change. Generated ones do not, so `stableClasses` throws
 *     them away first.
 *  6. **A landmark tag** — weaker than the classes above it only because a page
 *     usually has several `<section>`s and one `.rail.sidebar`.
 *  7. **The structural path** — always works, always the first thing to break.
 *
 * Every entry is verified to match *exactly one* element before it ships. A
 * selector matching 160 boxes is not a worse anchor than the path, it is a
 * different op: `hide` on it empties the page.
 */
function deriveSelectors(
  doc: Document,
  element: Element,
  repeats: Map<Element, Repeated | undefined>,
  matchCounts: Map<string, number>,
): string[] {
  const out: string[] = [];
  const push = (selector: string | undefined) => {
    if (!selector || out.includes(selector)) return;
    if (!resolvesUniquely(doc, selector, element, matchCounts)) return;
    out.push(selector);
  };

  const tag = element.localName.toLowerCase();

  const id = regionIdentifier(element, repeats);
  if (id) push(`#${id}`);

  // A custom element: `<shreddit-post>`, `<ytd-rich-grid-renderer>`. Only useful
  // when there is one of them, which `resolvesUniquely` decides — a feed's fifty
  // `ytd-rich-item-renderer`s are items, and this is where they drop out.
  if (tag.includes("-")) push(tag);

  for (const name of STABLE_ATTRIBUTES) {
    push(attributeSelector(element, tag, name));
  }

  const role = stableIdentifier(element.getAttribute("role"));
  if (role) push(`${tag}[role="${role}"]`);

  const classes = stableClasses(element);
  if (classes.length > 0) {
    // Two tokens is the sweet spot: one is often shared by a dozen boxes, three
    // starts encoding state classes ("is-open") that flip at run time.
    push(`${tag}.${classes.slice(0, 2).join(".")}`);
    push(`${tag}.${classes[0]}`);
  }

  if (LANDMARK_TAGS.has(tag)) push(tag);

  push(cssPath(element));
  return out;
}

/** `tag[attr="value"]`, when the site put a usable name in that attribute. */
function attributeSelector(element: Element, tag: string, name: string): string | undefined {
  const value = element.getAttribute(name);
  if (value === null || !ATTRIBUTE_VALUE.test(value)) return undefined;
  if (name === "aria-label" && !isLandmark(element, tag)) return undefined;
  return `${tag}[${name}="${value}"]`;
}

function isLandmark(element: Element, tag: string): boolean {
  if (LANDMARK_TAGS.has(tag)) return true;
  const role = element.getAttribute("role");
  return role !== null && LANDMARK_ROLES.has(role);
}

/**
 * Does `selector` match this element and *nothing else*?
 *
 * The uniqueness half is the fix for the worst measured defect in the feature.
 * `found[0] === element` accepted `div.jXhsNG_gridCell.jXhsNG_positioned` as the
 * preferred anchor for one NYT card — one hundred and sixty elements — because
 * that card happened to be first in document order. Every op then applied to all
 * hundred and sixty and reported `applied`.
 *
 * `matches()` first, because it answers from the element's own attributes without
 * touching the document, so a selector that was derived wrongly or that this
 * engine cannot parse costs nothing. Only a selector that already matches is worth
 * a document query, and since the element is then guaranteed to be in the result,
 * a length of one *is* uniqueness.
 *
 * The counts are memoised for the length of one build. A feed of five hundred
 * identically-marked-up cards derives the *same* class selector for every survivor
 * that sits in it, and asking the document five hundred times what it already
 * answered is most of what the second pass costs.
 */
function resolvesUniquely(
  doc: Document,
  selector: string,
  element: Element,
  matchCounts: Map<string, number>,
): boolean {
  try {
    if (!element.matches(selector)) return false;
    let count = matchCounts.get(selector);
    if (count === undefined) {
      count = doc.querySelectorAll(selector).length;
      matchCounts.set(selector, count);
    }
    return count === 1;
  } catch {
    // jsdom's selector engine rejects a few things WebKit accepts. An unusable
    // alternate is dropped rather than shipped untested.
    return false;
  }
}

/**
 * Class tokens worth anchoring to.
 *
 * Generated class names change on every build of the site, so a lens anchored to
 * one is drift waiting to happen. They are dropped rather than merely ranked
 * lower, because a selector list whose second entry is guaranteed to rot is a list
 * with one real entry and one lie in it.
 *
 * The doc comment here used to claim exactly that while the filter caught one of
 * the five formats actually in the wild. Measured, these all passed:
 * `prc-PageLayout-Content-xWL-A` (GitHub), `eu3y8st0` (NYT/Emotion),
 * `container-k4OAt1` (Substack), `x1i10hfl` (Meta) — only X's `css-175oi2r` was
 * caught. See `looksGenerated` for what each rule is for.
 */
export function stableClasses(element: Element): string[] {
  return Array.from(element.classList).filter((token) => {
    if (!isPlainIdentifier(token) || token.length > 48) return false;
    return !looksGenerated(token);
  });
}

/**
 * Does this name look like a build tool wrote it?
 *
 * Three rules, one per shape that a bundler actually emits, and each was written
 * against a name observed on a live site:
 *
 *  1. **A lone token with digits mixed into it.** `eu3y8st0`, `x1i10hfl`. The
 *     digits must be *interleaved* — a trailing number is how a person writes
 *     `heading2` and `col3`, and rejecting those would throw away real anchors.
 *  2. **A trailing segment with digits mixed into it.** `css-175oi2r`,
 *     `container-k4OAt1`, `t3_1vx81cr`. The readable prefix is the site's, the
 *     suffix is the hash, and the hash is what changes.
 *  3. **A segment that mixes case in a way no one types.** `prc-PageLayout-…-xWL`,
 *     `mwDLo`. An uppercase letter inside a word is followed by a lowercase one
 *     when a person camel-cased it; `xWL` and `DLo` are base62 from a hash
 *     function. An all-uppercase segment (`CTA`, `NAV`) is left alone.
 *
 * Exported because ids and classes rot the same way and there should be one
 * definition of "generated" for both, and because `fingerprint.ts` must agree
 * with this file about which tokens are worth storing.
 */
export function looksGenerated(token: string): boolean {
  const segments = token.split(/[-_]/).filter((segment) => segment.length > 0);
  if (segments.length === 0) return false;

  if (segments.length === 1 && token.length >= 6 && hasInterleavedDigit(token)) return true;

  const last = segments[segments.length - 1] as string;
  if (last.length >= 4 && hasInterleavedDigit(last)) return true;

  for (const segment of segments) {
    if (mixesCaseUnnaturally(segment)) return true;
  }
  return false;
}

/** A letter and a digit, with at least one digit somewhere other than the trailing
 * run — `1vx81cr` yes, `heading2` no. */
function hasInterleavedDigit(value: string): boolean {
  if (!/[A-Za-z]/.test(value) || !/[0-9]/.test(value)) return false;
  return /[0-9]/.test(value.replace(/[0-9]+$/, ""));
}

/** An uppercase letter not followed by a lowercase one, in a segment that is not
 * simply an acronym. `PageLayout` no, `xWL` yes, `NAV` no. */
function mixesCaseUnnaturally(segment: string): boolean {
  if (!/[A-Z]/.test(segment) || !/[a-z]/.test(segment)) return false;
  for (let index = 0; index < segment.length; index += 1) {
    const character = segment[index] as string;
    if (character < "A" || character > "Z") continue;
    const next = segment[index + 1];
    if (next === undefined || next < "a" || next > "z") return true;
  }
  return false;
}

/**
 * An id or role usable verbatim in a selector.
 *
 * Anything needing escaping is rejected instead of escaped: `CSS.escape` is not
 * present in every environment this code runs in, and a half-escaped selector
 * silently matches the wrong node. The structural path is always there as the
 * fallback, so rejecting costs nothing.
 */
export function stableIdentifier(value: string | null): string | undefined {
  if (!value) return undefined;
  if (!isPlainIdentifier(value) || value.length > 48) return undefined;
  if (/\d{4,}/.test(value)) return undefined;
  return value;
}

/**
 * An id that names a *region* rather than one row of a feed.
 *
 * `stableIdentifier` had no generated-name test at all, and ids rot in both of the
 * ways a class does plus one of their own:
 *
 *  - **Generated.** Wikipedia's Parsoid ids (`#mwDLo`) are reassigned every time
 *    an article is re-rendered. Handled by `looksGenerated`.
 *  - **Content-derived.** Reddit's `shreddit-post` derives to `#t3_1vx81cr`, and
 *    that was its *first-choice* selector: an anchor to one specific post, dead
 *    the moment the feed moves, which for a feed is immediately. The hash shape
 *    catches this one, but `#story-osprey-nesting` has the same problem with none
 *    of the hash.
 *
 * So the last rule is positional rather than lexical: an element that sits in a
 * detected repeated run, whose siblings in that run also carry ids, sharing a
 * common prefix, with a volatile tail — that is an item id, and the region is the
 * container. Three conditions rather than one because the alternative rejects
 * `#header`/`#main`/`#footer` for being sibling `div`s with ids, which is a 2004
 * layout, not a feed.
 */
export function regionIdentifier(
  element: Element,
  repeats?: Map<Element, Repeated | undefined>,
): string | undefined {
  const id = stableIdentifier(element.getAttribute("id"));
  if (id === undefined) return undefined;
  if (looksGenerated(id)) return undefined;
  if (isItemIdentifier(element, id, repeats)) return undefined;
  return id;
}

function isItemIdentifier(
  element: Element,
  id: string,
  repeats?: Map<Element, Repeated | undefined>,
): boolean {
  const parent = element.parentElement;
  if (!parent) return false;
  const run = repeatedItems(parent, repeats);
  if (!run || !run.items.includes(element)) return false;

  const siblingIDs: string[] = [];
  for (const item of run.items) {
    if (item === element) continue;
    const value = item.getAttribute("id");
    if (value) siblingIDs.push(value);
  }
  if (siblingIDs.length < 2) return false;

  const prefix = commonPrefix([id, ...siblingIDs]);
  if (prefix.length < 2) return false;

  // The tails are what tells a feed from a layout: `t3_…`/`t3_…` differ by a hash,
  // `nav-primary`/`nav-secondary` differ by a word someone chose.
  return [id, ...siblingIDs].some((value) => {
    const tail = value.slice(prefix.length);
    return tail.length <= 2 || /[0-9]/.test(tail);
  });
}

function commonPrefix(values: string[]): string {
  let prefix = values[0] ?? "";
  for (const value of values) {
    let index = 0;
    while (index < prefix.length && index < value.length && prefix[index] === value[index]) {
      index += 1;
    }
    prefix = prefix.slice(0, index);
    if (prefix.length === 0) break;
  }
  return prefix;
}

function isPlainIdentifier(value: string): boolean {
  return /^-?[A-Za-z_][A-Za-z0-9_-]*$/.test(value);
}

// MARK: - Kind

interface KindSignals {
  tag: string;
  role: string | undefined;
  textLength: number;
  linkCount: number;
  mediaCount: number;
  itemCount: number;
}

/**
 * What this region probably is, for the model and for the editor overlay.
 *
 * Deliberately ordered from most explicit to most inferred. A site that declares
 * `role="feed"` gets believed; one that declares nothing is judged by shape. The
 * guess is advisory — nothing in the op runner branches on it — so being wrong
 * costs a slightly worse suggestion, never a broken page.
 */
function guessKind(element: Element, signals: KindSignals): string {
  const { tag, role } = signals;

  // Comments first: they are usually inside `<main>`, and calling the comment
  // thread "main" would make "hide the comments" name the article.
  if (hasCommentHint(element)) return "comments";

  if (tag === "header" || role === "banner") return "header";
  if (tag === "footer" || role === "contentinfo") return "footer";
  if (tag === "nav" || role === "navigation") return "nav";
  if (tag === "aside" || role === "complementary") return "aside";
  if (tag === "main" || role === "main") return "main";

  if (role === "feed" || signals.itemCount >= MIN_REPEATED_ITEMS) return "feed";

  if (MEDIA_TAGS.has(tag)) return "media";
  // A box that is mostly a player: media present and almost no prose around it.
  if (signals.mediaCount > 0 && signals.textLength < 200) return "media";

  // Link-dense and text-thin is a menu whatever it calls itself: many links, and
  // only a couple of words behind each one.
  if (signals.linkCount >= 5 && signals.textLength < signals.linkCount * 24) return "nav";

  return "unknown";
}

function hasCommentHint(element: Element): boolean {
  const id = element.getAttribute("id");
  if (id && COMMENT_HINT.test(id)) return true;
  for (const token of Array.from(element.classList)) {
    if (COMMENT_HINT.test(token)) return true;
  }
  return false;
}

// MARK: - Repeated items

export interface Repeated {
  count: number;
  selector: string;
  items: Element[];
}

/** `repeatedItems` memoised for one catalog build. A region asks for its own run
 * and `regionIdentifier` asks for its parent's, so most elements are asked twice. */
function repeatedItems(
  element: Element,
  cache?: Map<Element, Repeated | undefined>,
): Repeated | undefined {
  if (!cache) return detectRepeatedItems(element);
  if (cache.has(element)) return cache.get(element);
  const found = detectRepeatedItems(element);
  cache.set(element, found);
  return found;
}

/**
 * The repeated-child run inside this element, if there is one.
 *
 * This is the feed signal, and it is what makes a timeline addressable: without
 * it a lens can only hide the whole rail, and with it a lens can filter the items
 * inside. Children are grouped by tag plus stable classes, and the largest group
 * wins — a feed with an ad card every fifth slot still reports a run that covers
 * both, because one card and one ad are both one row.
 *
 * **It declines when the winning run is several rows per item.** Measured on Hacker
 * News: one logical story is three sibling `<tr>`s, so grouping offers `:scope >
 * tr` at 92 against `tr.athing` at 30. Filtering on the 92 hides the title row of
 * a story and orphans its score row, and reports `applied, 92 matched`; filtering
 * on the 30 does the same thing from the other end. Neither run is a list of
 * stories, so neither is offered, and "we could not find the items" is the honest
 * answer. A bare tag running at twice the count of a qualified one inside it is
 * that shape; below twice it is the ad-card case above, where the extra rows are
 * peers rather than parts.
 */
function detectRepeatedItems(element: Element): Repeated | undefined {
  const children = Array.from(element.children).filter(
    (child) => !IGNORED_TAGS.has(child.localName.toLowerCase()) && !isOurs(child),
  );
  if (children.length < MIN_REPEATED_ITEMS) return undefined;

  const groups = new Map<string, number>();
  const bump = (key: string) => groups.set(key, (groups.get(key) ?? 0) + 1);

  for (const child of children) {
    const tag = child.localName.toLowerCase();
    const classes = stableClasses(child).slice(0, 2);
    bump(tag);
    if (classes.length > 0) bump(`${tag}.${classes.join(".")}`);
  }

  let best: { selector: string; count: number } | undefined;
  for (const [key, count] of groups) {
    if (count < MIN_REPEATED_ITEMS) continue;
    // Prefer the more specific signature at equal count: `article.card` names one
    // kind of row, `article` names whatever else the site puts in the same list.
    const better =
      best === undefined ||
      count > best.count ||
      (count === best.count && key.length > best.selector.length);
    if (better) best = { selector: key, count };
  }

  if (!best) return undefined;
  if (isMultiRowRun(best, groups)) return undefined;

  // `:scope >` because an item selector is used as `region.querySelectorAll(sel)`
  // and a feed of cards very often contains nested cards — a quoted post inside a
  // post. Without the child combinator, filtering a timeline would also filter
  // the quotes inside it.
  const selector = `:scope > ${best.selector}`;
  try {
    const matched = Array.from(element.querySelectorAll(selector));
    if (matched.length < MIN_REPEATED_ITEMS) return undefined;
    return { count: matched.length, selector, items: matched };
  } catch {
    return undefined;
  }
}

/** A bare tag running at twice the count of a qualified group of the same tag: the
 * winning "items" are rows of something bigger. See `detectRepeatedItems`. */
function isMultiRowRun(best: { selector: string; count: number }, groups: Map<string, number>): boolean {
  if (best.selector.includes(".")) return false;
  for (const [key, count] of groups) {
    if (!key.startsWith(`${best.selector}.`)) continue;
    if (count >= MIN_REPEATED_ITEMS && best.count >= count * 2) return true;
  }
  return false;
}

// MARK: - Item fields

/**
 * What is inside one repeated item, so a `harvest` can name a field.
 *
 * Until this existed the model was shown that a region had 30 items and nothing
 * about what an item contained, while the system prompt told it that invented
 * selectors are discarded — so a compliant model either refused to author a
 * harvest or authored one that could not work. Measured: `harvest` was
 * unauthorable on 0 of 14 real sites for this reason alone.
 *
 * **Textless, and this is the field most likely to leak.** A tag, a selector built
 * from tags and class tokens, the *names* of the attributes a harvest may read,
 * and a text *length*. Never a character of the item. An element with neither its
 * own text nor a readable attribute is skipped: it is a wrapper, and a harvest
 * field pointed at it reads an empty string.
 *
 * The first item is sampled rather than all of them, because the field list is a
 * vocabulary and not a census, and because a feed's first card is the one whose
 * markup the rest were cloned from.
 */
function itemFields(region: Element, itemSelector: string): ItemFieldCandidate[] {
  let item: Element | null = null;
  try {
    item = region.querySelector(itemSelector);
  } catch {
    return [];
  }
  if (!item) return [];

  const fields: ItemFieldCandidate[] = [];
  for (const node of Array.from(item.querySelectorAll("*"))) {
    if (fields.length >= MAX_ITEM_FIELDS) break;
    const tag = node.localName.toLowerCase();
    if (IGNORED_TAGS.has(tag) || isOurs(node)) continue;

    const attributesPresent = HARVESTABLE_ATTRIBUTES.filter((name) => node.hasAttribute(name));
    const readable = FIELD_TAGS.has(tag) ? (node.textContent ?? "").trim().length : ownTextLength(node);
    if (attributesPresent.length === 0 && readable === 0) continue;

    const selector = fieldSelector(item, node, tag);
    if (!selector) continue;

    fields.push({
      selector,
      tag,
      attributesPresent,
      // The length of what `readField` would return for `text`, whitespace
      // collapsed the same way, so "this field is empty" is answerable from the
      // catalog rather than from a harvest that already ran.
      textLength: (node.textContent ?? "").replace(/\s+/g, " ").trim().length,
    });
  }
  return fields;
}

/** Text belonging to this element rather than to a descendant. A `<div>` wrapping
 * an `<h3>` has none, and is not a field. */
function ownTextLength(element: Element): number {
  let length = 0;
  for (let node = element.firstChild; node !== null; node = node.nextSibling) {
    if (node.nodeType === 3 || node.nodeType === 4) {
      length += (node.nodeValue ?? "").trim().length;
    }
  }
  return length;
}

/**
 * A selector for one field, resolved inside one item.
 *
 * Verified with `item.querySelector(selector) === node`, which is exactly what
 * `readField` will do, so a selector that ships is one that reads this element and
 * not the one above it. No attribute *values* here — `a[href]` is presence, and a
 * `[data-testid="…"]` inside a card would put the card's own vocabulary in the
 * catalog for no gain over the class it already has.
 */
function fieldSelector(item: Element, node: Element, tag: string): string | undefined {
  const classes = stableClasses(node);
  const attempts: string[] = [];
  if (classes.length > 0) {
    attempts.push(`${tag}.${classes.slice(0, 2).join(".")}`);
    attempts.push(`${tag}.${classes[0]}`);
  }
  if (node.hasAttribute("href")) attempts.push(`${tag}[href]`);
  if (node.hasAttribute("src")) attempts.push(`${tag}[src]`);
  attempts.push(tag);
  attempts.push(scopedPath(item, node));

  for (const attempt of attempts) {
    try {
      if (item.querySelector(attempt) === node) return attempt;
    } catch {
      continue;
    }
  }
  return undefined;
}

/** `:scope > div > h3:nth-of-type(2)` — the last resort inside an item, and the
 * only one that cannot fail to identify it. */
function scopedPath(item: Element, node: Element): string {
  const parts: string[] = [];
  let current: Element | null = node;
  while (current && current !== item) {
    const tag = current.localName.toLowerCase();
    const parent: Element | null = current.parentElement;
    if (!parent) break;
    const twins = Array.from(parent.children).filter(
      (child) => child.localName === current?.localName,
    );
    parts.unshift(twins.length > 1 ? `${tag}:nth-of-type(${twins.indexOf(current) + 1})` : tag);
    current = parent;
  }
  return `:scope > ${parts.join(" > ")}`;
}

// MARK: - Geometry

function rectOf(element: Element): RegionRect {
  try {
    const rect = element.getBoundingClientRect();
    const view = element.ownerDocument.defaultView;
    // Document coordinates, not viewport coordinates: a catalog is compared with
    // one built after the user scrolled, and viewport-relative geometry would
    // make the same box look like it moved.
    return {
      x: Math.round(rect.left + (view?.scrollX ?? 0)),
      y: Math.round(rect.top + (view?.scrollY ?? 0)),
      width: Math.round(rect.width),
      height: Math.round(rect.height),
    };
  } catch {
    return { x: 0, y: 0, width: 0, height: 0 };
  }
}

function depthOf(element: Element): number {
  let depth = 0;
  let current = element.parentElement;
  while (current) {
    depth += 1;
    current = current.parentElement;
  }
  return depth;
}
