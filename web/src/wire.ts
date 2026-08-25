// Wire types shared with ZenticKit.
//
// These mirror the Swift `Codable` types in Sources/ZenticKit/Reader/. There is no
// codegen: the shapes are small and stable, and generated bindings would add a
// build step to save a few dozen lines. Drift is caught instead by golden-file
// contract tests — Swift asserts it *encodes* to Tests/Fixtures/wire/*.json and
// this side asserts it *decodes* the same files, so either language changing
// shape unilaterally fails a test rather than silently breaking a page.
//
// See web/test/wire.contract.test.ts.

// 3: `Lens` lost `order`, `ReaderConfiguration` lost its seven lens budgets,
// `LensRegion` gained a fingerprint and `RegionCandidate` gained `itemFields`.
// This bundle is injected at document-start from a resource that can outlive an
// app upgrade, so a stale copy talking to a newer app has to fail loudly rather
// than go on believing in fields nobody sends any more.
export const WIRE_VERSION = 3;

// MARK: - Enums

export type Archetype = "article" | "docs" | "feed" | "thread" | "app";

/**
 * How much a page may be transformed. Mirrors `PageLevel` in Swift.
 *
 * The order is load-bearing — every stop does everything the one below it does
 * and one thing more. See `level.ts` for what each grants.
 */
export type PageLevel = "original" | "clean" | "calm" | "reader" | "rewritten";

export type RevealReason =
  | "rendered"
  | "passthrough"
  | "extractionEmpty"
  | "failsafe"
  | "userRequested";

export type ReaderMode = "restructured" | "original";

export type SectionKind =
  | "heading"
  | "paragraph"
  | "list"
  | "quote"
  | "code"
  | "table"
  | "math"
  | "figure"
  | "embed"
  | "footnotes";

/** Mirrors `SectionKind.isRewritable`. Code, tables, math and embeds are never
 * sent to a model — see the Swift docs for why this is a correctness rule. */
const REWRITABLE: ReadonlySet<SectionKind> = new Set<SectionKind>([
  "heading",
  "paragraph",
  "list",
  "quote",
]);

export function isRewritable(kind: SectionKind): boolean {
  return REWRITABLE.has(kind);
}

// MARK: - Content

export interface ContentSection {
  id: string;
  kind: SectionKind;
  markdown: string;
  html?: string;
  level?: number;
}

export interface ExtractionResult {
  url: string;
  archetype: Archetype;
  title: string;
  byline?: string;
  /** ISO-8601. */
  publishedAt?: string;
  siteName?: string;
  lang?: string;
  wordCount: number;
  sections: ContentSection[];
  usedRecipe?: string;
  confidence: number;
  isFidelitySensitive: boolean;
}

// MARK: - Recipes

export type Quirk =
  | "lateHydration"
  | "shadowContent"
  | "lazyImageAttrs"
  | "paginated"
  | "keepStylesheets"
  | "neverRestructure";

export interface SiteRecipe {
  origin: string;
  pathPattern: string;
  archetype: Archetype;
  contentSelectors: string[];
  junkSelectors: string[];
  itemSelector?: string;
  quirks: Quirk[];
  provenance: "inferred" | "curated" | "userOverride";
  /** ISO-8601. */
  generatedAt: string;
  schemaVersion: number;
}

/** Structural fingerprint for recipe inference. Carries no page text — only
 * lengths. See the privacy contract on the Swift `DOMSkeleton`. */
export interface SkeletonNode {
  tag: string;
  id?: string;
  classes: string[];
  role?: string;
  path: string;
  depth: number;
  textLength: number;
  linkCount: number;
  paragraphCount: number;
  area: number;
  hiddenOnNarrow: boolean;
}

export interface DOMSkeleton {
  origin: string;
  pathPattern: string;
  viewport: { width: number; height: number };
  nodes: SkeletonNode[];
}

// MARK: - Theme

export type FontKey =
  | "systemSans"
  | "helveticaNeue"
  | "avenirNext"
  | "optima"
  | "futura"
  | "gillSans"
  | "verdana"
  | "arial"
  | "systemSerif"
  | "georgia"
  | "palatino"
  | "timesNewRoman"
  | "charter"
  | "americanTypewriter"
  | "systemMono"
  | "menlo"
  | "monaco"
  | "courierNew"
  | "impact"
  | "comicSans"
  | "markerFelt"
  | "chalkboard"
  | "copperplate"
  | "papyrus";

export interface Palette {
  background: string;
  surface: string;
  text: string;
  textMuted: string;
  accent: string;
  visited: string;
  border: string;
  codeBackground: string;
}

export interface ThemeTokens {
  typography: {
    body: FontKey;
    heading: FontKey;
    mono: FontKey;
    baseSize: number;
    scaleRatio: number;
    lineHeight: number;
    measure: number;
    letterSpacing: number;
  };
  light: Palette;
  dark: Palette;
  shape: {
    radius: number;
    borderWidth: number;
    elevation: "none" | "subtle" | "raised" | "bevel";
  };
  ornament: {
    rule: "none" | "hairline" | "solid" | "double" | "dashed" | "groove" | "ridge";
    listMarker: "disc" | "circle" | "square" | "dash" | "arrow" | "none";
    linkDecoration: "none" | "underline" | "thickUnderline" | "dotted" | "highlight";
    headingCase: "asIs" | "upper" | "smallCaps";
    dropCap: boolean;
    justify: boolean;
  };
  density: number;
}

export interface ReaderTheme {
  id: string;
  name: string;
  source: "builtIn" | "generated" | "userEdited";
  tokens: ThemeTokens;
  prompt?: string;
  /** ISO-8601. */
  createdAt: string;
}

// MARK: - Lenses

/** Every kind of instruction a lens can carry. Mirrors Swift's `LensOpKind`. */
export type LensOpKind =
  | "hide"
  | "keep"
  | "width"
  | "move"
  | "restyle"
  | "reorder"
  | "filter"
  | "label"
  | "harvest"
  | "insert";

export type MatchMode = "any" | "all" | "none";
export type FilterMode = "keep" | "drop";
export type ItemField = "text" | "href" | "ariaLabel";
export type SortKey = "documentOrder" | "textLength" | "linkCount" | "harvestedField";

/** Presentation tokens for one region. Never a CSS string — the Swift side
 * validates these to `#rrggbb` and clamped numbers, so the stylesheet compiler
 * can emit them without sanitising. See the Swift `RegionStyle`. */
export interface RegionStyle {
  background?: string;
  foreground?: string;
  fontScale?: number;
  maxWidthPx?: number;
  paddingPx?: number;
  radiusPx?: number;
  columns?: number;
  hideImages?: boolean;
}

/** Closed predicate language for choosing repeated children. `terms` come from
 * the user's prompt, never from page text, and matching happens here. */
export interface ItemPredicate {
  terms: string[];
  matchMode: MatchMode;
  field: ItemField;
  minLinks?: number;
  maxLinks?: number;
  minChars?: number;
  maxChars?: number;
}

export interface SortSpec {
  key: SortKey;
  field?: string;
  ascending: boolean;
}

/** What a harvest may read off an element. Closed on both sides of the wire: an
 * arbitrary attribute name would let a lens lift `data-*` payloads a site never
 * meant to render. Mirrors Swift's `HarvestAttribute`. */
export type HarvestAttribute = "text" | "href" | "src" | "alt" | "title";

export interface HarvestField {
  name: string;
  selector: string;
  attribute: HarvestAttribute;
}

export interface HarvestSpec {
  itemSelector: string;
  fields: HarvestField[];
  into: string;
}

/**
 * A rect reduced to doubling bands: `floor(log2(1 + value))` per component.
 *
 * Not `RegionRect`. A catalog rect is measured now and read once; a fingerprint
 * rect is compared against a page rendered a month later at a different window
 * size, where "1004px from the left" is noise and "roughly a thousand" is signal.
 */
export interface RegionRectBand {
  x: number;
  y: number;
  width: number;
  height: number;
}

/**
 * A textless structural signature of one element, for re-finding it after the
 * site changes under the lens.
 *
 * The selector list only degrades gracefully when a stale selector matches
 * *nothing*. In practice the preferred anchor is a structural path or a build
 * hash, and after a redesign those keep matching a *different* element — so the
 * failure that actually happens is a lens quietly acting on the wrong box and
 * reporting `applied`. Scoring candidates against this and demanding a threshold
 * turns that into an honest `missed`.
 *
 * Carries no page text: attribute *names*, class tokens, counts and bands. `role`
 * is the one attribute *value* kept, because ARIA roles are a closed vocabulary
 * chosen from a fixed list rather than written by the page. See the privacy
 * contract on the Swift `RegionFingerprint`.
 */
export interface RegionFingerprint {
  /** Lowercased tag name; a custom element's name counts and is the strongest
   * signal there is, since the site's own JS depends on it. */
  tag: string;
  elementID?: string;
  classes: string[];
  /** Names of the stable `data-*`/`aria-*` attributes, never their values. */
  attributeNames: string[];
  /** The `role` value — a closed W3C vocabulary, so never page content. */
  role?: string;
  childCount: number;
  /** `floor(log2(1 + textLength))`, clamped 0…31. A band because the length is
   * what changes: a feed gains a card and an exact match would score zero. */
  textLengthBand: number;
  rectBand: RegionRectBand;
  /** Index among same-tag siblings. */
  siblingIndex: number;
  /** Tag names from the parent upwards, nearest first, at most six. */
  ancestorTags: string[];
}

export interface LensRegion {
  id: string;
  intent: string;
  /** Best first; the first that matches wins. */
  selectors: string[];
  /** Absent on lenses written before fingerprinting existed, which fall back to
   * the selectors alone — exactly what they did before. */
  fingerprint?: RegionFingerprint;
}

export interface LensOp {
  id: string;
  kind: LensOpKind;
  /** `LensRegion.id` this acts on. */
  region: string;
  note: string;
  target?: string;
  index?: number;
  fraction?: number;
  text?: string;
  style?: RegionStyle;
  sort?: SortSpec;
  predicate?: ItemPredicate;
  filterMode?: FilterMode;
  harvest?: HarvestSpec;
  itemSelector?: string;
  /** Which harvested bucket an `insert` renders — a `HarvestSpec.into` declared
   * by a `harvest` op in the same lens. Without it `insert` cannot be written
   * down: `harvest` names a bucket and nothing could read the name back. */
  bucket?: string;
  limit?: number;
}

export interface Lens {
  id: string;
  name: string;
  origin: string;
  pathPattern: string;
  isEnabled: boolean;
  prompt: string;
  regions: LensRegion[];
  ops: LensOp[];
  /** ISO-8601. */
  createdAt: string;
  /** ISO-8601. Also the stacking order: lenses arrive newest-edit-first. There is
   * no explicit `order` any more, and no conflict arbitration — where two lenses
   * touch one element the cascade and DOM order decide, in public. */
  updatedAt: string;
  schemaVersion: number;
  lastReport?: LensReport;
}

/** `missed` is drift — the selector matched nothing, so the site changed under
 * the lens. Ops fail independently, so one `missed` never stops the rest.
 *
 * `skipped` is a budget, never an override: the per-lens op cap in `planOps`, the
 * pass ceiling in `runStructuralOps`, or a structural pass declined outright in
 * `index.ts`. It is us doing less on purpose, which is why it is not `missed` —
 * nothing about the site changed.
 *
 * `failed` is the lens being wrong rather than the page or the budget: an op that
 * threw, an `insert` naming no bucket, two harvests claiming one. */
export type LensOpStatus = "applied" | "missed" | "ambiguous" | "skipped" | "failed";

export interface LensOpResult {
  opID: string;
  status: LensOpStatus;
  matchedCount: number;
  usedSelector?: string;
  message?: string;
}

/** The computed counters on the Swift `LensReport` are derived, not encoded —
 * anything that needs them here counts `results` itself. */
export interface LensReport {
  lensID: string;
  url: string;
  results: LensOpResult[];
  /** ISO-8601. */
  generatedAt: string;
}

export interface RegionRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

/**
 * One field a `harvest` could collect from a repeated item.
 *
 * `HarvestField.selector` is the one selector the model must supply and the one
 * that is deliberately not catalog-gated, because it resolves inside a single
 * item rather than against the document. Until this existed the model was shown
 * an item selector and nothing about what was *inside* an item, so authoring a
 * harvest meant inventing `.title` and hoping — against a prompt that says
 * invented selectors are discarded.
 *
 * Named `ItemFieldCandidate` because `ItemField` is already the predicate's field
 * vocabulary. Carries no page text: attribute *names* and a text *length*.
 */
export interface ItemFieldCandidate {
  /** Relative to one item — `h3`, `a[href]`, `.byline`. */
  selector: string;
  tag: string;
  /** Names of the attributes a harvest could read here, never their values. */
  attributesPresent: string[];
  textLength: number;
}

/** One addressable part of the page, as offered to the model. Carries no page
 * text — only lengths and counts. See the privacy contract on the Swift
 * `RegionCandidate`. */
export interface RegionCandidate {
  id: string;
  selector: string;
  alternates: string[];
  tag: string;
  elementID?: string;
  classes: string[];
  role?: string;
  /** `header|nav|main|aside|feed|media|footer|comments|unknown`. */
  kindGuess: string;
  rect: RegionRect;
  depth: number;
  textLength: number;
  linkCount: number;
  paragraphCount: number;
  imageCount: number;
  itemCount: number;
  itemSelector?: string;
  /** What is inside one repeated child, so a `harvest` can name a field the model
   * has been shown. Empty for a candidate that is not a feed. */
  itemFields: ItemFieldCandidate[];
}

export interface RegionCatalog {
  origin: string;
  pathPattern: string;
  viewport: { width: number; height: number };
  candidates: RegionCandidate[];
}

export interface LensProposal {
  regions: LensRegion[];
  ops: LensOp[];
  note: string;
}

export interface LensPromptRequest {
  text: string;
  selectedRegionIDs: string[];
  catalog: RegionCatalog;
}

/**
 * Which lens ⌥⌘L is opening, if it is opening one.
 *
 * Absent means authoring: a new lens, adopting nothing. `editing` names an
 * existing lens by id, and the draft that comes back carries that id — which is
 * the only thing that tells the app to replace the record rather than write a
 * second lens beside it, both enabled, every op applied twice. Optional so an
 * `enterLensMode` with no payload still decodes, which is what authoring sends.
 */
export interface LensEditRequest {
  editing?: string;
}

// MARK: - Bootstrap configuration

export interface ReaderConfiguration {
  mode: ReaderMode;
  theme: ReaderTheme;
  recipe?: SiteRecipe;
  /** How much this page may be transformed. See `level.ts`. */
  level: PageLevel;
  passthroughOrigins: string[];
  /**
   * Origins the app has learned do not get restructured. Their pages are not
   * hidden on arrival — the reader still runs, but it may not render, because
   * swapping a visible page for the reader is the flash this design prevents.
   */
  instantOrigins: string[];
  revealFailsafeMs: number;
  settleQuietPeriodMs: number;
  settleCeilingMs: number;
  minConfidence: number;
  minWordCount: number;
  skeletonNodeLimit: number;
  /** Lenses matching the page about to load, newest edit first. Present at
   * document-start so `hide` and `restyle` can compile to a stylesheet before
   * the first paint.
   *
   * Seven lens budgets used to ride alongside this. Every one was a compile-time
   * constant on the Swift side, and this side declared its own copy of all seven
   * and fell back to it per field — two copies of the same numbers shipped over a
   * wire to arrive at the value the receiver already had. `lens/index.ts` keeps
   * its copy; Swift keeps `Budget`; neither reads the other. */
  lenses: Lens[];
  debugLogging: boolean;
}

// MARK: - Page → app

export interface RevealPayload {
  reason: RevealReason;
  elapsedMs: number;
}

export interface ReaderFailure {
  stage: string;
  message: string;
}

export type ReaderEvent =
  | { v: number; type: "ready"; payload: { bundleVersion: string; url: string } }
  | { v: number; type: "extracted"; payload: ExtractionResult }
  | { v: number; type: "needsRecipe"; payload: DOMSkeleton }
  | { v: number; type: "revealed"; payload: RevealPayload }
  | { v: number; type: "failed"; payload: ReaderFailure }
  | { v: number; type: "lensReport"; payload: LensReport[] }
  | { v: number; type: "lensRegions"; payload: RegionCatalog }
  | { v: number; type: "lensPrompt"; payload: LensPromptRequest }
  | { v: number; type: "lensDraft"; payload: Lens }
  | { v: number; type: "lensModeChanged"; payload: boolean };

// MARK: - App → page

export interface RewritePatch {
  sectionID: string;
  markdown: string;
  isFinal: boolean;
}

/**
 * A model-authored rendering of the page.
 *
 * Sanitised on the Swift side before it is sent — no script, no iframe, no
 * `url()`, and no `<img>` pointing anywhere the page does not already load
 * from. Non-rewritable sections are not in here: they arrive as
 * `<zentic-section section="…">` placeholders and are rendered locally.
 */
export interface GeneratedDocument {
  html: string;
}

export type ReaderCommand =
  | { v: number; type: "applyRecipe"; payload: SiteRecipe }
  | { v: number; type: "setMode"; payload: ReaderMode }
  | { v: number; type: "setLevel"; payload: PageLevel }
  | { v: number; type: "requestSkeleton" }
  | { v: number; type: "applyRewrite"; payload: RewritePatch }
  | { v: number; type: "discardRewrite" }
  | { v: number; type: "applyTheme"; payload: ReaderTheme }
  | { v: number; type: "applyDocument"; payload: GeneratedDocument }
  | { v: number; type: "applyLenses"; payload: Lens[] }
  | { v: number; type: "enterLensMode"; payload?: LensEditRequest }
  | { v: number; type: "exitLensMode" }
  | { v: number; type: "proposeOps"; payload: LensProposal }
  | { v: number; type: "requestRegions" };
