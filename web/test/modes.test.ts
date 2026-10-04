import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { apply } from "../src/modes";
import { FAILSAFE_MS } from "../src/minimal";
import { reset, restoreReadyState, setReadyState } from "./helpers";

const PAGE = `<!doctype html><html><head>
<link rel="stylesheet" href="/a.css">
<link rel="stylesheet" href="/b.css" media="screen and (min-width: 1px)">
<style>.x{color:red} .flyout{display:none}</style>
</head><body>
<header><nav><ul><li><a href="/">Home</a><ul><li><a href="/sub">Sub</a></li></ul></li></ul></nav></header>
<div id="hero" style="color: blue; padding: 4px">Hello</div>
<div id="gone" style="display:none">Secret menu</div>
<svg width="10" height="10"><style>.icon{fill:red}</style><rect style="fill: red" width="5" height="5"/></svg>
<p>Body text</p>
</body></html>`;

function snapshotAttrs(): string {
  return Array.from(document.querySelectorAll("*"))
    .map((el) => `${el.localName}:${Array.from(el.attributes).map((a) => `${a.name}=${a.value}`).sort().join(",")}`)
    .join("\n");
}

describe("apply()", () => {
  beforeEach(() => reset(PAGE));
  afterEach(() => restoreReadyState());

  it("minimal → original restores stylesheets and inline styles exactly", () => {
    const before = snapshotAttrs();
    apply({ mode: "minimal", custom: null });
    expect(document.querySelector("link[href='/a.css']")!.getAttribute("media")).toBe("not all");
    expect(document.querySelector("link[href='/b.css']")!.getAttribute("media")).toBe("not all");
    expect(document.querySelector("head > style:not([data-zentic])")!.getAttribute("media")).toBe("not all");
    expect(document.getElementById("hero")!.hasAttribute("style")).toBe(false);
    expect(document.querySelector("style[data-zentic='minimal']")).not.toBeNull();

    apply({ mode: "original", custom: null });
    expect(document.querySelector("[data-zentic]")).toBeNull();
    expect(snapshotAttrs()).toBe(before);
  });

  it("is idempotent", () => {
    apply({ mode: "minimal", custom: null });
    apply({ mode: "minimal", custom: null });
    expect(document.querySelectorAll("style[data-zentic='minimal']").length).toBe(1);
    expect(document.getElementById("hero")!.getAttribute("data-zentic-style")).toBe("color: blue; padding: 4px");
    apply({ mode: "clean", custom: null });
    expect(document.getElementById("hero")!.getAttribute("style")).toBe("color: blue; padding: 4px");
  });

  it("keeps SVG internals styled", () => {
    apply({ mode: "minimal", custom: null });
    expect(document.querySelector("rect")!.getAttribute("style")).toBe("fill: red");
    expect(document.querySelector("svg style")!.hasAttribute("media")).toBe(false);
  });

  it("keeps what the site hid hidden once its CSS is gone", () => {
    apply({ mode: "minimal", custom: null });
    expect(document.getElementById("gone")!.hasAttribute("data-zentic-hidden")).toBe(true);
  });

  it("disables stylesheets the site adds later, and re-disables media flips", async () => {
    apply({ mode: "minimal", custom: null });
    const late = document.createElement("link");
    late.rel = "stylesheet";
    late.href = "/late.css";
    document.head.appendChild(late);
    const inline = document.createElement("div");
    inline.setAttribute("style", "position:fixed");
    document.body.appendChild(inline);
    await new Promise((r) => setTimeout(r, 0));
    expect(late.getAttribute("media")).toBe("not all");
    expect(inline.hasAttribute("style")).toBe(false);

    // <link media=print onload="this.media='all'">
    late.setAttribute("media", "all");
    await new Promise((r) => setTimeout(r, 0));
    expect(late.getAttribute("media")).toBe("not all");
    apply({ mode: "original", custom: null });
    expect(late.getAttribute("media")).toBe("all");
    expect(inline.getAttribute("style")).toBe("position:fixed");
  });

  it("reads what the site hides in subtrees it builds later, under the site's own CSS", async () => {
    vi.useFakeTimers();
    apply({ mode: "minimal", custom: null });
    const nav = document.createElement("div");
    nav.innerHTML = `<div class="flyout"><h2>Shop</h2></div><a href="/">Home</a>`;
    document.body.appendChild(nav);
    await vi.advanceTimersByTimeAsync(1000);
    expect(document.querySelector(".flyout")!.hasAttribute("data-zentic-hidden")).toBe(true);
    expect(document.querySelector("a[href='/']")!.hasAttribute("data-zentic-hidden")).toBe(false);
    // and the site's sheets are off again afterwards
    expect(document.querySelector("head > style:not([data-zentic])")!.getAttribute("media")).toBe("not all");
    expect(document.querySelector("style[data-zentic='minimal']")!.hasAttribute("media")).toBe(false);
    vi.useRealTimers();
  });

  it("follows the site showing a hidden element via inline style", async () => {
    apply({ mode: "minimal", custom: null });
    const gone = document.getElementById("gone")!;
    gone.setAttribute("style", "display:block");
    await new Promise((r) => setTimeout(r, 0));
    expect(gone.hasAttribute("data-zentic-hidden")).toBe(false);
  });

  it("custom CSS lands after the minimal sheet", () => {
    apply({ mode: "custom", custom: { base: "minimal", css: "h1{color:red}", hide: ["#hero"] } });
    const sheets = Array.from(document.querySelectorAll("style[data-zentic]")).map((s) => s.getAttribute("data-zentic"));
    expect(sheets.indexOf("minimal")).toBeLessThan(sheets.indexOf("custom"));
    expect(document.getElementById("zentic-custom")!.textContent).toBe("h1{color:red}");
  });

  it("custom on clean leaves author styles on; switching away removes everything", () => {
    const result = apply({ mode: "custom", custom: { base: "clean", css: "p{margin:0}", hide: ["#hero", "body", "p:::bad"] } });
    expect(document.querySelector("link[href='/a.css']")!.hasAttribute("media")).toBe(false);
    expect(result.hidden).toEqual([{ selector: "#hero", count: 1 }]);
    expect(result.rejected).toEqual(["body", "p:::bad"]);
    apply({ mode: "original", custom: null });
    expect(document.querySelector("[data-zentic], #zentic-custom")).toBeNull();
  });

  it("custom with no version falls back to clean", () => {
    apply({ mode: "custom", custom: null });
    expect(document.querySelector("style[data-zentic='minimal']")).toBeNull();
  });
});

describe("reveal failsafe", () => {
  beforeEach(() => {
    reset(PAGE);
    vi.useFakeTimers();
  });
  afterEach(() => {
    vi.useRealTimers();
    restoreReadyState();
  });

  it("hides at document-start and always reveals, even if DOMContentLoaded never comes", () => {
    setReadyState("loading");
    apply({ mode: "minimal", custom: null });
    expect(document.querySelector("style[data-zentic='guard']")).not.toBeNull();
    vi.advanceTimersByTime(FAILSAFE_MS);
    expect(document.querySelector("style[data-zentic='guard']")).toBeNull();
    // and the transform still happened
    expect(document.querySelector("style[data-zentic='minimal']")).not.toBeNull();
  });

  it("waits for the site's stylesheets after DOMContentLoaded, then reveals", async () => {
    setReadyState("loading");
    apply({ mode: "minimal", custom: null });
    document.dispatchEvent(new Event("DOMContentLoaded"));
    await vi.advanceTimersByTimeAsync(10);
    // Sheets still in flight: reading what the site hides now would read nothing.
    expect(document.querySelector("style[data-zentic='guard']")).not.toBeNull();
    expect(document.querySelector("style[data-zentic='minimal']")).toBeNull();
    for (const link of Array.from(document.querySelectorAll("link"))) link.dispatchEvent(new Event("load"));
    await vi.advanceTimersByTimeAsync(0);
    expect(document.querySelector("style[data-zentic='guard']")).toBeNull();
    expect(document.querySelector("style[data-zentic='minimal']")).not.toBeNull();
  });

  it("a stylesheet that never loads cannot hold the page hidden past the failsafe", async () => {
    setReadyState("loading");
    apply({ mode: "minimal", custom: null });
    document.dispatchEvent(new Event("DOMContentLoaded"));
    await vi.advanceTimersByTimeAsync(FAILSAFE_MS);
    expect(document.querySelector("style[data-zentic='guard']")).toBeNull();
    expect(document.querySelector("style[data-zentic='minimal']")).not.toBeNull();
  });

  it("switching away before the page is ready still reveals", () => {
    setReadyState("loading");
    apply({ mode: "minimal", custom: null });
    apply({ mode: "clean", custom: null });
    expect(document.querySelector("style[data-zentic='guard']")).toBeNull();
    vi.advanceTimersByTime(FAILSAFE_MS * 2);
    expect(document.querySelector("style[data-zentic='minimal']")).toBeNull();
  });
});

describe("custom hides never become the site's own", () => {
  beforeEach(() => reset(PAGE));
  afterEach(() => restoreReadyState());

  // Found in review: Minimal read "what the site hides" with the custom hide
  // sheet still on, so a version's hides were baked in as the site's.
  it("custom(minimal) → minimal brings back what the version hid", () => {
    apply({ mode: "custom", custom: { base: "minimal", css: "", hide: ["#hero"] } });
    apply({ mode: "minimal", custom: null });
    expect(document.getElementById("hero")!.hasAttribute("data-zentic-hidden")).toBe(false);
    // While the site's own hidden menu stays hidden.
    expect(document.getElementById("gone")!.hasAttribute("data-zentic-hidden")).toBe(true);
  });

  it("a clean-base preview followed by a minimal-base one does not inherit its hides", () => {
    apply({ mode: "custom", custom: { base: "clean", css: "", hide: ["#hero"] } });
    apply({ mode: "custom", custom: { base: "minimal", css: "", hide: [] } });
    expect(document.getElementById("hero")!.hasAttribute("data-zentic-hidden")).toBe(false);
  });
});
