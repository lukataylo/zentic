import { countWords, elementArea, matchesAny, narrowHiddenSelectors, viewportSize } from "./dom.js";
import type { DOMSkeleton, SkeletonNode } from "./wire.js";

// Structural fingerprint for recipe inference.
//
// **Privacy contract, and the whole reason this file is separate from
// extraction: a skeleton carries no page text.** Tag names, class and id tokens,
// ARIA roles, geometry, and text *lengths*. Never characters.
//
// That is not belt-and-braces. A skeleton is the one artefact of a page read that
// is allowed to reach a model (to infer a `SiteRecipe`), so if page text could
// ride along in any field, then "your reading never goes to a model" would be
// false. `ExtractionResult` is the type that holds real text, and it stays on the
// device.
//
// Guarded on both sides: `PrivacyContractTests` in Swift, `skeleton.test.ts` here.

/** Elements that never contain a page's content and only spend the node budget. */
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
]);

/** Below this, an element is too small to be anyone's main content. */
const MIN_TEXT_LENGTH = 40;
const MIN_AREA = 4000;

/**
 * URL path with volatile components replaced by `*`.
 *
 * Groups pages of a kind so one recipe covers them: `/posts/12345/my-title`
 * becomes `/posts/*` + `/*`. The rules are heuristic on purpose — the cost of
 * over-generalising is one recipe covering slightly too much of a site, and the
 * cost of under-generalising is a recipe per article.
 */
export function pathPattern(pathname: string): string {
  const segments = pathname.split("/").filter((segment) => segment.length > 0);
  if (segments.length === 0) return "/";

  const generalised = segments.map((segment) => {
    const decoded = safeDecode(segment);
    if (/^\d+$/.test(decoded)) return "*";
    if (/^[0-9a-f]{16,}$/i.test(decoded)) return "*";
    if (/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}/i.test(decoded)) return "*";
    // A slug: long, or hyphenated with a number in it.
    if (decoded.length > 24) return "*";
    if (/\d/.test(decoded) && decoded.length > 4) return "*";
    return decoded;
  });

  return `/${generalised.join("/")}`;
}

function safeDecode(segment: string): string {
  try {
    return decodeURIComponent(segment);
  } catch {
    return segment;
  }
}

/** `body>div:nth-of-type(2)>article` — stable enough for a recipe to name. */
function cssPath(element: Element): string {
  const parts: string[] = [];
  let current: Element | null = element;

  while (current && current.localName !== "html") {
    const tag = current.localName.toLowerCase();
    if (tag === "body") {
      parts.unshift("body");
      break;
    }

    const parent: Element | null = current.parentElement;
    if (!parent) {
      parts.unshift(tag);
      break;
    }

    const siblings = Array.from(parent.children).filter(
      (child) => child.localName === current!.localName,
    );
    parts.unshift(
      siblings.length > 1 ? `${tag}:nth-of-type(${siblings.indexOf(current) + 1})` : tag,
    );
    current = parent;
  }

  return parts.join(">");
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

export interface SkeletonOptions {
  url: string;
  nodeLimit: number;
}

/**
 * Build a skeleton of the document.
 *
 * Nodes are kept largest-area first, because the biggest text-dense box is
 * almost always the content and a truncated skeleton should keep the part that
 * answers the question the model is being asked.
 */
export function buildSkeleton(doc: Document, options: SkeletonOptions): DOMSkeleton {
  const view = viewportSize(doc);
  let origin = "";
  let pattern = "/";
  try {
    const url = new URL(options.url);
    origin = url.origin;
    pattern = pathPattern(url.pathname);
  } catch {
    // Leave the defaults; a skeleton without an origin is useless but harmless.
  }

  const hiddenOnNarrow = narrowHiddenSelectors(doc);
  const candidates: SkeletonNode[] = [];

  for (const element of Array.from(doc.body?.querySelectorAll("*") ?? [])) {
    const tag = element.localName.toLowerCase();
    if (IGNORED_TAGS.has(tag)) continue;

    // Subtree length, not own-text length: what identifies a content container
    // is how much text lives *under* it. Ownership of the characters is the
    // thing we must not transmit, and a count is not the characters.
    const textLength = (element.textContent ?? "").trim().length;
    const area = elementArea(element);
    if (textLength < MIN_TEXT_LENGTH && area < MIN_AREA && !element.hasAttribute("role")) {
      continue;
    }

    const id = element.getAttribute("id") ?? undefined;
    const role = element.getAttribute("role") ?? undefined;

    candidates.push({
      tag,
      classes: Array.from(element.classList).slice(0, 12),
      path: cssPath(element),
      depth: depthOf(element),
      textLength,
      linkCount: element.querySelectorAll("a[href]").length,
      paragraphCount: element.querySelectorAll("p").length,
      area,
      hiddenOnNarrow: matchesAny(element, hiddenOnNarrow),
      ...(id ? { id } : {}),
      ...(role ? { role } : {}),
    });
  }

  // Area first; text length breaks the tie, which is what happens in jsdom and
  // in any document that has not been laid out yet.
  candidates.sort((a, b) => b.area - a.area || b.textLength - a.textLength);

  return {
    origin,
    pathPattern: pattern,
    viewport: { width: Math.round(view.width), height: Math.round(view.height) },
    nodes: candidates.slice(0, Math.max(1, options.nodeLimit)),
  };
}

/** Word count of a whole document, used only for debug logging. */
export function documentWordCount(doc: Document): number {
  return countWords(doc.body?.textContent ?? "");
}
