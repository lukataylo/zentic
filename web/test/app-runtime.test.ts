import { describe, expect, it } from "vitest";

(globalThis as { __ZENTIC_TEST__?: boolean }).__ZENTIC_TEST__ = true;
const { escapeHTML, makeH, makeText, plain, removePeerConnections, themeStylesheet, timeAgo } = await import(
  "../src/app-runtime"
);

// Generated apps render text captured from the web. `h` is the escape hatch the
// brief tells every model to use, so it has to be right about the one thing it
// is for: interpolated strings never become markup.

describe("h", () => {
  const h = makeH(document);

  it("escapes interpolated text, including attribute breakouts", () => {
    const hostile = `"><img src=x onerror="alert(1)">`;
    const fragment = h`<p title="${hostile}">${hostile}</p>`;
    const p = fragment.querySelector("p")!;
    expect(fragment.querySelector("img")).toBeNull();
    expect(p.textContent).toBe(hostile);
    expect(p.getAttribute("title")).toBe(hostile);
  });

  it("splices nodes and arrays, and renders nothing for absent values", () => {
    const items = ["a", "<b>"].map((t) => h`<li>${t}</li>`);
    const fragment = h`<ul>${items}${null}${false}${undefined}</ul>`;
    const lis = [...fragment.querySelectorAll("li")].map((li) => li.textContent);
    expect(lis).toEqual(["a", "<b>"]);
    expect(fragment.querySelector("b")).toBeNull();
  });

  it("escapes every character that can open markup or a template", () => {
    expect(escapeHTML(`<>&"'\``)).toBe("&lt;&gt;&amp;&quot;&#39;&#96;");
  });
});

describe("timeAgo", () => {
  const now = Date.parse("2026-10-18T12:00:00Z");
  it("reads like a timeline", () => {
    expect(timeAgo("2026-10-18T11:59:50Z", now)).toBe("now");
    expect(timeAgo("2026-10-18T11:56:00Z", now)).toBe("4m");
    expect(timeAgo("2026-10-18T10:00:00Z", now)).toBe("2h");
    expect(timeAgo("2026-10-15T12:00:00Z", now)).toBe("3d");
    expect(timeAgo(undefined, now)).toBe("");
    expect(timeAgo("garbage", now)).toBe("");
  });
});

describe("theme", () => {
  it("defines the tokens on :root with a dark variant, and loads nothing", () => {
    const css = themeStylesheet();
    expect(css).toContain(":root {");
    expect(css).toContain("--z-bg");
    expect(css).toContain("--z-fg");
    expect(css).toContain("prefers-color-scheme: dark");
    expect(css).not.toMatch(/url\(|@import/);
  });
});

describe("text", () => {
  const text = makeText(document);

  it("keeps captured markup as text and makes links real", () => {
    const fragment = text('<img src=x onerror=alert(1)> see https://example.com/a.\nand [docs](https://docs.example/x)\n\nnext');
    expect(fragment.querySelector("img")).toBeNull();
    const links = [...fragment.querySelectorAll("a")];
    expect(links.map((a) => a.getAttribute("href"))).toEqual(["https://example.com/a", "https://docs.example/x"]);
    expect(links.every((a) => a.target === "_blank" && a.rel === "noopener")).toBe(true);
    expect(links[1]!.textContent).toBe("docs");
    expect(fragment.querySelectorAll("p")).toHaveLength(2);
    expect(fragment.querySelectorAll("br")).toHaveLength(1);
    expect(fragment.textContent).toContain("<img src=x onerror=alert(1)>");
  });

  it("never links anything but http(s)", () => {
    const fragment = text("[click](javascript:alert(1)) data:text/html,x");
    expect(fragment.querySelector("a")).toBeNull();
  });
});

describe("plain", () => {
  it("strips Markdown and cuts at a word", () => {
    expect(plain("# Title\n\nSome **bold** and [a link](https://x.y) here", 200)).toBe("Title Some bold and a link here");
    const cut = plain("one two three four five six seven", 15);
    expect(cut.endsWith("…")).toBe(true);
    expect(cut.length).toBeLessThanOrEqual(16);
    expect(cut).not.toMatch(/ …$/);
  });
});

describe("peer connections", () => {
  it("are removed before any app script can take a reference", () => {
    const fake = {} as Window;
    Object.defineProperty(fake, "RTCPeerConnection", { value: function () {}, configurable: true, writable: true });
    removePeerConnections(fake);
    expect((fake as unknown as Record<string, unknown>)["RTCPeerConnection"]).toBeUndefined();
    expect(() => {
      (fake as unknown as Record<string, unknown>)["RTCPeerConnection"] = function () {};
    }).toThrow();
  });
});
