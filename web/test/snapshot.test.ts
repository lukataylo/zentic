import { beforeEach, describe, expect, it } from "vitest";
import { SNAPSHOT_BUDGET, snapshot } from "../src/snapshot";
import { corpus, reset } from "./helpers";

describe("snapshot()", () => {
  beforeEach(() => reset("<body></body>"));

  it("collapses runs of look-alike siblings", () => {
    const items = Array.from({ length: 30 }, (_, i) => `<li class="card"><a href="/${i}">Story ${i}</a></li>`).join("");
    reset(`<html><head><title>Front</title></head><body><nav id="top"><a href="/">Home</a></nav><ul class="stories">${items}</ul></body></html>`);
    const out = snapshot();
    expect(out).toContain("Title: Front");
    expect(out).toContain("nav#top");
    expect(out).toContain("ul.stories");
    expect(out).toContain("li.card");
    expect(out).toContain("(×29 similar)");
    expect(out.match(/li\.card/g)!.length).toBe(1);
  });

  it("keeps stable classes and drops hashed ones", () => {
    reset(`<body><div class="Header_root__a8Fk2 header sc-bdfBwQ">x</div></body>`);
    const out = snapshot();
    expect(out).toContain("div.header");
    expect(out).not.toContain("sc-bdfBwQ");
  });

  it.each(["news-apnews-hub.html", "wiki-wikipedia-riemann.html", "docs-nodejs-fs.html"])(
    "stays within budget on %s",
    (name) => {
      reset(corpus(name));
      const out = snapshot();
      expect(out.length).toBeLessThanOrEqual(SNAPSHOT_BUDGET);
      expect(out.split("\n").length).toBeGreaterThan(20);
    },
    30_000,
  );
});
