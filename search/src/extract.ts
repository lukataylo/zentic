import { JSDOM, VirtualConsole } from "jsdom";

import { extract } from "../../web/src/extract/index.js";
import { Budget } from "./config.js";
import { isCrawlable } from "./seeds.js";

/**
 * Page HTML → the text worth indexing, and the links worth following.
 *
 * This deliberately reuses the browser's own extractor rather than writing a
 * second one. Two reasons, and the second is the important one.
 *
 * It is the hard part and it is already done — 80 corpus pages of tuning, app
 * detection, front-door detection, confidence scoring. And it means **the index
 * contains exactly what Zentic would show you**: search results and the page you
 * land on are the same content, produced by the same code. A separate extractor
 * would drift, and the day it did the index would start describing pages that no
 * longer exist.
 *
 * It is also how advertising stays out. Extraction returns article content, not
 * documents — navigation, promos, related-content rails and ad slots are discarded
 * before anything is stored, so there is no path by which ad copy reaches the
 * index and no raw HTML kept that it could be recovered from.
 */

export interface Extracted {
  title: string;
  text: string;
  wordCount: number;
  archetype: string;
  confidence: number;
  lang?: string | undefined;
  byline?: string | undefined;
  published?: string | undefined;
  /**
   * Every crawlable link on the page, for the frontier.
   *
   * Taken from the whole document including navigation, because a blog's roll of
   * other blogs lives in exactly the furniture extraction throws away, and that
   * roll is the best discovery source a crawl like this has.
   */
  links: string[];
  /**
   * Links that appeared inside the *article*, for the rank graph.
   *
   * The distinction is the whole of link-based ranking. A link an author wrote
   * into a sentence is an endorsement; a link in a footer is site furniture that
   * appears on every page of the site. Counting both put githubstatus.com,
   * docker.com/legal/terms-use and policies.google.com/privacy at the top of the
   * index the moment it grew past a few hundred pages — every site links to its
   * own terms, so boilerplate out-ranks writing on in-links alone.
   */
  contentLinks: string[];
}

export type ExtractOutcome =
  | { kind: "ok"; page: Extracted }
  | { kind: "rejected"; reason: string };

/** Swallows the console noise a real page generates inside jsdom. */
const quiet = new VirtualConsole();

/**
 * Run something with Node's console muted.
 *
 * Defuddle logs its own recovered errors with `console.error` — a page with an
 * unusual selector produces a stack trace and carries on working. That is fine
 * behaviour for a browser with a devtools console and useless in a crawl of fifty
 * thousand pages, where it buries the progress line under stack traces for pages
 * that extracted successfully anyway.
 */
function quietly<T>(work: () => T): T {
  const { log, warn, error, info, debug } = console;
  const noop = () => {};
  Object.assign(console, { log: noop, warn: noop, error: noop, info: noop, debug: noop });
  try {
    return work();
  } finally {
    Object.assign(console, { log, warn, error, info, debug });
  }
}

export function extractPage(html: string, url: string): ExtractOutcome {
  let dom: JSDOM;
  try {
    dom = new JSDOM(html, {
      url,
      // Never. A crawler that runs page script is a crawler that can be made to do
      // anything by anyone it visits.
      runScripts: "outside-only",
      pretendToBeVisual: true,
      virtualConsole: quiet,
    });
  } catch (error) {
    return { kind: "rejected", reason: `parse failed: ${(error as Error).message}` };
  }

  try {
    const document = dom.window.document;
    const links = collectLinks(document, url);

    const outcome = quietly(() =>
      extract(document as unknown as Document, {
        url,
        minWordCount: Budget.minWordCount,
      }),
    );
    const result = outcome.result;

    if (result.archetype === "app") {
      return { kind: "rejected", reason: "app" };
    }
    if (outcome.empty) {
      return { kind: "rejected", reason: "nothing extracted" };
    }
    if (result.confidence < Budget.minConfidence) {
      return { kind: "rejected", reason: `confidence ${result.confidence.toFixed(2)}` };
    }
    if (result.wordCount < Budget.minWordCount) {
      return { kind: "rejected", reason: `${result.wordCount} words` };
    }

    // Only prose and headings. Code and tables are indexed nowhere near as usefully
    // as they read, and a page of configuration would otherwise outrank an essay on
    // any term that appears in it.
    const text = result.sections
      .filter((section) => ["paragraph", "heading", "list", "quote"].includes(section.kind))
      .map((section) => section.markdown)
      .join("\n")
      .slice(0, Budget.maxStoredChars);

    return {
      kind: "ok",
      page: {
        contentLinks: markdownLinks(text, url),
        title: result.title || hostOf(url),
        text,
        wordCount: result.wordCount,
        archetype: result.archetype,
        confidence: result.confidence,
        lang: result.lang,
        byline: result.byline,
        published: result.publishedAt,
        links,
      },
    };
  } catch (error) {
    return { kind: "rejected", reason: `extract threw: ${(error as Error).message}` };
  } finally {
    dom.window.close();
  }
}

/**
 * Links worth following, from the whole document.
 *
 * Taken before extraction rather than from the extracted content: extraction
 * discards navigation, and a blog's roll of other blogs lives in exactly the
 * furniture it discards. That roll is the most valuable link source there is for a
 * crawl like this one — it is how a hand-tended web finds the rest of itself.
 */
function collectLinks(document: Document, base: string): string[] {
  const found = new Set<string>();
  for (const anchor of Array.from(document.querySelectorAll("a[href]"))) {
    const href = anchor.getAttribute("href");
    if (!href || href.startsWith("#")) continue;

    let target: URL;
    try {
      target = new URL(href, base);
    } catch {
      continue;
    }
    if (target.protocol !== "https:" && target.protocol !== "http:") continue;
    if (!isCrawlable(target.hostname)) continue;

    // Fragments are the same document; query strings usually are too on a blog,
    // and dropping them collapses a lot of near-duplicate crawling.
    target.hash = "";
    if (looksLikeAsset(target.pathname)) continue;

    found.add(target.href);
    if (found.size >= 300) break;
  }
  return [...found];
}

/**
 * Links written into the prose, pulled back out of the extracted markdown.
 *
 * Extraction has already discarded navigation, headers and footers by this point,
 * so anything still carrying a link here was in the body of the piece.
 */
function markdownLinks(markdown: string, base: string): string[] {
  const found = new Set<string>();
  for (const match of markdown.matchAll(/\]\(([^()\s]+)/g)) {
    const href = match[1];
    if (!href || href.startsWith("#")) continue;
    try {
      const target = new URL(href, base);
      if (target.protocol !== "https:" && target.protocol !== "http:") continue;
      if (!isCrawlable(target.hostname)) continue;
      target.hash = "";
      if (looksLikeAsset(target.pathname)) continue;
      found.add(target.href);
    } catch {
      continue;
    }
  }
  return [...found];
}

const ASSET = /\.(png|jpe?g|gif|svg|webp|avif|ico|css|js|mjs|json|xml|rss|atom|pdf|zip|gz|tar|mp[34]|m4a|mov|webm|woff2?|ttf|eot)$/i;

function looksLikeAsset(pathname: string): boolean {
  return ASSET.test(pathname);
}

export function hostOf(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return "";
  }
}
