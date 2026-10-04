import { describe, expect, it } from "vitest";
import { fetchesRemotely, sanitizeCSS } from "../src/sanitize";

describe("sanitizeCSS", () => {
  it("removes anything that can fetch", () => {
    const out = sanitizeCSS(`
      @import url("https://evil.test/a.css");
      @import "https://evil.test/b.css";
      @font-face { font-family: X; src: url(https://evil.test/f.woff2) format("woff2"); }
      body { background: url(https://evil.test/p.gif); }
      .a { background-image: url( 'https://evil.test/q.png' ) }
      .b { background-image: image-set("https://evil.test/r.png" 1x, "s.png" 2x); }
      .c { background: u\\72l(https://evil.test/t.png); }
      @\\69mport "https://evil.test/u.css";
      .d { width: expression(alert(1)); }
      .e { color: red; }
    `);
    // A URL left as inert text is harmless; one the browser would fetch is not.
    expect(fetchesRemotely(out)).toBe(false);
    expect(out).not.toMatch(/@import|@font-face|expression\(|url\(\s*['"]?https/i);
    expect(out).toContain(".e { color: red; }");
  });

  it("keeps data: URIs", () => {
    const out = sanitizeCSS(`.x { background: url("data:image/svg+xml;utf8,<svg/>"); }`);
    expect(out).toContain("url(\"data:image/svg+xml;utf8,<svg/>\")");
  });

  it("cannot be smuggled through comments", () => {
    const out = sanitizeCSS(`@im/**/port "https://evil.test/x.css";`);
    expect(out).not.toMatch(/@import/);
    expect(fetchesRemotely(out)).toBe(false);
  });

  // Found in review: deleting one token spliced its neighbours into another,
  // and two sanitizers in series completed each other's work.
  it.each([
    "body{background:urjavajavascript:script:l(https://evil.test/p.png)}",
    '@imjavajavascript:script:port "https://evil.test/x.css";',
    "a{background:urlexpression(https://evil.test/a.png)}",
    "a{background:\\75 rl(https://evil.test/a.png)}",
    'a{background:-webkit-image-set("https://evil.test/a.png" 1x)}',
    "@import'https://evil.test/x.css';",
  ])("cannot be spliced into a fetch: %s", (css) => {
    const once = sanitizeCSS(css);
    expect(fetchesRemotely(once)).toBe(false);
    expect(fetchesRemotely(sanitizeCSS(once))).toBe(false);
  });
});
