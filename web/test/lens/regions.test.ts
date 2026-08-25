import { beforeEach, describe, expect, it } from "vitest";

import { buildRegionCatalog } from "../../src/lens/regions.js";
import type { RegionCandidate, RegionCatalog } from "../../src/wire.js";

// Segmentation is what makes a page addressable, and the catalog is the one
// artefact of a page read that a lens sends to a model. So these tests are about
// three properties:
//
//  1. **The parts a user would point at come back named.** A sidebar the model
//     cannot see is a sidebar the user cannot hide.
//  2. **A selector that ships addresses exactly one thing.** Everything below
//     called `-- measured --` is a fixture shaped like the markup of a real site
//     the derivation was run against, and each one is a defect it exhibited.
//  3. **No page characters are in it, anywhere.** The last tests in this file are
//     the same contract `PrivacyContractTests` asserts from Swift, checked here
//     because the field that leaks would be added on this side.

// Text is deliberately made of words that appear nowhere in a class, id or tag,
// so the privacy assertion cannot pass by accident.
const PAGE = `
  <header id="masthead"><h1>Cormorant Publishing Incorporated</h1></header>
  <nav id="primary">
    <a href="/one">Peregrine</a><a href="/two">Kestrel</a><a href="/three">Merlin</a>
    <a href="/four">Goshawk</a><a href="/five">Harrier</a><a href="/six">Buzzard</a>
  </nav>
  <main id="content">
    <article class="post entry">
      <h2>Osprey nesting in the estuary</h2>
      <p>Bitterns boom across the reedbed every spring, and the wardens count them.</p>
      <p>Curlews return in numbers nobody expected after the saltmarsh was restored.</p>
    </article>
  </main>
  <aside class="rail sidebar">
    <p>Godwits, dunlin and knot arrive together when the tide turns on the mudflats.</p>
  </aside>
  <div id="comments" class="comment-list">
    <p>Sanderlings chase the surf line, which is the funniest thing on the beach.</p>
  </div>
  <div class="timeline">
    <article class="card"><p>Avocets swept the scrape for invertebrates all morning.</p></article>
    <article class="card"><p>Lapwings tumbled over the wet grassland in display flight.</p></article>
    <article class="card"><p>Redshanks piped continuously from the fence posts nearby.</p></article>
    <article class="card"><p>Snipe drummed at dusk, which the recorder finally caught.</p></article>
  </div>
  <footer id="colophon"><p>Wheatears leave before the equinox, every single year.</p></footer>
`;

/** Distinctive words from the page body. None of them is a tag, class or id. */
const PAGE_WORDS = [
  "Cormorant",
  "Peregrine",
  "Osprey",
  "Bitterns",
  "Godwits",
  "Sanderlings",
  "Avocets",
  "Wheatears",
];

function find(catalog: RegionCatalog, selector: string): RegionCandidate | undefined {
  return catalog.candidates.find(
    (candidate) => candidate.selector === selector || candidate.alternates.includes(selector),
  );
}

function offers(catalog: RegionCatalog, selector: string): boolean {
  return find(catalog, selector) !== undefined;
}

function build(limit = 120): RegionCatalog {
  return buildRegionCatalog(document, { url: "https://example.com/birds/2026", limit });
}

/** Counts the document queries one build makes. The whole E1 fix is about how
 * many of these run before the limit is applied, so it is asserted rather than
 * described. */
function countQueries(run: () => void): number {
  const prototypes = [Document.prototype, Element.prototype];
  const originals = prototypes.map((prototype) => prototype.querySelectorAll);
  let calls = 0;
  prototypes.forEach((prototype, index) => {
    prototype.querySelectorAll = function counted(this: ParentNode, selector: string) {
      calls += 1;
      return (originals[index] as typeof prototype.querySelectorAll).call(this, selector);
    } as typeof prototype.querySelectorAll;
  });
  try {
    run();
    return calls;
  } finally {
    prototypes.forEach((prototype, index) => {
      prototype.querySelectorAll = originals[index] as typeof prototype.querySelectorAll;
    });
  }
}

describe("buildRegionCatalog", () => {
  beforeEach(() => {
    document.body.innerHTML = PAGE;
  });

  it("names the origin by host and generalises the path", () => {
    const catalog = build();

    // Host, not origin: a site that redirects http to https is one site to the
    // user and one host to their lens.
    expect(catalog.origin).toBe("example.com");
    // `/birds/2026` — the year is volatile, so it generalises, using the same
    // function the skeleton uses so a lens and a recipe agree on scope.
    expect(catalog.pathPattern).toBe("/birds/*");
  });

  it("prefers a stable id, then a distinctive class combination, then the path", () => {
    const catalog = build();

    const header = find(catalog, "#masthead");
    expect(header?.selector).toBe("#masthead");
    // The structural path is always last, and always present: it is the anchor
    // that cannot fail to match, and the first to break on a redesign.
    expect(header?.alternates.at(-1)).toMatch(/^body>/);

    const rail = find(catalog, "aside.rail.sidebar");
    expect(rail?.selector).toBe("aside.rail.sidebar");
    expect(rail?.alternates).toContain("aside");
  });

  it("guesses the kind of each landmark", () => {
    const catalog = build();

    expect(find(catalog, "#masthead")?.kindGuess).toBe("header");
    expect(find(catalog, "#primary")?.kindGuess).toBe("nav");
    expect(find(catalog, "#content")?.kindGuess).toBe("main");
    expect(find(catalog, "aside.rail.sidebar")?.kindGuess).toBe("aside");
    expect(find(catalog, "#colophon")?.kindGuess).toBe("footer");
  });

  it("calls a comment thread comments, not main, wherever it sits", () => {
    // Comments are usually inside <main>, and naming them "main" would make
    // "hide the comments" point at the article.
    expect(find(build(), "#comments")?.kindGuess).toBe("comments");
  });

  it("detects a repeated-sibling run, which is the feed signal", () => {
    const feed = find(build(), "div.timeline");

    expect(feed?.kindGuess).toBe("feed");
    expect(feed?.itemCount).toBe(4);
    // `:scope >` so filtering a timeline does not also filter the quoted posts
    // nested inside its cards.
    expect(feed?.itemSelector).toBe(":scope > article.card");
  });

  it("does not call three unrelated children a feed", () => {
    document.body.innerHTML = `
      <div class="mixed">
        <h2>Marshland report</h2>
        <p>Shovelers dabbled in the shallows for most of the afternoon session.</p>
        <form><input name="q"></form>
      </div>`;

    const candidate = build().candidates.find((entry) => entry.tag === "div");

    expect(candidate?.itemCount).toBe(0);
    expect(candidate?.itemSelector).toBeUndefined();
  });

  it("counts links and paragraphs, which is how shape is judged without layout", () => {
    // Geometry is all zeros in jsdom, so every heuristic that matters has to work
    // from structure alone — the same situation as a page that has not laid out.
    const nav = find(build(), "#primary");

    expect(nav?.linkCount).toBe(6);
    expect(find(build(), "#content")?.paragraphCount).toBe(2);
  });

  it("measures text the way `textContent.trim()` does, from one bottom-up pass", () => {
    // The counts come from a single sweep rather than a query per element per
    // counter, and the sweep has to agree with the thing it replaced — including
    // about whitespace, which is why it tracks each run's edges.
    const catalog = build();

    for (const candidate of catalog.candidates) {
      const element = document.querySelector(candidate.selector);
      expect(element).not.toBeNull();
      expect(candidate.textLength).toBe((element?.textContent ?? "").trim().length);
      expect(candidate.linkCount).toBe(element?.querySelectorAll("a[href]").length);
      expect(candidate.imageCount).toBe(element?.querySelectorAll("img,picture,figure").length);
    }
  });

  it("honours the candidate limit", () => {
    expect(build(3).candidates).toHaveLength(3);
    // Ids are assigned after ranking, so they are always dense and ordered.
    expect(build(3).candidates.map((candidate) => candidate.id)).toEqual(["r0", "r1", "r2"]);
  });

  it("never offers our own nodes as regions", () => {
    const label = document.createElement("zentic-lens-label");
    label.textContent = "Kittiwakes";
    document.body.appendChild(label);

    const tags = build().candidates.map((candidate) => candidate.tag);

    expect(tags).not.toContain("zentic-lens-label");
  });

  it("carries no page text — the whole reason a catalog may leave the device", () => {
    const encoded = JSON.stringify(build());

    for (const word of PAGE_WORDS) {
      expect(encoded).not.toContain(word);
    }

    // And it is not empty of *lengths*: the model needs to know a region is
    // text-dense without being told what the text says.
    const main = find(build(), "#content");
    expect(main?.textLength).toBeGreaterThan(100);
  });
});

// -- measured -- NYT: `div.jXhsNG_gridCell.jXhsNG_positioned` was offered as the
// preferred anchor for ONE outlined box while matching 160 of them, because
// `found[0] === element` is true for whichever one happens to be first.
describe("a selector is only offered if it matches one element", () => {
  const GRID = Array.from(
    { length: 8 },
    (_, index) =>
      `<div class="gridCell positioned"><p>Turnstones worked along the strandline for cell ${index}.</p></div>`,
  ).join("");

  beforeEach(() => {
    document.body.innerHTML = `<div class="gridContainer">${GRID}</div>`;
  });

  it("does not offer a class selector shared by every cell in the grid", () => {
    const catalog = build();

    expect(offers(catalog, "div.gridCell.positioned")).toBe(false);
    expect(offers(catalog, "div.gridCell")).toBe(false);
  });

  it("falls back to the path, which addresses the one box that was pointed at", () => {
    const catalog = build();
    const cell = catalog.candidates.find((candidate) =>
      candidate.classes.includes("gridCell"),
    );

    expect(cell?.selector).toMatch(/^body>/);
    expect(document.querySelectorAll(cell?.selector ?? "*")).toHaveLength(1);
  });

  it("still offers the container, which is genuinely one element", () => {
    expect(find(build(), "div.gridContainer")?.itemCount).toBe(8);
  });
});

describe("selector tiers, in the order they survive a redesign", () => {
  it("prefers a custom-element tag over the utility classes on it", () => {
    // -- measured -- Reddit: `shreddit-post` resolves and was never offered,
    // because a bare tag was pushed only for landmarks. The name is passed to the
    // site's own `customElements.define()`, so it outlives every class on it.
    document.body.innerHTML = `
      <shreddit-post class="block relative cursor-pointer">
        <p>Ptarmigan turn white before the first snow, which is the whole trick.</p>
      </shreddit-post>`;

    const candidate = build().candidates.find((entry) => entry.tag === "shreddit-post");

    expect(candidate?.selector).toBe("shreddit-post");
    expect(candidate?.alternates).toContain("shreddit-post.block.relative");
  });

  it("does not offer a custom-element tag that names every item in a feed", () => {
    document.body.innerHTML = `
      <shreddit-feed>
        <shreddit-post class="block"><p>Dotterel flocks stop over on the tops in April.</p></shreddit-post>
        <shreddit-post class="block"><p>Twite feed on the saltmarsh seed through the winter.</p></shreddit-post>
        <shreddit-post class="block"><p>Choughs prospect the cliff caves from February onward.</p></shreddit-post>
      </shreddit-feed>`;

    const catalog = build();

    // One `shreddit-feed`, so the tag names it. Three posts, so it names none.
    expect(find(catalog, "shreddit-feed")?.selector).toBe("shreddit-feed");
    expect(offers(catalog, "shreddit-post")).toBe(false);
  });

  it("prefers a test-suite attribute over a class", () => {
    // -- measured -- X's timeline is addressed almost entirely by `data-testid`
    // and has no usable class at all.
    document.body.innerHTML = `
      <div data-testid="primaryColumn" class="timeline-column">
        <p>Firecrests were ringed in the churchyard yews on three mornings.</p>
      </div>`;

    const candidate = build().candidates.find((entry) => entry.tag === "div");

    expect(candidate?.selector).toBe('div[data-testid="primaryColumn"]');
    expect(candidate?.alternates).toContain("div.timeline-column");
  });

  it("prefers a role over a class, which is where Facebook's feed was hiding", () => {
    // -- measured -- `div[role="feed"]` was already derived and ranked fourth,
    // behind atomic classes that match a thousand elements and therefore never
    // stop matching.
    document.body.innerHTML = `
      <div role="feed" class="feedwrap">
        <article class="story"><p>Nightjars churred from the clearfell until it was fully dark.</p></article>
        <article class="story"><p>Woodcock roded over the same ride at exactly the same time.</p></article>
        <article class="story"><p>Tawny owls answered each other across the valley all night.</p></article>
      </div>`;

    const candidate = build().candidates.find((entry) => entry.role === "feed");

    expect(candidate?.selector).toBe('div[role="feed"]');
    expect(candidate?.alternates).toContain("div.feedwrap");
  });

  it("uses an aria-label to name a landmark, and never to name a card", () => {
    // `aria-label` is localised, so it is the weakest attribute in the tier — and
    // it is the one whose value can be page content. On a landmark it is the site's
    // name for the region; on a card it is the headline, and invariant 4 has no
    // exception for text that arrived in an attribute.
    document.body.innerHTML = `
      <nav aria-label="Section navigation">
        <a href="/a">Pintail</a><a href="/b">Wigeon</a><a href="/c">Gadwall</a>
      </nav>
      <article aria-label="Osprey nesting in the estuary" class="card">
        <p>Bitterns boom across the reedbed every spring, and the wardens count.</p>
      </article>`;

    const catalog = build();

    expect(find(catalog, 'nav[aria-label="Section navigation"]')).toBeDefined();
    expect(JSON.stringify(catalog)).not.toContain("Osprey");
  });
});

// -- measured -- Four of the five generated-class formats in the wild passed the
// filter whose doc comment said it dropped them.
describe("generated class names", () => {
  const cases: Array<[string, string, string]> = [
    ["X/Emotion", "css-175oi2r", "sidebar"],
    ["GitHub/PRC", "prc-PageLayout-Content-xWL-A", "sidebar"],
    ["NYT/Emotion", "eu3y8st0", "sidebar"],
    ["Substack/CSS modules", "container-k4OAt1", "sidebar"],
    ["Meta/atomic", "x1i10hfl", "sidebar"],
  ];

  for (const [site, generated, handwritten] of cases) {
    it(`drops ${site}'s ${generated}`, () => {
      document.body.innerHTML = `
        <section class="${generated} ${handwritten}">
          <p>Ringed plovers nested on the shingle again, which surprised everyone.</p>
        </section>`;

      const candidate = build().candidates.find((entry) => entry.tag === "section");

      expect(candidate?.classes).toEqual([handwritten]);
      expect(candidate?.selector).toBe(`section.${handwritten}`);
    });
  }

  it("keeps the names a person types, including a trailing counter", () => {
    document.body.innerHTML = `
      <section class="site-header heading2 col-md-6 CTA PageLayout">
        <p>Wrynecks turn up on the coast in autumn and never stay for long.</p>
      </section>`;

    expect(build().candidates.find((entry) => entry.tag === "section")?.classes).toEqual([
      "site-header",
      "heading2",
      "col-md-6",
      "CTA",
      "PageLayout",
    ]);
  });
});

// -- measured -- `stableIdentifier` had no generated-name test at all, so the
// worst available selector was ranked first.
describe("an id has to name a region, not one row of a feed", () => {
  it("refuses Reddit's per-post id", () => {
    document.body.innerHTML = `
      <shreddit-feed>
        <shreddit-post id="t3_1vx81cr"><p>Dotterel flocks stop over on the tops in April.</p></shreddit-post>
        <shreddit-post id="t3_1vx91dm"><p>Twite feed on the saltmarsh seed through winter.</p></shreddit-post>
        <shreddit-post id="t3_1vxa2fn"><p>Choughs prospect the cliff caves from February on.</p></shreddit-post>
      </shreddit-feed>`;

    const catalog = build();
    const post = catalog.candidates.find((entry) => entry.tag === "shreddit-post");

    expect(post?.selector).not.toBe("#t3_1vx81cr");
    expect(post?.elementID).toBeUndefined();
    expect(JSON.stringify(catalog)).not.toContain("t3_1vx81cr");
  });

  it("refuses Wikipedia's Parsoid ids, which change on every re-render", () => {
    document.body.innerHTML = `
      <section id="content-body">
        <p id="mwDLo">Hen harriers quartered the moor edge for most of the afternoon.</p>
        <p id="mwAQ">Merlins hunted the same pipits along the same wall every day.</p>
        <p id="mwBg">Ring ouzels held two territories in the gully above the road.</p>
      </section>`;

    const catalog = build();

    expect(offers(catalog, "#mwDLo")).toBe(false);
    // The section around them is a perfectly good region and keeps its id.
    expect(find(catalog, "#content-body")?.selector).toBe("#content-body");
  });

  it("refuses a per-item id even when a person wrote it", () => {
    document.body.innerHTML = `
      <ol class="thread">
        <li id="comment-11"><p>Stone curlews returned to the same field for a ninth year.</p></li>
        <li id="comment-12"><p>Little owls used the barn gable again after a summer away.</p></li>
        <li id="comment-13"><p>Barn owls hunted the verges every evening through the frost.</p></li>
      </ol>`;

    const catalog = build();

    expect(offers(catalog, "#comment-11")).toBe(false);
    expect(find(catalog, "ol.thread")).toBeDefined();
  });

  it("keeps sibling ids that name parts rather than rows", () => {
    // The counter-case, and the reason the rule needs three conditions rather than
    // one: three sibling `div`s with ids is a 2004 layout, not a feed.
    document.body.innerHTML = `
      <div class="page">
        <div id="site-header"><p>Sand martins were back at the pit face by the third week.</p></div>
        <div id="site-main"><p>Swifts screamed over the terrace from the middle of May.</p></div>
        <div id="site-footer"><p>House martins held on to two nests under the eaves.</p></div>
      </div>`;

    const catalog = build();

    expect(find(catalog, "#site-header")?.selector).toBe("#site-header");
    expect(find(catalog, "#site-main")?.selector).toBe("#site-main");
  });
});

// -- measured -- GitHub: fifteen consecutive `div`s, every one with textLength
// 5896 and an eighteen-segment path, spending 40-65% of the candidate budget on
// fifteen ways to name one box.
describe("a tower of single-child wrappers", () => {
  beforeEach(() => {
    let html = `
      <article class="repo-content">
        <h2>Fieldfare arrivals</h2>
        <p>Fieldfares stripped the hedge in a morning, then moved on to the orchard.</p>
        <p>Redwings followed them a week later and stayed until the ground froze.</p>
      </article>`;
    for (let rung = 14; rung >= 0; rung -= 1) {
      html = `<div class="rung rung-${rung}">${html}</div>`;
    }
    document.body.innerHTML = html;
  });

  it("contributes exactly one candidate", () => {
    const rungs = build().candidates.filter((candidate) => candidate.classes.includes("rung"));

    expect(rungs).toHaveLength(1);
    // The outermost, which is the biggest box and the one a click lands on.
    expect(rungs[0]?.classes).toContain("rung-0");
  });

  it("still offers what the tower is wrapped around", () => {
    expect(find(build(), "article.repo-content")).toBeDefined();
  });

  it("keeps a landmark that happens to have one child", () => {
    document.body.innerHTML = `
      <main id="content"><div class="inner"><div class="pad">
        <p>Waxwings found the supermarket rowans within a day of arriving in town.</p>
      </div></div></main>`;

    const catalog = build();

    expect(find(catalog, "#content")).toBeDefined();
    expect(catalog.candidates.filter((entry) => entry.tag === "div")).toHaveLength(1);
  });
});

// -- measured -- Hacker News: one logical story is three sibling `<tr>`s, so the
// run offered was `:scope > tr` at 92 against `tr.athing` at 30. A filter over the
// 92 hides the title row and orphans the score row, and reports `applied, 92`.
describe("a repeated run that is rows of something bigger", () => {
  beforeEach(() => {
    const stories = Array.from(
      { length: 30 },
      (_, index) => `
        <tr class="athing"><td><a href="/s/${index}">Corncrakes counted by call on the machair</a></td></tr>
        <tr><td class="subtext">${index * 3} points by a reader</td></tr>
        <tr class="spacer"><td></td></tr>`,
    ).join("");
    document.body.innerHTML = `
      <table class="itemlist"><tbody>
        ${stories}
        <tr class="morespace"><td></td></tr>
        <tr><td><a href="/more">More</a></td></tr>
      </tbody></table>`;
  });

  it("declines rather than offering rows as if they were items", () => {
    const tbody = build().candidates.find((candidate) => candidate.tag === "tbody");

    expect(tbody).toBeDefined();
    expect(tbody?.itemCount).toBe(0);
    expect(tbody?.itemSelector).toBeUndefined();
    expect(tbody?.kindGuess).not.toBe("feed");
  });

  it("still reports a run where the extra rows are peers, not parts", () => {
    // The ad-card case: one ad every fifth slot is still one row per item, so the
    // bare tag covers both kinds and is offered.
    document.body.innerHTML = `
      <div class="timeline">
        <article class="card"><p>Avocets swept the scrape for invertebrates all morning.</p></article>
        <article class="card"><p>Lapwings tumbled over the wet grassland in display flight.</p></article>
        <article class="card"><p>Redshanks piped continuously from the fence posts nearby.</p></article>
        <article class="card"><p>Snipe drummed at dusk, which the recorder finally caught.</p></article>
        <article class="promoted"><p>Something a marketing department paid to put here.</p></article>
      </div>`;

    const feed = find(build(), "div.timeline");

    expect(feed?.itemCount).toBe(5);
    expect(feed?.itemSelector).toBe(":scope > article");
  });
});

// H1 — the only reason `harvest` was unauthorable on 0 of 14 real sites.
describe("item fields", () => {
  beforeEach(() => {
    const cards = Array.from(
      { length: 4 },
      (_, index) => `
        <article class="card">
          <h3 class="title"><a href="/story/${index}">Osprey nesting in the estuary</a></h3>
          <p class="dek">Bitterns boom across the reedbed every spring, all told.</p>
          <img src="/thumb/${index}.jpg" alt="Avocets on the scrape">
          <span class="byline">Cormorant Publishing</span>
        </article>`,
    ).join("");
    document.body.innerHTML = `<div class="feed">${cards}</div>`;
  });

  it("names what is inside one item, so a harvest field can be written down", () => {
    const feed = find(build(), "div.feed");
    const selectors = feed?.itemFields.map((field) => field.selector) ?? [];

    expect(selectors).toContain("h3.title");
    expect(selectors).toContain("a[href]");
    expect(selectors).toContain("p.dek");
    expect(selectors).toContain("span.byline");
  });

  it("names the attributes a harvest may read, and nothing else", () => {
    const feed = find(build(), "div.feed");
    const image = feed?.itemFields.find((field) => field.tag === "img");

    expect(image?.attributesPresent).toEqual(["src", "alt"]);
    for (const field of feed?.itemFields ?? []) {
      for (const name of field.attributesPresent) {
        expect(["href", "src", "alt", "title"]).toContain(name);
      }
    }
  });

  it("ships selectors that resolve where `readField` will look", () => {
    const feed = find(build(), "div.feed");
    const item = document.querySelector(".feed .card") as Element;

    for (const field of feed?.itemFields ?? []) {
      const found = item.querySelector(field.selector);
      expect(found).not.toBeNull();
      expect(found?.localName).toBe(field.tag);
    }
  });

  it("skips a wrapper, which would harvest an empty string", () => {
    document.body.innerHTML = `
      <div class="feed">
        <article class="card"><div class="pad"><h3 class="title">Curlews return in numbers</h3></div></article>
        <article class="card"><div class="pad"><h3 class="title">Godwits arrive with the tide</h3></div></article>
        <article class="card"><div class="pad"><h3 class="title">Snipe drum at dusk again</h3></div></article>
      </div>`;

    const fields = find(build(), "div.feed")?.itemFields ?? [];

    expect(fields.map((field) => field.tag)).toEqual(["h3"]);
  });

  it("is empty for a region that is not a feed", () => {
    document.body.innerHTML = `
      <section class="prose">
        <p>Whimbrel passed over the house on the same date for four years running.</p>
      </section>`;

    expect(find(build(), "section.prose")?.itemFields).toEqual([]);
  });

  it("carries lengths, never characters", () => {
    const catalog = build();
    const encoded = JSON.stringify(catalog.candidates.map((entry) => entry.itemFields));

    for (const word of ["Osprey", "Bitterns", "Avocets", "Cormorant"]) {
      expect(encoded).not.toContain(word);
    }

    const title = find(catalog, "div.feed")?.itemFields.find(
      (field) => field.selector === "h3.title",
    );
    expect(title?.textLength).toBe("Osprey nesting in the estuary".length);
  });
});

// E1 — the catalog was superlinear and applied the limit after all the work:
// 8.2x the DOM gave 9.2x the queries but 88x the matched elements.
describe("the cost of a catalog", () => {
  beforeEach(() => {
    const cards = Array.from(
      { length: 60 },
      (_, index) => `
        <article class="card" id="post-${index}">
          <div class="wrap"><div class="inner">
            <h3 class="title"><a href="/s/${index}">Turnstones worked along the strandline</a></h3>
            <p class="dek">Sanderlings chased the surf line for the whole of the morning.</p>
            <img src="/t/${index}.jpg" alt="thumb">
          </div></div>
        </article>`,
    ).join("");
    document.body.innerHTML = `<main id="content"><div class="feed" role="feed">${cards}</div></main>`;
  });

  it("pays for the candidates it offers, not for the document", () => {
    // Roughly 500 elements qualify here. The version this replaces asked the
    // document four counting questions and up to five selector questions per
    // element *before* ranking, so this was thousands of queries deep.
    const queries = countQueries(() => build(20));

    expect(queries).toBeLessThan(60);
  });

  it("costs the same to catalog 20 regions of a big page as of a small one", () => {
    const big = countQueries(() => build(20));
    document.body.innerHTML = `<main id="content"><div class="feed" role="feed">
      <article class="card"><p>Turnstones worked along the strandline all morning long.</p></article>
      <article class="card"><p>Sanderlings chased the surf line for the whole morning.</p></article>
      <article class="card"><p>Dunlin roosted on the spit until the tide pushed them off.</p></article>
    </div></main>`;
    const small = countQueries(() => build(20));

    // Not "fewer than before" — *bounded by the limit*, which is the property that
    // makes ⌥⌘L cost the same on a YouTube home feed as on an article.
    expect(big).toBeLessThanOrEqual(small * 2);
  });
});
