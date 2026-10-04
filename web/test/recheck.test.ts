import { beforeEach, describe, expect, it } from "vitest";
import { apply } from "../src/modes";
import { recheck } from "../src/recheck";
import { health } from "../src/health";
import { reset } from "./helpers";

const PAGE = `<!doctype html><html><head><title>t</title></head><body>
<header><nav><a href="/">Home</a></nav></header>
<main><article><h1>Title</h1><p>Words on the page.</p></article></main>
<aside class="rail">Suggested</aside><aside class="rail">More</aside>
<div role="contentinfo">Footer</div>
<script>var notWords = "this is code, not text";</script>
<style>.x{color:red}</style>
</body></html>`;

describe("recheck()", () => {
  beforeEach(() => reset(PAGE));

  it("is null when no custom version is on the page", async () => {
    apply({ mode: "minimal", custom: null });
    expect(await recheck(false)).toBeNull();
  });

  it("counts what each hide selector still finds — hidden elements included", async () => {
    apply({ mode: "custom", custom: { base: "clean", css: "", hide: [".rail", ".gone", "div["] } });
    const check = await recheck(false);
    // Our own display:none does not stop a selector matching: hidden is still found.
    expect(check!.matches[".rail"]).toBe(2);
    expect(check!.matches[".gone"]).toBe(0);
    // A selector the engine rejects counts as matching nothing rather than throwing.
    expect(check!.matches["div["]).toBe(0);
  });

  it("fingerprints landmarks by tag or role", async () => {
    apply({ mode: "custom", custom: { base: "clean", css: "", hide: [] } });
    const check = await recheck(false);
    expect(check!.landmarks).toEqual({ header: 1, nav: 1, main: 1, article: 1, aside: 2, footer: 1, h1: 1 });
  });

  it("does not see a version switched off while it waited for idle", async () => {
    apply({ mode: "custom", custom: { base: "clean", css: "", hide: [".rail"] } });
    const pending = recheck(true);
    apply({ mode: "clean", custom: null });
    expect(await pending).toBeNull();
  });
});

describe("health().totalText", () => {
  beforeEach(() => reset(PAGE));

  it("counts the page's words, not its scripts or styles", () => {
    const total = health().totalText;
    expect(total).toBe("HomeTitleWords on the page.SuggestedMoreFooter".length);
  });
});
