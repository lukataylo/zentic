import { beforeEach, describe, expect, it } from "vitest";

import { ReaderView } from "../src/render/view.js";
import type { ExtractionResult } from "../src/wire.js";

// Two properties of the overlay, both load-bearing since the reader became
// translucent:
//
//  1. Its ground really is translucent, by default, with no theme involved.
//  2. `isCovering` tells the truth. It is the only thing standing between a
//     concealed document and a blank window — `VisibilityController` hides the
//     original for exactly as long as this getter is true.
//
// jsdom is not WebKit and never will be, so nothing here is about how the page
// *looks*. What it can check is which element carries the ground, and that every
// teardown path flips the getter.

const RESULT: ExtractionResult = {
  url: "https://example.com/article",
  archetype: "article",
  title: "A title",
  wordCount: 120,
  confidence: 0.9,
  isFidelitySensitive: false,
  sections: [
    { id: "s1", kind: "paragraph", markdown: "Body text, long enough to be a lead paragraph." },
  ],
};

const host = () => document.getElementById("zentic-reader-root");
const alphaOf = (background: string) => {
  const match = /rgba?\([^)]*?,\s*([\d.]+)\s*\)/.exec(background);
  return match ? Number(match[1]) : 1;
};

describe("the reader overlay", () => {
  let view: ReaderView;

  beforeEach(() => {
    host()?.remove();
    document.body.innerHTML = "<p>the original page</p>";
    view = new ReaderView(document);
  });

  it("paints a translucent ground by default", () => {
    view.render(RESULT, undefined);

    // jsdom normalises `#rrggbbaa` to `rgba(…)`, which is what makes the alpha
    // readable here at all.
    const background = host()!.style.getPropertyValue("background");
    expect(background).toMatch(/^rgba\(/);
    expect(alphaOf(background)).toBeLessThan(1);
    expect(alphaOf(background)).toBeGreaterThan(0.5);
  });

  it("covers the viewport once it has rendered", () => {
    expect(view.isCovering).toBe(false);

    view.render(RESULT, undefined);

    expect(view.isCovering).toBe(true);
    expect(view.isRendered).toBe(true);
  });

  it("stops covering when ⌘\\ hides it, and covers again on the way back", () => {
    view.render(RESULT, undefined);

    view.hide();
    // Still mounted — ⌘\ must be instant and must not rebuild anything — but a
    // `display: none` overlay is not covering anything.
    expect(view.isRendered).toBe(true);
    expect(view.isCovering).toBe(false);

    view.show();
    expect(view.isCovering).toBe(true);
  });

  it("stops covering when its content is cleared for a route change", () => {
    view.render(RESULT, undefined);
    view.clear();

    expect(view.isRendered).toBe(true);
    expect(view.isCovering).toBe(false);
  });

  it("stops covering when it is destroyed", () => {
    view.render(RESULT, undefined);
    view.destroy();

    expect(view.isCovering).toBe(false);
  });

  it("stops covering when the page rips the host out of its own DOM", () => {
    // An SPA assigning to `body.innerHTML` does exactly this. Nothing tells the
    // reader, which is why the coverage predicate is read live rather than
    // remembered.
    view.render(RESULT, undefined);
    document.body.innerHTML = "<p>the router replaced everything</p>";

    expect(view.isCovering).toBe(false);
  });
});
