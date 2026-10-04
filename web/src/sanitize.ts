// Defensive CSS sanitiser for model-written custom versions.
//
// Swift sanitises too; this is the second lock. The threat is not a broken
// layout (that is reversible) but CSS that *fetches*: a `url()` or `@import`
// beacons to a third party on every visit, invisibly. So anything that can name
// a resource goes, except inline `data:` URIs, which cannot leave the machine.

export const MAX_CSS_LENGTH = 60_000;

export function sanitizeCSS(input: string): string {
  let css = input.slice(0, MAX_CSS_LENGTH);
  // Repeat to a fixed point, replacing with a space rather than nothing: a
  // single pass that *deletes* a token can splice the text around it into a
  // new one (`urjavascript:l(` → `url(`).
  for (let pass = 0; pass < 8; pass++) {
    const before = css;
    css = css.replace(/\/\*[\s\S]*?(\*\/|$)/g, " ");
    // No escapes at all: they are how every filter below would be spelled around.
    css = css.replace(/\\/g, " ");
    css = css.replace(/<\/?\s*style/gi, " ");
    css = removeBlocks(css, /@font-face\s*\{/gi);
    css = css.replace(/@import[^;]*;?/gi, " ");
    css = css.replace(/@namespace[^;]*;?/gi, " ");
    css = css.replace(/url\(\s*(['"]?)([\s\S]*?)\1\s*\)/gi, (_m, _q: string, body: string) =>
      /^\s*data:/i.test(body) ? `url("${body.replace(/"/g, "%22")}")` : "none",
    );
    css = css.replace(/(-webkit-)?image-set\s*\(([^()]|\([^()]*\))*\)/gi, "none");
    css = css.replace(/\bsrc\s*\(([^()]|\([^()]*\))*\)/gi, "none");
    css = css.replace(/expression\s*\(/gi, " (");
    css = css.replace(/javascript\s*:/gi, " ");
    css = css.replace(/-moz-binding|behavio(u)?r\s*:/gi, " ");
    if (css === before) break;
  }
  // Belt and braces: if anything that can fetch is still there, the whole
  // sheet goes. A missing restyle is a small loss; a beacon is not.
  return fetchesRemotely(css) ? "" : css.trim();
}

/** Whether CSS still contains anything that can reach the network. */
export function fetchesRemotely(css: string): boolean {
  const lower = css.toLowerCase();
  if (/@import|image-set\s*\(|\bsrc\s*\(|\\/.test(lower)) return true;
  const urls = lower.match(/url\s*\(\s*['"]?\s*[^'"\s)]{0,8}/g) ?? [];
  return urls.some((u) => !/url\s*\(\s*['"]?\s*data:/.test(u));
}

/** Remove `@rule { ... }` blocks with balanced braces. */
function removeBlocks(css: string, opener: RegExp): string {
  let out = css;
  for (;;) {
    opener.lastIndex = 0;
    const match = opener.exec(out);
    if (!match) return out;
    let depth = 0;
    let end = out.length;
    for (let i = match.index + match[0].length - 1; i < out.length; i++) {
      if (out[i] === "{") depth++;
      else if (out[i] === "}" && --depth === 0) {
        end = i + 1;
        break;
      }
    }
    out = out.slice(0, match.index) + out.slice(end);
  }
}

/**
 * A hide selector must be a selector, nothing that could close the rule it
 * sits in. Backslash escapes are allowed — Tailwind class names need them
 * (`.md\\:hidden`) and a selector cannot fetch anything.
 */
export function isSafeSelectorText(selector: string): boolean {
  return selector.length > 0 && selector.length <= 400 && !/[{};<@]/.test(selector) && !/url\s*\(/i.test(selector);
}
