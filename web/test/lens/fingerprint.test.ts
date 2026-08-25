import { beforeEach, describe, expect, it } from "vitest";

import { band, buildFingerprint, resolveFingerprint, scoreFingerprint } from "../../src/lens/fingerprint.js";
import type { RegionFingerprint } from "../../src/wire.js";

// These tests are mostly about what the fingerprint refuses to do.
//
// The failure it exists to fix is not "the lens stopped working" — that one is
// visible, and the selector list already handles it. It is the invisible one: a
// stale `cssPath` or build hash that still matches after a redesign, matching a
// *different* element, so the op reports `applied` and the drift badge says the
// lens fits while the page says otherwise. Measured on four of five sites.
//
// So the property under test is: **no confident wrong answers.** Every adversarial
// case below — two indistinguishable siblings, a region that was deleted, a
// wrapper with nothing identifying about it, a page where everything the site
// called the region changed — must return `undefined`, because `undefined` is what
// the caller turns into an honest `missed`.

const PAGE = `
  <div id="page">
    <header id="masthead" class="site-head"><h1>Cormorant Publishing</h1></header>
    <main id="content" class="prose" data-testid="articleBody">
      <p>Bitterns boom across the reedbed every spring, and the wardens count them.</p>
      <p>Curlews return in numbers nobody expected after the saltmarsh was restored.</p>
    </main>
    <aside id="rail" class="rail sidebar" role="complementary" data-testid="sidebarColumn">
      <p>Godwits, dunlin and knot arrive together when the tide turns on the flats.</p>
    </aside>
  </div>
`;

function element(selector: string): Element {
  const found = document.querySelector(selector);
  if (!found) throw new Error(`fixture is missing ${selector}`);
  return found;
}

describe("band", () => {
  it("is `floor(log2(1 + value))`, clamped, which is the definition Swift uses", () => {
    expect(band(0)).toBe(0);
    expect(band(1)).toBe(1);
    expect(band(1000)).toBe(9);
    expect(band(1004)).toBe(9);
    // The band is the point: a region that grew by a card is the same band, and
    // "roughly a thousand pixels across" is what survives a different window.
    expect(band(1200)).toBe(10);
    expect(band(2 ** 40)).toBe(31);
    expect(band(-5)).toBe(0);
    expect(band(Number.NaN)).toBe(0);
  });
});

describe("buildFingerprint", () => {
  beforeEach(() => {
    document.body.innerHTML = PAGE;
  });

  it("records what the site calls a region, in bands and names", () => {
    const print = buildFingerprint(element("#rail"));

    expect(print.tag).toBe("aside");
    expect(print.elementID).toBe("rail");
    expect(print.classes).toEqual(["rail", "sidebar"]);
    expect(print.attributeNames).toEqual(["data-testid"]);
    expect(print.role).toBe("complementary");
    expect(print.ancestorTags).toEqual(["div", "body", "html"]);
    expect(print.childCount).toBe(1);
    expect(print.textLengthBand).toBe(band(element("#rail").textContent?.trim().length ?? 0));
  });

  it("carries no page text — it travels with a lens that can be read back", () => {
    const encoded = JSON.stringify([
      buildFingerprint(element("#masthead")),
      buildFingerprint(element("#content")),
      buildFingerprint(element("#rail")),
    ]);

    for (const word of ["Cormorant", "Bitterns", "Curlews", "Godwits"]) {
      expect(encoded).not.toContain(word);
    }
  });

  it("ignores attributes that are state rather than identity", () => {
    // A fingerprint taken while a disclosure was open must still describe the same
    // region once it closes, so the attributes that flip are not evidence.
    const rail = element("#rail");
    const before = buildFingerprint(rail);
    rail.setAttribute("aria-hidden", "true");
    rail.setAttribute("aria-expanded", "false");

    expect(buildFingerprint(rail).attributeNames).toEqual(before.attributeNames);
  });

  it("refuses a per-item id, the same way the catalog does", () => {
    document.body.innerHTML = `
      <shreddit-feed>
        <shreddit-post id="t3_1vx81cr"><p>Dotterel flocks stop over on the tops.</p></shreddit-post>
        <shreddit-post id="t3_1vx91dm"><p>Twite feed on the saltmarsh seed.</p></shreddit-post>
        <shreddit-post id="t3_1vxa2fn"><p>Choughs prospect the cliff caves.</p></shreddit-post>
      </shreddit-feed>`;

    expect(buildFingerprint(element("#t3_1vx81cr")).elementID).toBeUndefined();
  });
});

describe("resolveFingerprint", () => {
  beforeEach(() => {
    document.body.innerHTML = PAGE;
  });

  it("finds the region again on a page that has not changed", () => {
    const print = buildFingerprint(element("#rail"));

    expect(resolveFingerprint(document, print)).toBe(element("#rail"));
    expect(scoreFingerprint(element("#rail"), print)).toBe(1);
  });

  it("survives a redesign that renames every class", () => {
    // The case the tiers cannot help with: the classes are gone, the path moved,
    // and what is left is the role and the attribute the site's own test suite
    // uses. That is enough evidence, and it is the common shape of a redesign.
    const print = buildFingerprint(element("#rail"));
    document.body.innerHTML = `
      <div id="page">
        <div class="shell">
          <header id="masthead" class="x1i10hfl"><h1>Cormorant Publishing</h1></header>
          <main id="content" class="x9f619" data-testid="articleBody">
            <p>Bitterns boom across the reedbed every spring, and the wardens count.</p>
            <p>Curlews return in numbers nobody expected after the marsh was restored.</p>
          </main>
        </div>
        <aside id="rail" class="x78zum5 xdt5ytf" role="complementary" data-testid="sidebarColumn">
          <p>Godwits, dunlin and knot arrive together when the tide turns on flats.</p>
        </aside>
      </div>`;

    expect(resolveFingerprint(document, print)).toBe(element("#rail"));
  });

  it("returns nothing when the region was removed", () => {
    const print = buildFingerprint(element("#rail"));
    element("#rail").remove();

    // Not "the nearest thing" — nothing. The caller reports `missed`, the badge
    // says the lens no longer fits, and the user is told the truth.
    expect(resolveFingerprint(document, print)).toBeUndefined();
  });

  it("returns nothing when the site changed everything it called the region", () => {
    const print = buildFingerprint(element("#rail"));
    document.body.innerHTML = `
      <div id="page">
        <header id="masthead" class="site-head"><h1>Cormorant Publishing</h1></header>
        <aside id="secondary" class="promo panel" role="banner" data-view-name="promo-unit">
          <p>Godwits, dunlin and knot arrive together when the tide turns on flats.</p>
        </aside>
      </div>`;

    expect(resolveFingerprint(document, print)).toBeUndefined();
  });

  it("cannot be talked into an answer by position and shape alone", () => {
    // Same tag, same place, same size, same number of children, same text band —
    // and none of the names. Every positional signal there is comes to 0.30 of the
    // total, against a threshold of 0.62.
    const print = buildFingerprint(element("#rail"));
    document.body.innerHTML = `
      <div id="page">
        <header id="masthead" class="site-head"><h1>Cormorant Publishing</h1></header>
        <main id="content" class="prose"><p>Bitterns boom across the reedbed.</p></main>
        <aside>
          <p>Godwits, dunlin and knot arrive together when the tide turns on flats.</p>
        </aside>
      </div>`;

    const impostor = element("#page > aside");
    expect(scoreFingerprint(impostor, print)).toBeLessThan(0.62);
    expect(resolveFingerprint(document, print)).toBeUndefined();
  });

  it("declines when the region never had anything identifying about it", () => {
    document.body.innerHTML = `<div id="page"><div><p>Whimbrel passed over the house.</p></div></div>`;
    const print = buildFingerprint(element("#page > div"));

    // A bare wrapper on an unchanged page, and still no answer: there is nothing
    // here that would distinguish it from the next bare wrapper after a redesign,
    // so an answer now is a promise this could not keep later.
    expect(print.classes).toEqual([]);
    expect(resolveFingerprint(document, print)).toBeUndefined();
  });

  it("declines between two siblings it cannot tell apart", () => {
    // The adversarial case that matters most: a feed of identical cards. Answering
    // "the first one" is exactly the silent wrong-element failure this exists to
    // stop, so the margin rule answers nothing instead.
    document.body.innerHTML = `
      <div id="feed">
        <div class="card" data-testid="cellInnerDiv"><p>Avocets swept the scrape for invertebrates.</p></div>
        <div class="card" data-testid="cellInnerDiv"><p>Lapwings tumbled over the wet grassland.</p></div>
        <div class="card" data-testid="cellInnerDiv"><p>Redshanks piped from the fence posts.</p></div>
      </div>`;
    const print = buildFingerprint(element("#feed > div:nth-of-type(2)"));

    expect(resolveFingerprint(document, print)).toBeUndefined();
  });

  it("tells apart siblings by the names the site gave them", () => {
    // Names, and only names. Two columns that differ solely in the *value* of a
    // `data-testid` are indistinguishable here on purpose — a fingerprint stores
    // attribute names, never values, so that it can travel inside a lens without
    // carrying anything off the page. A role is different: it comes from a closed
    // W3C vocabulary, so it is safe to keep and it is real evidence.
    document.body.innerHTML = `
      <div id="page">
        <div class="col" role="main" data-testid="primaryColumn"><p>Avocets swept the scrape.</p></div>
        <div class="col" role="complementary" data-testid="sidebarColumn"><p>Lapwings tumbled over the grass.</p></div>
      </div>`;
    const print = buildFingerprint(element('[role="complementary"]'));
    document.body.innerHTML = `
      <div id="page">
        <div class="lane" role="main" data-testid="primaryColumn"><p>Avocets swept the scrape.</p></div>
        <div class="lane" role="complementary" data-testid="sidebarColumn"><p>Lapwings tumbled over the grass.</p></div>
      </div>`;

    expect(resolveFingerprint(document, print)).toBe(element('[role="complementary"]'));
  });

  it("does not follow a region into a different tag", () => {
    const print = buildFingerprint(element("#rail"));
    const replacement = document.createElement("div");
    replacement.id = "rail";
    replacement.className = "rail sidebar";
    replacement.setAttribute("role", "complementary");
    replacement.setAttribute("data-testid", "sidebarColumn");
    replacement.innerHTML = "<p>Godwits, dunlin and knot arrive together on the flats.</p>";
    element("#rail").replaceWith(replacement);

    // A `<div>` where an `<aside>` was is a rewrite of that part of the page, and
    // the honest answer is that the region we were pointed at is gone.
    expect(resolveFingerprint(document, print)).toBeUndefined();
  });

  it("survives a wrapper added above the region", () => {
    // The ancestor chain is stored nearest-first and scored as a prefix, so a shell
    // `<div>` added at the top of the page shifts the far end of the chain and
    // leaves the near end — the part that says what this region sits inside — alone.
    const print = buildFingerprint(element("#rail"));
    const shell = document.createElement("div");
    shell.className = "app-shell";
    const page = element("#page");
    page.parentElement?.insertBefore(shell, page);
    shell.appendChild(page);

    expect(resolveFingerprint(document, print)).toBe(element("#rail"));
  });

  it("survives a region that grew, because lengths are bands", () => {
    const print = buildFingerprint(element("#content"));
    const extra = document.createElement("p");
    extra.textContent = "Snipe drummed at dusk, which the recorder finally caught on tape.";
    element("#content").appendChild(extra);

    expect(resolveFingerprint(document, print)).toBe(element("#content"));
  });

  it("reads a fingerprint written by a schema that knew less", () => {
    // Lenses are stored on disk and outlive the code that wrote them. A print with
    // empty lists must not be scored as if every list matched — which is exactly
    // the shape that would resolve to whatever came first.
    const sparse: RegionFingerprint = {
      tag: "aside",
      classes: [],
      attributeNames: [],
      childCount: 1,
      textLengthBand: 6,
      rectBand: { x: 0, y: 0, width: 0, height: 0 },
      siblingIndex: 0,
      ancestorTags: [],
    };

    expect(resolveFingerprint(document, sparse)).toBeUndefined();
  });
});
