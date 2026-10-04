import { appliedCustom } from "./custom";
import { health } from "./health";
import { isSafeSelectorText } from "./sanitize";
import { OWN } from "./types";

/**
 * What a kept custom version does to this page: how many elements each hide
 * selector still finds, how much of the text stays visible, whether the page
 * scrolls sideways, and the page's rough shape. Swift compares it with the
 * same measurement taken when the version was kept (`Drift.swift`).
 *
 * Only ever run on request — Swift asks once a page has loaded, and at most
 * once per site every few minutes — never at document-start.
 */
export interface PageCheck {
  /** Elements each hide selector matches now, by selector. */
  matches: Record<string, number>;
  visibleText: number;
  totalText: number;
  overflowsX: boolean;
  /** Counts of the page's landmarks: a cheap fingerprint of what kind of page it is. */
  landmarks: Record<string, number>;
}

/** Landmark → selector. Tags and their ARIA roles, which many sites use instead. */
const LANDMARKS: Record<string, string> = {
  header: "header, [role=banner]",
  nav: "nav, [role=navigation]",
  main: "main, [role=main]",
  article: "article",
  aside: "aside, [role=complementary]",
  footer: "footer, [role=contentinfo]",
  h1: "h1",
};

/**
 * Measure the custom version on this page. `idle` waits for the browser to be
 * idle first, so a check never competes with the page finishing its own work.
 * Null when no custom version is applied (or it was switched off meanwhile).
 */
export async function recheck(idle = true): Promise<PageCheck | null> {
  if (idle) await whenIdle();
  const version = appliedCustom();
  if (!version || !document.body) return null;

  const matches: Record<string, number> = {};
  for (const selector of version.hide) matches[selector] = count(selector);
  const landmarks: Record<string, number> = {};
  for (const [name, selector] of Object.entries(LANDMARKS)) landmarks[name] = count(selector);
  const { visibleText, totalText, overflowsX } = health();
  return { matches, visibleText, totalText, overflowsX, landmarks };
}

function count(selector: string): number {
  if (!isSafeSelectorText(selector)) return 0;
  try {
    let n = 0;
    for (const el of document.querySelectorAll(selector)) if (!el.hasAttribute(OWN)) n++;
    return n;
  } catch {
    return 0;
  }
}

function whenIdle(): Promise<void> {
  return new Promise((resolve) => {
    const ric = (window as Window & { requestIdleCallback?: (cb: () => void, o?: { timeout: number }) => number })
      .requestIdleCallback;
    if (ric) ric.call(window, () => resolve(), { timeout: 3000 });
    else setTimeout(resolve, 200);
  });
}
