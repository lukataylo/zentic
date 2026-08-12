import { countWords, ELEMENT_NODE, elementArea, TEXT_NODE, textOf, viewportSize } from "../dom.js";
import { isDeniedHost } from "./denylist.js";

// Is this document an application rather than a document?
//
// This is the highest-stakes judgement in the product, and it is deliberately
// asymmetric. The two ways to be wrong are not comparable:
//
//   - Declining to restructure an article: the user sees the page they would
//     have seen in any other browser. Cost: nothing they notice.
//   - Restructuring an app: their mail client turns into a list of link text,
//     their spreadsheet into a table of stale numbers, the document they were
//     typing in loses its cursor. Cost: they stop trusting the browser.
//
// So detection **fails open**. Every ambiguous case resolves to `app`, the score
// only has to clear a low bar, and any one of several structural vetoes is
// enough on its own. Coverage is what we trade away, and coverage is recoverable
// later through recipes; trust is not.

export interface AppSignals {
  /** Hostname on the bundled deny-list. */
  denied: boolean;
  /** Words inside prose elements — the only content a reading view can show. */
  proseWords: number;
  /** Longest single run of uninterrupted text, in words. See `narrativeWords`. */
  longestTextRun: number;
  paragraphCount: number;
  /** Paragraphs of 25+ words. Real articles have several; app chrome has none. */
  longParagraphCount: number;
  /** input/select/textarea/button, plus anything with a button-like role. */
  controlCount: number;
  /** Landmark roles that only appear in applications. */
  appRoleCount: number;
  /** Share of the page's prose that sits inside an editable region, 0…1. */
  editableProseShare: number;
  editableCount: number;
  /** Largest canvas as a fraction of the viewport. */
  canvasViewportShare: number;
  webglLikely: boolean;
  /** Links per 100 prose words. Navigation and feeds run very high. */
  linkDensity: number;
  /** Markers that a framework mounted the whole page into one empty element. */
  shellMarkers: string[];
  /** Markers that this is published content: <article>, og:type, JSON-LD, <time>. */
  articleMarkers: string[];
}

export interface AppVerdict {
  isApp: boolean;
  /** Confidence that this is an app, 0…1. */
  confidence: number;
  /** Human-readable, in the order they were decided. For debug logging. */
  reasons: string[];
  signals: AppSignals;
}

/** Score at or above which a page is treated as an app. Deliberately low. */
const APP_THRESHOLD = 0.5;

const PROSE_SELECTOR = "p, li, blockquote, h1, h2, h3, h4, h5, h6, dd, pre, figcaption";
const CONTROL_SELECTOR =
  'input:not([type="hidden"]), select, textarea, button, [role="button"], [role="checkbox"], [role="switch"], [role="slider"], [role="menuitem"], [role="tab"]';
const APP_ROLE_SELECTOR =
  '[role="application"], [role="grid"], [role="treegrid"], [role="toolbar"], [role="menubar"], [role="tablist"], [role="listbox"], [role="combobox"], [role="dialog"], [role="alertdialog"], [role="tree"], [role="feed"]';
const EDITABLE_SELECTOR = '[contenteditable=""], [contenteditable="true"], [role="textbox"]';

/** Empty mount points. On their own they mean nothing — plenty of blogs use them. */
const SHELL_SELECTORS = [
  "#root",
  "#app",
  "#__next",
  "#___gatsby",
  "[data-reactroot]",
  "[ng-version]",
  "[data-server-rendered]",
  "#main-frame",
  ".app-shell",
];

export function collectAppSignals(doc: Document, hostname: string): AppSignals {
  const body = doc.body;
  const view = viewportSize(doc);
  const viewportArea = Math.max(1, view.width * view.height);

  const prose = body ? Array.from(body.querySelectorAll(PROSE_SELECTOR)) : [];
  const paragraphs = prose.filter((element) => element.localName === "p");
  let elementProseWords = 0;
  let longParagraphCount = 0;
  for (const element of prose) {
    const words = countWords(textOf(element));
    elementProseWords += words;
    if (element.localName === "p" && words >= 25) longParagraphCount += 1;
  }

  // Semantic prose elements are not enough on their own. Paul Graham's essays are
  // text in table cells, an SEC 10-K is text in <div>s, and both scored as apps
  // when only <p> counted — a false positive that costs a real article. So prose
  // is also measured structurally, by looking for long uninterrupted text runs.
  const narrative = narrativeText(body);
  const proseWords = Math.max(elementProseWords, narrative.words);
  if (longParagraphCount === 0) longParagraphCount = narrative.runs;

  const editables = body ? Array.from(body.querySelectorAll(EDITABLE_SELECTOR)) : [];
  let editableWords = 0;
  for (const editable of editables) {
    editableWords += countWords(textOf(editable));
  }

  const canvases = body ? Array.from(body.querySelectorAll("canvas")) : [];
  let canvasArea = 0;
  for (const canvas of canvases) canvasArea = Math.max(canvasArea, elementArea(canvas));

  const linkCount = body ? body.querySelectorAll("a[href]").length : 0;

  const shellMarkers = SHELL_SELECTORS.filter((selector) => {
    try {
      return doc.querySelector(selector) !== null;
    } catch {
      return false;
    }
  });

  const articleMarkers: string[] = [];
  if (doc.querySelector("article")) articleMarkers.push("article");
  const ogType = doc
    .querySelector('meta[property="og:type"], meta[name="og:type"]')
    ?.getAttribute("content");
  if (ogType && /article|book|blog/i.test(ogType)) articleMarkers.push(`og:type=${ogType}`);
  if (doc.querySelector('meta[property^="article:"]')) articleMarkers.push("article:*");
  if (hasArticleSchema(doc)) articleMarkers.push("schema.org");
  if (doc.querySelector("time[datetime]")) articleMarkers.push("time");
  if (doc.querySelector('link[rel="canonical"]') && paragraphs.length >= 5) {
    articleMarkers.push("canonical+prose");
  }

  return {
    denied: isDeniedHost(hostname),
    proseWords,
    longestTextRun: narrative.longest,
    paragraphCount: paragraphs.length,
    longParagraphCount,
    controlCount: body ? body.querySelectorAll(CONTROL_SELECTOR).length : 0,
    appRoleCount: body ? body.querySelectorAll(APP_ROLE_SELECTOR).length : 0,
    editableProseShare: proseWords > 0 ? Math.min(1, editableWords / proseWords) : 0,
    editableCount: editables.length,
    canvasViewportShare: canvasArea / viewportArea,
    webglLikely: canvases.some(
      (canvas) =>
        canvas.hasAttribute("data-engine") ||
        /webgl|three|unity|pixi/i.test(canvas.className || "") ||
        /webgl|three|unity|pixi/i.test(canvas.id || ""),
    ),
    linkDensity: proseWords > 0 ? (linkCount * 100) / proseWords : linkCount > 0 ? 999 : 0,
    shellMarkers,
    articleMarkers,
  };
}

/**
 * Prose measured by text-run length rather than by tag.
 *
 * An application's text is short and labelled: menu items, column headers, button
 * captions, status lines. A document's text comes in runs of dozens of words. So
 * a text node of 12+ words counts as narrative regardless of what element holds
 * it, which is what rescues hand-written HTML from the 1990s and any generator
 * that never learned about `<p>`.
 *
 * Adjacent inline markup splits a sentence across text nodes, so runs are
 * accumulated per *block* container rather than per node.
 */
function narrativeText(body: Element | null): { words: number; runs: number; longest: number } {
  if (!body) return { words: 0, runs: 0, longest: 0 };

  const NARRATIVE_MINIMUM = 12;
  let words = 0;
  let runs = 0;
  let longest = 0;

  for (const element of Array.from(body.querySelectorAll("*"))) {
    // Own text only: counting a container's whole subtree would count the same
    // sentence once per ancestor.
    let ownWords = 0;
    for (const child of Array.from(element.childNodes)) {
      if (child.nodeType === TEXT_NODE) ownWords += countWords(child.nodeValue ?? "");
      // Inline formatting is part of the same sentence.
      else if (
        child.nodeType === ELEMENT_NODE &&
        ["a", "em", "i", "strong", "b", "code", "span", "sup", "sub", "small", "abbr", "font", "tt", "u"].includes(
          (child as Element).localName,
        )
      ) {
        ownWords += countWords(child.textContent ?? "");
      }
    }

    if (ownWords >= NARRATIVE_MINIMUM) {
      words += ownWords;
      runs += 1;
      longest = Math.max(longest, ownWords);
    }
  }

  return { words, runs, longest };
}

/** JSON-LD `@type` naming published content. Parsed defensively — it is page input. */
function hasArticleSchema(doc: Document): boolean {
  const scripts = Array.from(doc.querySelectorAll('script[type="application/ld+json"]'));
  for (const script of scripts) {
    const text = script.textContent ?? "";
    // A substring test rather than a parse: the whole point is to avoid running
    // a JSON parser over an unbounded amount of page-controlled text on the hot
    // path, and a false positive here only nudges a score.
    if (/"@type"\s*:\s*"?(?:[A-Za-z]*Article|BlogPosting|Report|Recipe|WebPage|TechArticle)/.test(text)) {
      return true;
    }
  }
  return false;
}

/**
 * Classify a document as app or not-app.
 *
 * Structured as vetoes first, then a score. The vetoes exist because some
 * signals are conclusive on their own and should not be outvoted by a page that
 * happens to also contain prose — a word processor full of an article's text is
 * still a word processor, and that is exactly the case a pure score gets wrong.
 */
export function detectApp(doc: Document, hostname: string): AppVerdict {
  const signals = collectAppSignals(doc, hostname);
  const reasons: string[] = [];

  if (signals.denied) {
    return { isApp: true, confidence: 1, reasons: ["deny-list"], signals };
  }

  // Veto 1: the reader would be typing into our copy, not their document.
  if (signals.editableProseShare >= 0.3 || (signals.editableCount > 0 && signals.proseWords < 200)) {
    reasons.push(`editable region holds ${Math.round(signals.editableProseShare * 100)}% of prose`);
    return { isApp: true, confidence: 0.95, reasons, signals };
  }

  // Veto 2: a canvas that owns the viewport is the content, and it is not text.
  if (signals.canvasViewportShare >= 0.25 && signals.proseWords < 400) {
    reasons.push(`canvas covers ${Math.round(signals.canvasViewportShare * 100)}% of viewport`);
    return { isApp: true, confidence: 0.95, reasons, signals };
  }

  // Veto 3: an explicit ARIA promise that this is an application.
  const application = doc.querySelector('[role="application"]');
  if (application && signals.proseWords < 600) {
    reasons.push('role="application"');
    return { isApp: true, confidence: 0.9, reasons, signals };
  }

  // Veto 4: dense controls with nothing to read. Mail lists, dashboards, admin.
  if (signals.controlCount >= 12 && signals.proseWords < 120) {
    reasons.push(`${signals.controlCount} controls, ${signals.proseWords} prose words`);
    return { isApp: true, confidence: 0.9, reasons, signals };
  }

  let score = 0;
  const add = (weight: number, reason: string) => {
    score += weight;
    reasons.push(`${weight > 0 ? "+" : ""}${weight.toFixed(2)} ${reason}`);
  };

  if (signals.canvasViewportShare >= 0.1) add(0.35, "large canvas");
  if (signals.webglLikely) add(0.2, "webgl canvas");
  if (signals.appRoleCount >= 2) add(0.25, `${signals.appRoleCount} application roles`);
  if (signals.editableCount > 0) add(0.2, "editable region");

  const controlsPerParagraph = signals.controlCount / Math.max(1, signals.paragraphCount);
  if (controlsPerParagraph > 2) add(0.3, `${controlsPerParagraph.toFixed(1)} controls/paragraph`);

  if (signals.proseWords < 200) add(0.3, `only ${signals.proseWords} prose words`);
  if (signals.longParagraphCount === 0) add(0.25, "no substantial paragraph");
  if (signals.shellMarkers.length > 0 && signals.proseWords < 300) {
    add(0.3, `app shell (${signals.shellMarkers.join(", ")}) with little prose`);
  }
  if (signals.linkDensity > 15) add(0.2, `${signals.linkDensity.toFixed(0)} links/100 words`);
  if (signals.articleMarkers.length === 0) add(0.15, "no published-content markers");

  // Negative evidence. Substantial, sustained prose is the one thing an app shell
  // reliably does not have.
  if (signals.articleMarkers.length > 0) {
    add(-0.35, `content markers (${signals.articleMarkers.join(", ")})`);
  }
  if (signals.longParagraphCount >= 5) add(-0.4, `${signals.longParagraphCount} long paragraphs`);
  if (signals.proseWords > 800) add(-0.35, `${signals.proseWords} prose words`);
  // A single 80-word run of text is something no application chrome produces.
  if (signals.longestTextRun >= 80) add(-0.4, `${signals.longestTextRun}-word text run`);

  const confidence = Math.min(1, Math.max(0, score));
  return { isApp: confidence >= APP_THRESHOLD, confidence, reasons, signals };
}

export { APP_THRESHOLD };
