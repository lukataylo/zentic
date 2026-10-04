import { isSafeSelectorText } from "./sanitize";
import { isOwn, type SelectorReport } from "./types";

/** A hide selector may not swallow the page: this share of body text is the ceiling. */
export const MAX_TEXT_SHARE = 0.7;
const MIN_TEXT_FOR_SHARE_CHECK = 200;

/**
 * Check selectors a model proposed for hiding. Each one fails independently:
 * a bad selector is reported and dropped, it never takes the others with it.
 */
export function validate(selectors: string[]): SelectorReport[] {
  const bodyText = document.body?.textContent?.replace(/\s+/g, " ").trim().length ?? 0;
  return selectors.map((raw) => {
    const selector = String(raw).trim();
    if (!isSafeSelectorText(selector)) return { selector, count: 0, ok: false, reason: "unsafe characters" };
    let matches: Element[];
    try {
      matches = Array.from(document.querySelectorAll(selector));
    } catch {
      return { selector, count: 0, ok: false, reason: "invalid selector" };
    }
    const own = matches.filter((el) => !isOwn(el));
    if (own.some((el) => el === document.documentElement || el === document.body || el === document.head)) {
      return { selector, count: own.length, ok: false, reason: "matches the whole page" };
    }
    if (bodyText >= MIN_TEXT_FOR_SHARE_CHECK) {
      for (const el of own) {
        const text = el.textContent?.replace(/\s+/g, " ").trim().length ?? 0;
        if (text / bodyText > MAX_TEXT_SHARE) {
          return { selector, count: own.length, ok: false, reason: "hides most of the page" };
        }
      }
    }
    return { selector, count: own.length, ok: true };
  });
}
