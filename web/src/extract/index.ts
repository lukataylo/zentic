import Defuddle from "defuddle";

import { countWords, textOf } from "../dom.js";
import { sanitizeHTML } from "../render/sanitize.js";
import type { Archetype, ExtractionResult, SiteRecipe } from "../wire.js";
import { detectApp, type AppVerdict } from "./appdetect.js";
import { isFidelitySensitive } from "./fidelity.js";
import { buildSections } from "./sections.js";

// Extraction: page DOM → `ExtractionResult`.
//
// Defuddle rather than Readability, for three reasons that show up constantly in
// the corpus: it is multi-pass (it loosens its criteria and retries where
// Readability gives up, which is what rescues index-shaped pages), it consults
// mobile stylesheets as a not-main-content signal, and it emits *consistent*
// markup for footnotes, code blocks and math — the three things naive reader
// modes mangle. See the notes in web/test/corpus.
//
// Defuddle clones the document internally and only ever mutates the clone, which
// is load-bearing for us: invariant 6 says the original DOM is hidden, never
// destroyed, so ⌘\ is instant. `extract.test.ts` asserts the live document still
// has its scripts and styles afterwards.

export interface ExtractOptions {
  url: string;
  recipe?: SiteRecipe | undefined;
  minWordCount: number;
  debug?: boolean;
}

export interface ExtractionOutcome {
  result: ExtractionResult;
  app: AppVerdict;
  /** Set when there is nothing worth rendering. */
  empty: boolean;
  /** Stage timings, for debug logging only. Never leaves the device. */
  timings: Record<string, number>;
}

const JUNK_MARKERS = [
  "advertisement",
  "sign up for our newsletter",
  "subscribe to continue",
  "accept all cookies",
  "skip to content",
  "skip to main content",
  "share this article",
  "trending now",
  "recommended for you",
  "most popular",
];

/** `## [Some headline](https://…)` — a heading that is only a link. */
const LINK_ONLY_HEADING = /^#{1,6}\s*!?\[[^\]]*\]\([^)]*\)\s*$/;

const DOCS_PATH =/\/(docs?|documentation|reference|api|guide|manual|handbook|learn|book|spec|tutorial)(\/|$)/i;
const DOCS_GENERATOR = /sphinx|mkdocs|docusaurus|vitepress|vuepress|mdbook|gitbook|docc|hugo|antora|readme|nextra|starlight/i;

/**
 * ISO-8601 without fractional seconds.
 *
 * Foundation's `.iso8601` decoding strategy rejects a fractional-seconds
 * component, so `Date.toISOString()` — which always emits milliseconds — would
 * make the whole `extracted` event undecodable on the Swift side. One character
 * of formatting, and without it the app silently receives nothing.
 */
function isoSeconds(value: string | undefined): string | undefined {
  if (!value) return undefined;
  const parsed = Date.parse(value);
  if (Number.isNaN(parsed)) return undefined;
  return new Date(parsed).toISOString().replace(/\.\d{3}Z$/, "Z");
}

function schemaText(doc: Document): string {
  return Array.from(doc.querySelectorAll('script[type="application/ld+json"]'))
    .map((script) => script.textContent ?? "")
    .join("\n")
    .slice(0, 20_000);
}

/** Prose words in the whole body, as the denominator for extraction coverage. */
function bodyProseWords(doc: Document): number {
  if (!doc.body) return 0;
  let words = 0;
  for (const element of Array.from(doc.body.querySelectorAll("p, li, blockquote, dd"))) {
    words += countWords(textOf(element));
  }
  return words;
}

/**
 * Sibling blocks that each contain a whole post.
 *
 * Distinguishes a date archive or a forum thread from an article that merely
 * links to related posts: a teaser card carries a title and at most one line of
 * text, whereas a real post carries several full paragraphs. Only outermost
 * matches count, so an article nested in a wrapper is not counted twice.
 */
function countPostBlocks(doc: Document): number {
  if (!doc.body) return 0;
  const blocks = Array.from(
    doc.body.querySelectorAll("article, [class*='post'], [class*='entry']"),
  );
  let count = 0;
  for (const block of blocks) {
    if (blocks.some((other) => other !== block && other.contains(block))) continue;
    const full = Array.from(block.querySelectorAll("p")).filter(
      (paragraph) => countWords(textOf(paragraph)) >= 25,
    ).length;
    if (full >= 2) count += 1;
  }
  return count;
}

function detectDocs(doc: Document, url: string, sectionKinds: string[]): boolean {
  let signals = 0;

  try {
    if (DOCS_PATH.test(new URL(url).pathname)) signals += 1;
  } catch {
    // Unparseable URL contributes nothing.
  }

  const generator = doc.querySelector('meta[name="generator"]')?.getAttribute("content") ?? "";
  if (DOCS_GENERATOR.test(generator)) signals += 1;

  // A persistent sidebar of same-site links is the structural signature of
  // documentation, and the reason `docs` gets a table of contents at all.
  const navLinks = Array.from(doc.querySelectorAll("nav a[href], [role='navigation'] a[href]"));
  if (navLinks.length >= 12) signals += 1;

  const codeSections = sectionKinds.filter((kind) => kind === "code").length;
  if (codeSections >= 3 && codeSections / Math.max(1, sectionKinds.length) >= 0.12) signals += 1;

  if (doc.querySelector('[role^="doc-"], [class*="api-"], [class*="reference"]')) signals += 0.5;

  return signals >= 2;
}

/**
 * Extraction self-assessment, 0…1.
 *
 * Not a probability — a deterministic score that has to be *ordered* correctly:
 * pages where extraction went well must land above `Budget.minConfidence` and
 * pages where it produced a mess must land below, because that threshold is the
 * last thing standing between the reader and a bad reconstruction.
 *
 * The strongest negative signal is coverage near 1.0. That means the extractor
 * kept essentially the whole body, which in practice means it found no content
 * element and fell back — the page will render as a reading view of the site's
 * navigation.
 */
interface ConfidenceInput {
  wordCount: number;
  bodyWords: number;
  paragraphCount: number;
  longParagraphs: number;
  headingCount: number;
  /** Headings that are nothing but a link — the signature of an index page. */
  linkedHeadings: number;
  /** Code, table and math sections: substance that `wordCount` does not count. */
  structuredCount: number;
  /** Sibling blocks that each hold a whole post — a date archive or a thread. */
  postBlocks: number;
  linkDensity: number;
  junkHits: number;
  fellBackToBody: boolean;
  hasTitle: boolean;
  hasAttribution: boolean;
  minWordCount: number;
}

function estimateConfidence(input: ConfidenceInput): number {
  let score = 0.35;
  const coverage = input.bodyWords > 0 ? input.wordCount / input.bodyWords : 0;
  const averageParagraph = input.paragraphCount > 0 ? input.wordCount / input.paragraphCount : 0;
  const structured = input.structuredCount >= 3;

  if (input.hasTitle) score += 0.2;
  if (input.hasAttribution) score += 0.1;
  if (input.longParagraphs >= 3) score += 0.15;
  if (input.longParagraphs >= 8) score += 0.1;
  if (input.longParagraphs >= 15) score += 0.1;
  if (coverage >= 0.25 && coverage <= 0.95) score += 0.1;
  // Reference documentation is mostly tables and code with a sentence of prose
  // between them. Judging it by word count alone would reject the pages where a
  // reading view helps most.
  if (structured) score += 0.2;

  // An index page: headlines that are links, teaser-length paragraphs, and a lot
  // of links for the amount of text. Each of these alone happens on real
  // articles; the combination is a front page, and rendering one as an article
  // produces a list of orphaned sentences.
  if (input.headingCount >= 3 && input.linkedHeadings / input.headingCount >= 0.5) score -= 0.35;
  // Short average paragraphs mean teasers on a front page — but they also mean a
  // reference page where every sentence introduces a code block or a table. The
  // structured check separates the two; without it, terse API docs (Tailwind's
  // utility pages, one line of prose per example) get declined as index pages.
  if (input.paragraphCount >= 6 && averageParagraph < 20 && !structured) score -= 0.25;
  if (input.linkDensity > 20) score -= 0.2;

  // Taking essentially the whole body is only suspicious when the body is full of
  // navigation. On a hand-written page — one <body>, one essay, no chrome —
  // taking everything is the correct answer.
  if (coverage > 0.98 && input.linkDensity > 8) score -= 0.2;
  // The inverse: a page with plenty of prose where we captured almost none of it
  // means the content element was wrong, and a stub reads worse than the original.
  if (coverage < 0.2 && input.bodyWords > 400) score -= 0.25;

  if (input.fellBackToBody) score -= 0.2;
  if (input.junkHits >= 2) score -= 0.15;
  if (input.wordCount < input.minWordCount * 2 && !structured) score -= 0.25;
  if (input.longParagraphs === 0 && !structured) score -= 0.2;

  // Several sibling blocks each holding a full post — a date archive, or a forum
  // thread — scores maximally on every article signal, because each post *is*
  // real prose. Concatenating them yields one document of unrelated paragraphs
  // with the post titles dropped, which reads worse than the original. No
  // additive penalty is enough here (these pages hit the 0.98 cap), so the
  // ceiling drops instead. `feed` and `thread` get proper layouts in M4; until
  // then invariant 2 applies and we pass the page through.
  if (input.postBlocks >= 3) return Math.min(score, 0.4);

  return Math.min(0.98, Math.max(0.05, score));
}

/**
 * Run extraction over a document.
 *
 * The app check comes first and can short-circuit: there is no point extracting
 * a mail client, and an `ExtractionResult` for one would only invite something
 * downstream to render it.
 */
export function extract(doc: Document, options: ExtractOptions): ExtractionOutcome {
  const timings: Record<string, number> = {};
  const mark = <T>(name: string, work: () => T): T => {
    const started = performance.now();
    try {
      return work();
    } finally {
      timings[name] = Math.round(performance.now() - started);
    }
  };

  let hostname = "";
  try {
    hostname = new URL(options.url).hostname;
  } catch {
    hostname = "";
  }

  const app = mark("detectApp", () => detectApp(doc, hostname));
  const lang =
    doc.documentElement?.getAttribute("lang") ??
    doc.querySelector("meta[property='og:locale']")?.getAttribute("content") ??
    undefined;

  if (app.isApp) {
    return {
      app,
      empty: true,
      timings,
      result: {
        url: options.url,
        archetype: "app",
        title: doc.title ?? "",
        wordCount: 0,
        sections: [],
        confidence: app.confidence,
        isFidelitySensitive: false,
        ...(lang ? { lang } : {}),
      },
    };
  }

  const source = mark("prepare", () => prepareDocument(doc, options.recipe));
  const parsed = mark("defuddle", () =>
    new Defuddle(source, {
      url: options.url,
      // No network, ever. `parse()` is the synchronous path and does not fetch,
      // but a future default flip on either flag would turn every page read into
      // an outbound request — so both are pinned, and `fetch` is poisoned.
      useAsync: false,
      fetch: (() => {
        throw new Error("extraction must not perform network requests");
      }) as unknown as typeof globalThis.fetch,
      ...(options.recipe?.contentSelectors.length
        ? { contentSelector: options.recipe.contentSelectors.join(", ") }
        : {}),
      ...(options.debug ? { debug: true } : {}),
    }).parse(),
  );

  const fragment = mark("sanitize", () =>
    sanitizeHTML(parsed.content ?? "", doc, { baseUrl: options.url, allowEmbeds: true }),
  );

  const { sections, wordCount } = mark("sections", () => buildSections(fragment, doc));

  const text = sections
    .filter((section) => section.kind === "paragraph" || section.kind === "heading")
    .map((section) => section.markdown)
    .join("\n")
    .slice(0, 8000);

  const paragraphs = sections.filter((section) => section.kind === "paragraph");
  const headings = sections.filter((section) => section.kind === "heading");
  const linkCount = fragment.querySelectorAll("a[href]").length;
  const junkHits = JUNK_MARKERS.filter((marker) => text.toLowerCase().includes(marker)).length;

  const title = (parsed.title || doc.title || "").trim();
  const confidence = estimateConfidence({
    wordCount,
    bodyWords: bodyProseWords(doc),
    paragraphCount: paragraphs.length,
    longParagraphs: paragraphs.filter((section) => countWords(section.markdown) >= 25).length,
    headingCount: headings.length,
    linkedHeadings: headings.filter((section) => LINK_ONLY_HEADING.test(section.markdown)).length,
    structuredCount: sections.filter(
      (section) =>
        section.kind === "code" || section.kind === "table" || section.kind === "math",
    ).length,
    postBlocks: mark("postBlocks", () => countPostBlocks(doc)),
    linkDensity: wordCount > 0 ? (linkCount * 100) / wordCount : 0,
    junkHits,
    fellBackToBody: /^\s*<body/i.test(parsed.content ?? ""),
    hasTitle: title.length > 0,
    hasAttribution: Boolean(parsed.author || parsed.published),
    minWordCount: options.minWordCount,
  });

  const archetype: Archetype = detectDocs(
    doc,
    options.url,
    sections.map((section) => section.kind),
  )
    ? "docs"
    : "article";

  const published = isoSeconds(parsed.published);
  const byline = parsed.author?.trim();
  const siteName = parsed.site?.trim();
  const language = (parsed.language || lang || "").trim();
  const recipeID = options.recipe ? `${options.recipe.origin}|${options.recipe.pathPattern}` : undefined;

  const result: ExtractionResult = {
    url: options.url,
    archetype,
    title,
    wordCount,
    sections,
    confidence,
    isFidelitySensitive: isFidelitySensitive({
      url: options.url,
      title,
      text,
      schema: schemaText(doc),
    }),
    ...(byline ? { byline } : {}),
    ...(published ? { publishedAt: published } : {}),
    ...(siteName ? { siteName } : {}),
    ...(language ? { lang: language } : {}),
    ...(recipeID ? { usedRecipe: recipeID } : {}),
  };

  return {
    result,
    app,
    empty: wordCount < options.minWordCount || sections.length === 0,
    timings,
  };
}

/**
 * The document handed to Defuddle.
 *
 * Normally the live one, so mobile-stylesheet and computed-style signals are
 * real. With a recipe that names junk selectors we have to remove them first,
 * and removing anything from the live DOM would break the promise that the
 * original is only hidden — so that case works on a clone and accepts the loss
 * of those signals. A curated recipe is a fair trade for them.
 */
function prepareDocument(doc: Document, recipe: SiteRecipe | undefined): Document {
  if (!recipe || recipe.junkSelectors.length === 0) return doc;

  const clone = doc.cloneNode(true) as Document;
  for (const selector of recipe.junkSelectors) {
    try {
      for (const element of Array.from(clone.querySelectorAll(selector))) element.remove();
    } catch {
      // A rotted selector is expected: recipes outlive redesigns.
    }
  }
  return clone;
}
