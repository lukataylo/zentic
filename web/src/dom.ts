// DOM measurement helpers shared by detection, extraction and skeletons.
//
// Every geometry read here degrades instead of throwing, because two very
// different environments run this code: WebKit, where layout is real, and jsdom
// under vitest, where `getBoundingClientRect()` returns zeros and nothing has a
// size. Logic that only works with real layout is untestable, so the heuristics
// that matter are written to work from structure and fall back to geometry as a
// bonus — not the other way round.

// Node type constants, rather than `Node.ELEMENT_NODE`. The global `Node` is not
// the same object as the one behind a document from another realm — which every
// corpus test uses — and it does not exist at all outside a DOM environment.
export const ELEMENT_NODE = 1;
export const TEXT_NODE = 3;

/** Rendered area in CSS px², best effort. Returns 0 when layout is unavailable. */
export function elementArea(element: Element): number {
  try {
    const rect = element.getBoundingClientRect();
    if (rect.width > 0 && rect.height > 0) return Math.round(rect.width * rect.height);
  } catch {
    // No layout engine.
  }

  const html = element as HTMLElement;
  if (html.offsetWidth > 0 && html.offsetHeight > 0) {
    return html.offsetWidth * html.offsetHeight;
  }

  // Presentational width/height attributes are the last resort, and the only
  // signal available for a <canvas> in a document that was never laid out.
  const width = Number.parseInt(element.getAttribute("width") ?? "", 10);
  const height = Number.parseInt(element.getAttribute("height") ?? "", 10);
  return Number.isFinite(width) && Number.isFinite(height) ? width * height : 0;
}

export function viewportSize(doc: Document): { width: number; height: number } {
  const view = doc.defaultView;
  const width = view?.innerWidth || doc.documentElement?.clientWidth || 1280;
  const height = view?.innerHeight || doc.documentElement?.clientHeight || 900;
  return { width, height };
}

/** Words, counted the same way everywhere so thresholds are comparable. */
export function countWords(text: string): number {
  const trimmed = text.trim();
  if (!trimmed) return 0;
  return trimmed.split(/\s+/).length;
}

export function textOf(node: Node | null | undefined): string {
  return (node?.textContent ?? "").replace(/\s+/g, " ").trim();
}

/**
 * Selectors that a `max-width` media query hides.
 *
 * A reliable not-main-content signal: sites hide chrome on phones and keep the
 * article, so anything the mobile layout throws away is almost never the thing
 * the reader came for. Same trick Defuddle uses for extraction; here it feeds
 * `DOMSkeleton.hiddenOnNarrow`.
 *
 * Cross-origin sheets throw on `cssRules` access, which is expected and skipped.
 */
export function narrowHiddenSelectors(doc: Document, maxWidth = 600): Set<string> {
  const selectors = new Set<string>();

  let sheets: StyleSheet[] = [];
  try {
    sheets = Array.from(doc.styleSheets);
  } catch {
    return selectors;
  }

  for (const sheet of sheets) {
    let rules: CSSRuleList | undefined;
    try {
      rules = (sheet as CSSStyleSheet).cssRules;
    } catch {
      continue;
    }
    if (!rules) continue;

    for (const rule of Array.from(rules)) {
      const media = rule as CSSMediaRule;
      if (typeof media.conditionText !== "string") continue;
      const match = /max-width\s*:\s*(\d+)/.exec(media.conditionText);
      if (!match || Number.parseInt(match[1]!, 10) > maxWidth) continue;

      for (const inner of Array.from(media.cssRules ?? [])) {
        const style = inner as CSSStyleRule;
        if (!style.selectorText || !style.style) continue;
        if (style.style.getPropertyValue("display").trim() === "none") {
          selectors.add(style.selectorText);
        }
      }
    }
  }

  return selectors;
}

/** `element.matches` over a selector set, tolerating selectors jsdom cannot parse. */
export function matchesAny(element: Element, selectors: Iterable<string>): boolean {
  for (const selector of selectors) {
    try {
      if (element.matches(selector)) return true;
    } catch {
      continue;
    }
  }
  return false;
}
