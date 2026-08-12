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

export const WIRE_VERSION = 1;

// MARK: - Enums

export type Archetype = "article" | "docs" | "feed" | "thread" | "app";

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

// MARK: - Bootstrap configuration

export interface ReaderConfiguration {
  mode: ReaderMode;
  theme: ReaderTheme;
  recipe?: SiteRecipe;
  passthroughOrigins: string[];
  revealFailsafeMs: number;
  settleQuietPeriodMs: number;
  settleCeilingMs: number;
  minConfidence: number;
  minWordCount: number;
  skeletonNodeLimit: number;
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
  | { v: number; type: "failed"; payload: ReaderFailure };

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
  | { v: number; type: "requestSkeleton" }
  | { v: number; type: "applyRewrite"; payload: RewritePatch }
  | { v: number; type: "discardRewrite" }
  | { v: number; type: "applyTheme"; payload: ReaderTheme }
  | { v: number; type: "applyDocument"; payload: GeneratedDocument };
