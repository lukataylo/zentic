/**
 * How readable the page is right now — measured before and after a custom
 * version is previewed, so a stylesheet that hides or wrecks the content is
 * caught before the user is asked to keep it.
 *
 * Counts the characters of text the user can actually see: in a rendered,
 * visible, non-zero-sized element. Not perfect (it cannot see text the same
 * colour as its background), but it catches the failures that matter — a
 * rule that hides the main column, collapses a table, or pushes the content
 * off-screen.
 */
export interface Health {
  /** Characters of visible text. */
  visibleText: number;
  /**
   * Characters of text in the document, shown or not. Visible text as a share
   * of it compares pages of different lengths — what a re-check needs, since
   * the page a version was kept on is rarely the page it is checked on.
   */
  totalText: number;
  /** The page scrolls sideways, beyond a small tolerance. */
  overflowsX: boolean;
}

export function health(): Health {
  const body = document.body;
  if (!body) return { visibleText: 0, totalText: 0, overflowsX: false };
  const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
  const seen = new Map<Element, boolean>();
  let visibleText = 0;
  let totalText = 0;
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const length = node.nodeValue?.trim().length ?? 0;
    if (length === 0) continue;
    const parent = node.parentElement;
    if (!parent || NOT_TEXT.has(parent.localName)) continue;
    totalText += length;
    let visible = seen.get(parent);
    if (visible === undefined) {
      visible = isVisible(parent);
      seen.set(parent, visible);
    }
    if (visible) visibleText += length;
  }
  const root = document.scrollingElement ?? document.documentElement;
  const overflowsX = root.scrollWidth > window.innerWidth * 1.04 + 8;
  return { visibleText, totalText, overflowsX };
}

/** Elements whose text nodes are code or markup, never words on the page. */
const NOT_TEXT = new Set(["script", "style", "noscript", "template"]);

function isVisible(el: Element): boolean {
  const check = (el as Element & { checkVisibility?: (o: object) => boolean }).checkVisibility;
  if (check && !check.call(el, { opacityProperty: true, visibilityProperty: true })) return false;
  const rect = el.getBoundingClientRect();
  if (rect.width < 1 || rect.height < 1) return false;
  // Pushed entirely off the left or top of the document.
  if (rect.right + window.scrollX < 0 || rect.bottom + window.scrollY < 0) return false;
  return true;
}
