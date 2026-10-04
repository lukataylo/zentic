// Defensive CSS sanitiser for model-written custom versions.
//
// Swift sanitises too; this is the second lock. The threat is not a broken
// layout (that is reversible) but CSS that *fetches*: a `url()` or `@import`
// beacons to a third party on every visit, invisibly. So anything that can name
// a resource goes, except inline `data:` URIs, which cannot leave the machine.

export const MAX_CSS_LENGTH = 60_000;

export function sanitizeCSS(input: string): string {
  let css = input.slice(0, MAX_CSS_LENGTH);
  // Comments can hide tokens from the patterns below (`@im/**/port`).
  css = css.replace(/\/\*[\s\S]*?(\*\/|$)/g, "");
  // HTML-ish breakouts are harmless via textContent, but strip them anyway.
  css = css.replace(/<\/?\s*style/gi, "");
  // At-rules spelled with escapes (`@\69mport`) — drop the whole statement.
  css = css.replace(/@[\w-]*\\[^;{]*(;|\{[^}]*\})/g, "");
  css = css.replace(/@import[^;]*;?/gi, "");
  css = removeBlocks(css, /@font-face\s*\{/gi);
  // Functions whose *name* is escaped (`u\72l(`) — neutralise the name.
  css = css.replace(/[\w-]*\\[\w\\-]*\s*\(([^()]|\([^()]*\))*\)/g, "none");
  // url(...) unless it is data:
  css = css.replace(/url\(\s*(['"]?)([\s\S]*?)\1\s*\)/gi, (_match, _quote: string, body: string) =>
    /^\s*data:/i.test(body) ? `url("${body.replace(/"/g, "%22")}")` : "none",
  );
  // Fetching functions that do not need url(): image-set("a.png" 1x), src("…").
  css = css.replace(/(-webkit-)?image-set\s*\(([^()]|\([^()]*\))*\)/gi, "none");
  css = css.replace(/\bsrc\s*\(([^()]|\([^()]*\))*\)/gi, "none");
  css = css.replace(/expression\s*\(([^()]|\([^()]*\))*\)/gi, "none");
  css = css.replace(/javascript\s*:/gi, "");
  css = css.replace(/-moz-binding\s*:[^;}]*/gi, "");
  css = css.replace(/behavio(u)?r\s*:[^;}]*/gi, "");
  return css.trim();
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

/** A hide selector must be a selector, nothing that could close the rule it sits in. */
export function isSafeSelectorText(selector: string): boolean {
  return selector.length > 0 && selector.length <= 400 && !/[{};<@\\]/.test(selector);
}
