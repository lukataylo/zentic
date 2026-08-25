import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { buildFingerprint } from "../../src/lens/fingerprint.js";
import { HarvestStore } from "../../src/lens/harvest.js";
import {
  DEFAULT_OP_BUDGET,
  LensJournal,
  compilePass,
  runStructuralOps,
  type OpBudget,
} from "../../src/lens/ops.js";
import type {
  ItemPredicate,
  Lens,
  LensOp,
  LensOpKind,
  LensOpResult,
  LensOpStatus,
  LensReport,
  RegionFingerprint,
} from "../../src/wire.js";

// The op runner has three promises, and each one is a test here.
//
//  1. **Every op reports the truth.** `applied`, `missed`, `ambiguous`, `skipped`
//     and `failed` all have to be producible and accurate, because the toolbar
//     badge and the whole drift story are built on nothing else.
//  2. **Ops fail independently.** One stale selector no-ops; the other nine still
//     apply and the page is still a page.
//  3. **It is reversible.** Applying and then clearing returns the DOM to exactly
//     what was found — asserted on the serialised markup, not on a spot check.

const PAGE = `
  <header id="masthead"><h1>Masthead</h1></header>
  <main id="content">
    <article class="post"><p>Body text of the article, long enough to matter.</p></article>
  </main>
  <aside id="related" class="rail"><p>Suggested for you</p></aside>
  <div class="dupe">one</div>
  <div class="dupe">two</div>
  <ul id="feed">
    <li class="item">Sponsored: buy this thing now</li>
    <li class="item">A short one</li>
    <li class="item">Ordinary post about a longer subject entirely</li>
  </ul>
  <div id="tray"></div>
`;

let opCounter = 0;

function op(kind: LensOp["kind"], region: string, extra: Partial<LensOp> = {}): LensOp {
  return { id: `op${++opCounter}`, kind, region, note: `${kind} ${region}`, ...extra };
}

function lens(ops: LensOp[], overrides: Partial<Lens> = {}): Lens {
  return {
    id: "lens-1",
    name: "Focus",
    origin: "example.com",
    pathPattern: "*",
    isEnabled: true,
    prompt: "",
    regions: [
      { id: "header", intent: "the masthead", selectors: ["#masthead"] },
      { id: "main", intent: "the article", selectors: ["#content"] },
      { id: "related", intent: "the suggestions rail", selectors: ["#related", "aside.rail"] },
      { id: "feed", intent: "the list of posts", selectors: ["#feed"] },
      { id: "tray", intent: "the tray at the bottom", selectors: ["#tray"] },
      { id: "dupe", intent: "the repeated boxes", selectors: ["div.dupe"] },
      { id: "gone", intent: "a box that no longer exists", selectors: ["#gone", ".gone-too"] },
    ],
    ops,
    createdAt: "2026-01-01T00:00:00Z",
    updatedAt: "2026-01-01T00:00:00Z",
    schemaVersion: 1,
    ...overrides,
  };
}

interface RunOutcome {
  reports: LensReport[];
  journal: LensJournal;
  results: LensOpResult[];
}

function run(lenses: Lens[], budget: OpBudget = DEFAULT_OP_BUDGET, now?: () => number): RunOutcome {
  const journal = new LensJournal(document);
  const reports = runStructuralOps(document, lenses, {
    budget,
    journal,
    harvests: new HarvestStore(),
    ...(now ? { now } : {}),
  });
  return { reports, journal, results: reports.flatMap((report) => report.results) };
}

/**
 * The sheet one compile produces.
 *
 * The document is explicit and has no default, because there are three of them
 * that matter and the difference between two of them used to be invisible: the
 * page (`document`), somebody else's page (a second `Document`), and *no page at
 * all*, which is what the engine hands the compile at `document-start` and is
 * not the same thing as a document with an empty body.
 */
function sheet(lenses: Lens[], doc: Document | undefined): string {
  return compilePass(lenses, DEFAULT_OP_BUDGET, doc).css;
}

/** The one rule a `hide` produced, without the preamble. */
function hideSelector(css: string): string | undefined {
  return css
    .split("\n")
    .filter((rule) => rule.endsWith("{display:none!important}") && !rule.startsWith("["))
    .map((rule) => rule.slice(0, rule.indexOf("{")))[0];
}

describe("the compile", () => {
  beforeEach(() => {
    // Empty by default: the compile that matters most runs at `document-start`,
    // when the page's own markup has not parsed. Tests that need a page say so.
    document.body.innerHTML = "";
  });

  it("commits to one candidate at document-start, when nothing can be resolved", () => {
    // Before the page parses, no candidate resolves and the alternates are
    // guesses. Under-hiding for a few milliseconds is a flash; over-hiding is a
    // page with its content missing, so the preferred anchor goes in alone and
    // `runPass` recompiles against the real DOM.
    const css = sheet([lens([op("hide", "related")])], document);

    expect(css).toContain("#related{display:none!important}");
    expect(css).not.toContain("aside.rail");
  });

  it("writes one selector into a rule, never a union of the candidates", () => {
    // The union was a provable no-op. It fired only when every candidate matched
    // exactly one element *and* it was the same element — and `a,b,c` then
    // selects precisely what `a` selects, so it could neither widen a rule nor
    // narrow one. It cost a scan of every candidate on every compile to arrive
    // back where it started, and it left the sheet naming selectors the report
    // did not, which is the small dishonesty the whole file is written against.
    document.body.innerHTML = PAGE;

    const css = sheet([lens([op("hide", "related")])], document);

    expect(hideSelector(css)).toBe("#related");
    expect(css).not.toContain("aside.rail");
  });

  it("writes the rule against the first candidate that resolves", () => {
    // Drift, from the sheet's side: the preferred anchor is gone, so the rule has
    // to be written against the alternate that is still there — and against that
    // one alone, since a rail that is only reachable by `aside.rail` is a rail
    // whose siblings share the class.
    document.body.innerHTML = `
      <aside id="related" class="rail"><p>Suggested for you</p></aside>
      <aside class="rail"><p>A different rail, which the user never pointed at</p></aside>
    `;

    const css = sheet([lens([op("hide", "related")])], document);
    const selector = hideSelector(css);

    expect(selector).toBe("#related");
    expect(document.querySelectorAll(selector!)).toHaveLength(1);
  });

  it("refuses a keep whose subject names more than one box", () => {
    // What the bare-tag ban was standing in for, said generally. `nav` is a
    // fallback anchor `regions.ts` really does ship, and a site with a nav in the
    // header and a nav in the footer makes `:has(> nav)` **two** parents — each of
    // which loses every child but its own nav. Hiding the siblings of one box the
    // user pointed at is what `keep` means; doing it to boxes they never pointed
    // at is a wrecked page from a perfectly legal lens.
    document.body.innerHTML = `
      <header><nav>top</nav><h1>Masthead</h1></header>
      <main id="content">the page</main>
      <footer><nav>bottom</nav><p>small print</p></footer>
    `;

    const css = sheet([
      lens([op("keep", "nav")], {
        regions: [{ id: "nav", intent: "the nav bar", selectors: ["nav"] }],
      }),
    ], document);

    expect(css).not.toContain(":has(> nav)");
    // And this is what it would have done: emptied the header and the footer of
    // everything but their navs, on a lens written about one of them.
    expect(document.querySelectorAll(":has(> nav) > *:not(nav)")).toHaveLength(2);
  });

  it("still keeps against a tag name that resolves to exactly one box", () => {
    // The other side of the same rule, and the reason it is a count rather than a
    // ban on tag names. One `<nav>` on the page is one box the user pointed at,
    // and "keep only this" means hide its siblings.
    document.body.innerHTML = `<nav id="bar">nav</nav><main id="content">the page</main>`;

    const css = sheet([
      lens([op("keep", "nav")], {
        regions: [{ id: "nav", intent: "the nav bar", selectors: ["nav"] }],
      }),
    ], document);

    expect(css).toContain(":has(> nav) > *:not(nav){display:none!important}");
  });

  it("refuses a keep whose parent reaches <html>, however the region is spelled", () => {
    // The case the bare-tag ban provably could not see, and the reason it is gone.
    // `keepRule(":is(body)")` synthesises `:has(> :is(body)) > *:not(:is(body))`,
    // whose parent is the document element — so the "region" being kept is the
    // whole page and the rule's entire effect is to hide `<head>`. No parser of
    // the *argument* catches this: `:is(body)` is a perfectly narrow-looking
    // compound right up until `:has(> …)` is wrapped around it.
    document.body.innerHTML = `<main id="content">the page</main>`;

    const css = sheet([
      lens([op("keep", "everything")], {
        regions: [{ id: "everything", intent: "the page", selectors: [":is(body)"] }],
      }),
    ], document);

    expect(css).not.toContain(":not(:is(body))");
    expect(hideSelector(css)).toBeUndefined();
  });

  it("refuses a region candidate whose match set contains the page", () => {
    // The other half of the same check, and the reason the 233-line subject
    // parser is gone. Each of these is a spelling of "the whole page" that a
    // set-membership test walks straight past — and every one of them compiled to
    // `{display:none!important}` on an element containing everything the site
    // has. `Element.matches()` does not care how they are spelled.
    // A page dressed the way real pages are: a `lang`, a JS-detection class on
    // `<html>`, a theme class on `<body>`. Every one of those is what makes the
    // corresponding spelling below *resolve* to the page.
    document.documentElement.setAttribute("lang", "en");
    document.documentElement.className = "js";
    document.body.className = "dark";
    document.body.innerHTML = `<main id="content"><a class="ad" href="/x">an ad</a></main>`;

    for (const broad of [
      ":is(body)",
      ":where(body)",
      ":is(html)",
      "*:not(.keep)",
      "body.dark",
      "body:not(#nope)",
      "html.js",
      "html[lang]",
      "*:has(.ad)",
      ":not(.keep)",
      ":is(*)",
    ]) {
      const css = sheet([
        lens([op("hide", "related")], {
          regions: [{ id: "related", intent: "x", selectors: [broad] }],
        }),
      ], document);
      expect(hideSelector(css), `${broad} reached the sheet`).toBeUndefined();
    }

    document.documentElement.removeAttribute("lang");
    document.documentElement.className = "";
    document.body.className = "";
  });

  it("caps the candidate selectors one region may carry", () => {
    // A lens with five hundred selectors per region and forty ops walks five
    // hundred `querySelectorAll` calls per region on every compile, and rebuilds
    // them on every SPA navigation. The cap is silent because a truncated list
    // still works: the entries that matter are at the front by construction.
    document.body.innerHTML = `<aside id="ninth">the rail</aside>`;
    const selectors = [
      ...Array.from({ length: 8 }, (_, index) => `#absent-${index}`),
      "#ninth",
    ];

    const css = sheet([
      lens([op("hide", "wide")], {
        regions: [{ id: "wide", intent: "the rail", selectors }],
      }),
    ], document);

    // Nothing in the first eight resolves, so the sheet carries the preferred
    // anchor alone — and never reaches the ninth candidate to find the one that
    // would have worked.
    expect(hideSelector(css)).toBe("#absent-0");
    expect(css).not.toContain("#ninth");
  });

  it("compiles keep to a parent rule, written without knowing the parent", () => {
    // At `document-start`, where the shape of the rule is all there is to judge.
    const css = sheet([lens([op("keep", "main")])], undefined);

    expect(css).toContain(":has(> #content) > *:not(#content){display:none!important}");
  });

  it("compiles keep from a path selector using the parent the path names", () => {
    // `:has(> body>article)` matches <html>, so the rule would hide the page.
    // A path already carries its parent, and that is the one to use.
    const css = sheet(
      [
        lens([op("keep", "main")], {
          regions: [{ id: "main", intent: "the article", selectors: ["body>div>article"] }],
        }),
      ],
      undefined,
    );

    expect(css).toContain("body>div>*:not(article){display:none!important}");
    expect(css).not.toContain(":has(> body>div>article)");
  });

  it("compiles no keep rule at all rather than a guessed one", () => {
    // A descendant combinator names no recoverable parent. Hiding the wrong
    // siblings would leave the user with a page they cannot read.
    const css = sheet([
      lens([op("keep", "main")], {
        regions: [{ id: "main", intent: "the article", selectors: ["main .body"] }],
      }),
    ], document);

    expect(css).not.toContain(":not(");
  });

  it("compiles width to a clamped percentage", () => {
    const css = sheet([lens([op("width", "main", { fraction: 0.5 })])], document);
    expect(css).toContain("max-width:50.0%!important");

    const silly = sheet([lens([op("width", "main", { fraction: 40 })])], document);
    expect(silly).toContain("max-width:100.0%!important");
  });

  it("compiles restyle from tokens, and drops anything that is not a token", () => {
    const css = sheet(
      [
        lens([
          op("restyle", "main", {
            style: {
              background: "#101010",
              // Not `#rrggbb`, so it never reaches the sheet. `url()` in a
              // stylesheet would beacon on every page read — invariant 5.
              foreground: "red; background:url(https://tracker.example/x)",
              fontScale: 9,
              hideImages: true,
            },
          }),
        ]),
      ],
      document,
    );

    expect(css).toContain("background-color:#101010!important");
    expect(css).not.toContain("url(");
    expect(css).not.toContain("tracker");
    expect(css).toContain("font-size:2.00em!important");
    expect(css).toContain("#content img");
  });

  it("refuses a selector that could break out of the rule", () => {
    const hostile = lens([op("hide", "related")], {
      regions: [
        { id: "related", intent: "x", selectors: ["#related{} body {display:none} .x"] },
      ],
    });

    expect(sheet([hostile], document)).not.toContain("body {display:none}");
  });

  it("refuses an unbalanced selector, which would swallow the rest of the sheet", () => {
    // `#secondary:has(` compiles to `#secondary:has( { display:none }`, and per
    // CSS Syntax §5.4.8 the unclosed block consumes every rule after it to the
    // end of the sheet. So one stale op silently disables every later CSS op
    // while the structural pass still reports them `applied` — the badge says the
    // lens fits and the page says otherwise.
    for (const broken of ["#secondary:has(", 'div[a="', "div:not(.a", "#a)", "div[data-x"]) {
      const css = sheet([
        lens([op("hide", "related"), op("hide", "main")], {
          regions: [
            { id: "related", intent: "x", selectors: [broken] },
            { id: "main", intent: "y", selectors: ["#content"] },
          ],
        }),
      ], document);
      expect(css, `${broken} reached the sheet`).not.toContain(broken);
      // The op that follows it still gets its rule, which is the actual promise.
      expect(css).toContain("#content{display:none!important}");
    }
  });

  it("refuses a selector whose subject is the whole page", () => {
    // `hide` on `html` is otherwise a legal lens that blanks every visit.
    for (const broad of ["*", "html", "body", ":root", "body > *"]) {
      const css = sheet([
        lens([op("hide", "related")], {
          regions: [{ id: "related", intent: "x", selectors: [broad] }],
        }),
      ], document);
      expect(css, `${broad} reached the sheet`).not.toContain(`${broad}{display:none`);
    }
  });

  it("keeps escaped utility classes, which is most of the modern web", () => {
    // Banning `\` outright rejected `.md\:flex`, `.w-1\/2` and every other
    // Tailwind class — on exactly the sites people want to lens.
    const css = sheet([
      lens([op("hide", "related")], {
        regions: [{ id: "related", intent: "x", selectors: [".md\\:flex"] }],
      }),
    ], document);

    expect(css).toContain(".md\\:flex{display:none!important}");
  });

  it("carries the runtime rules a structural op depends on", () => {
    // `filter` hides items with an attribute rather than an inline style, so that
    // undo can be exact. The rule that makes the attribute mean anything lives
    // here, and ships even when no lens uses it.
    expect(sheet([], document)).toContain("[data-zentic-lens-hidden]{display:none!important}");
  });

  it("resolves against the document it is handed, not the ambient global", () => {
    // `LensEngine` is constructed with a document and every other thing it does
    // uses it. The compile read `globalThis.document` instead — the same object in
    // a browser tab and a different one anywhere else, so the unit under test
    // stopped being the unit that ships.
    const elsewhere = document.implementation.createHTMLDocument("elsewhere");
    elsewhere.body.innerHTML = `<aside class="rail">links</aside>`;

    // The preferred anchor is absent over there and the alternate resolves, so
    // the sheet can only name the alternate if it looked at the right document.
    const focus = lens([op("hide", "related")]);

    expect(hideSelector(sheet([focus], elsewhere))).toBe(
      "aside.rail",
    );
    // The ambient document is empty, so nothing resolves and the preferred anchor
    // goes in alone.
    expect(hideSelector(sheet([focus], document))).toBe("#related");
  });

  it("emits a grid template for columns, never inert multicol", () => {
    // `column-count` is CSS multicol: it flows *inline content* into columns and
    // the spec makes it inert on any element that is already a grid or a flex
    // container. Every box a user asks to see in two columns is one of those, so
    // the declaration reached the sheet, changed nothing on any page it was
    // written for, and the op reported `applied`. Invariant 8 arrived at through
    // CSS rather than through a count.
    const css = sheet([lens([op("restyle", "main", { style: { columns: 2 } })])], document);

    expect(css).not.toContain("column-count");
    expect(css).toContain("display:grid!important");
    expect(css).toContain("grid-template-columns:repeat(2,minmax(0,1fr))!important");
  });

  it("skips the queries entirely when it is given no document", () => {
    // `document-start`, where the engine deliberately hands the compile no
    // document at all. Nothing can resolve before the page parses, so every
    // candidate of every op would be a whole-document `querySelectorAll` against
    // an empty tree — 480 ops of 8 candidates is 3,840 of them, guaranteed to come
    // back empty and be discarded.
    document.body.innerHTML = PAGE;
    const queries = vi.spyOn(document, "querySelectorAll");

    const css = sheet([lens([op("hide", "related")])], undefined);

    expect(queries).not.toHaveBeenCalled();
    expect(css).toContain("#related{display:none!important}");
    queries.mockRestore();
  });
});

describe("runStructuralOps", () => {
  beforeEach(() => {
    document.body.innerHTML = PAGE;
  });

  it("reports CSS ops against the live DOM, which is where drift is detected", () => {
    // The stylesheet did the hiding; this pass exists to say whether it bit.
    const { results } = run([lens([op("hide", "related")])]);

    expect(results[0]?.status).toBe("applied");
    expect(results[0]?.usedSelector).toBe("#related");
  });

  it("falls through to the next selector candidate", () => {
    document.querySelector("#related")?.removeAttribute("id");

    const { results } = run([lens([op("hide", "related")])]);

    expect(results[0]?.status).toBe("applied");
    expect(results[0]?.usedSelector).toBe("aside.rail");
  });

  it("reports missed when nothing matches — this is the drift signal", () => {
    const { results } = run([lens([op("hide", "gone")])]);

    expect(results[0]?.status).toBe("missed");
    expect(results[0]?.matchedCount).toBe(0);
    expect(results[0]?.usedSelector).toBeUndefined();
    expect(results[0]?.message).toContain("a box that no longer exists");
  });

  it("reports failed when the compile could write no rule, rather than applied", () => {
    // A `keep` on a descendant selector deliberately compiles to nothing: there
    // is no parent in the text to hang `:not()` off. The region still resolves,
    // so the status used to be decided by the resolution alone and came back
    // `applied` for an effect that was never in the cascade — the same lie the
    // unbalanced-selector fix chased, by a different route.
    const { results } = run([
      lens([op("keep", "main")], {
        regions: [{ id: "main", intent: "the article body", selectors: ["main .post"] }],
      }),
    ]);

    expect(results[0]?.status).toBe("failed");
    expect(results[0]?.matchedCount).toBe(1);
    expect(results[0]?.message).toContain("no rule could be compiled");
  });

  it("reports failed for a restyle carrying no usable token", () => {
    const { results } = run([lens([op("restyle", "main", { style: {} })])]);

    expect(results[0]?.status).toBe("failed");
    expect(results[0]?.message).toContain("no rule could be compiled");
  });

  it("reports the path a lens ran on, never the whole URL", () => {
    // The report is persisted into `Lenses.json`, which is still there next week.
    // The query string is where the session tokens and the search terms live.
    const { reports } = run([lens([op("hide", "related")])]);

    expect(reports[0]?.url).toBe(location.pathname);
    expect(reports[0]?.url).not.toContain("://");
  });

  it("moves a region into another, at an index", () => {
    const { results } = run([lens([op("move", "related", { target: "tray", index: 0 })])]);

    expect(results[0]?.status).toBe("applied");
    expect(document.querySelector("#tray")?.firstElementChild?.id).toBe("related");
  });

  it("reports ambiguous when one element was expected and several matched", () => {
    const { results } = run([lens([op("move", "dupe", { target: "tray" })])]);

    expect(results[0]?.status).toBe("ambiguous");
    expect(results[0]?.matchedCount).toBe(2);
    expect(document.querySelector("#tray")?.textContent).toBe("one");
  });

  it("reports failed rather than throwing, and keeps running", () => {
    const { results } = run([
      lens([
        // The destination lives inside the region being moved, so the move would
        // detach the destination with it.
        op("move", "main", { target: "main" }),
        op("hide", "related"),
      ]),
    ]);

    expect(results[0]?.status).toBe("failed");
    expect(results[0]?.message).toContain("destination");
    expect(results[1]?.status).toBe("applied");
  });

  it("reorders items by a sort key", () => {
    const { results } = run([
      lens([
        op("reorder", "feed", {
          itemSelector: ":scope > li",
          sort: { key: "textLength", ascending: true },
        }),
      ]),
    ]);

    expect(results[0]?.status).toBe("applied");
    const texts = Array.from(document.querySelectorAll("#feed li")).map((li) => li.textContent);
    expect(texts[0]).toBe("A short one");
  });

  it("reverses without scrambling the ties", () => {
    const { results } = run([
      lens([
        op("reorder", "feed", {
          itemSelector: ":scope > li",
          sort: { key: "documentOrder", ascending: false },
        }),
      ]),
    ]);

    expect(results[0]?.status).toBe("applied");
    const texts = Array.from(document.querySelectorAll("#feed li")).map((li) => li.textContent);
    expect(texts[0]).toContain("Ordinary post");
    expect(texts[2]).toContain("Sponsored");
  });

  it("filters items with a predicate built from the user's words", () => {
    const { results } = run([
      lens([
        op("filter", "feed", {
          itemSelector: ":scope > li",
          filterMode: "drop",
          predicate: { terms: ["sponsored"], matchMode: "any", field: "text" },
        }),
      ]),
    ]);

    expect(results[0]?.status).toBe("applied");
    expect(results[0]?.message).toBe("1 hidden, 2 kept");

    const hidden = document.querySelectorAll("#feed [data-zentic-lens-hidden]");
    expect(hidden).toHaveLength(1);
    expect(hidden[0]?.textContent).toContain("Sponsored");
  });

  it("brings an item back when it stops matching, so a feed cannot erode", () => {
    const filter = op("filter", "feed", {
      itemSelector: ":scope > li",
      filterMode: "drop",
      predicate: { terms: ["sponsored"], matchMode: "any", field: "text" },
    });

    const journal = new LensJournal(document);
    const harvests = new HarvestStore();
    runStructuralOps(document, [lens([filter])], { journal, harvests });

    const item = document.querySelector("#feed li");
    expect(item?.hasAttribute("data-zentic-lens-hidden")).toBe(true);

    item!.textContent = "No longer an advertisement";
    runStructuralOps(document, [lens([filter])], { journal, harvests });

    expect(item?.hasAttribute("data-zentic-lens-hidden")).toBe(false);
  });

  it("keeps a `:scope >` item selector, which is what the catalog generates", () => {
    // The breadth limit is a *region* rule. `filter` and `harvest` are handed
    // `:scope > li` by the region catalog, so applying it here would disable them.
    const { results } = run([
      lens([
        op("filter", "feed", {
          predicate: { terms: ["Sponsored"], matchMode: "any", field: "text" },
          filterMode: "drop",
          itemSelector: ":scope > li",
        }),
      ]),
    ]);

    expect(results[0]?.status).toBe("applied");
    expect(document.querySelectorAll("#feed li[data-zentic-lens-hidden]")).toHaveLength(1);
  });

  it("labels a region with a text node, never with markup", () => {
    const { results } = run([lens([op("label", "main", { text: "<b>Reading</b>" })])]);

    expect(results[0]?.status).toBe("applied");
    const label = document.querySelector("zentic-lens-label");
    expect(label?.textContent).toBe("<b>Reading</b>");
    expect(label?.querySelector("b")).toBeNull();
  });

  it("harvests fields and inserts them elsewhere", () => {
    const { results } = run([
      lens([
        op("harvest", "feed", {
          harvest: {
            itemSelector: ":scope > li",
            fields: [{ name: "text", selector: ":scope", attribute: "text" }],
            into: "posts",
          },
        }),
        op("insert", "feed", { target: "tray", bucket: "posts" }),
      ]),
    ]);

    expect(results[0]?.status).toBe("applied");
    expect(results[0]?.matchedCount).toBe(3);
    expect(results[1]?.status).toBe("applied");

    const block = document.querySelector("#tray zentic-lens-insert");
    expect(block?.getAttribute("data-bucket")).toBe("posts");
    expect(block?.querySelectorAll("zentic-lens-row")).toHaveLength(3);
  });

  it("never puts harvested text in a report", () => {
    // Counts leave the function; characters do not. A report crosses the bridge,
    // and page content on the bridge is the one thing a lens must never do.
    const { reports } = run([
      lens([
        op("harvest", "feed", {
          harvest: {
            itemSelector: ":scope > li",
            fields: [{ name: "text", selector: ":scope", attribute: "text" }],
            into: "posts",
          },
        }),
      ]),
    ]);

    expect(JSON.stringify(reports)).not.toContain("Sponsored");
  });

  it("reports missed when an insert has nothing to insert", () => {
    const { results } = run([lens([op("insert", "feed", { target: "tray", bucket: "empty" })])]);

    expect(results[0]?.status).toBe("missed");
    expect(document.querySelector("#tray")?.children).toHaveLength(0);
  });

  it("fails an insert that names no bucket rather than guessing one", () => {
    // The bucket used to be inferred from whatever this op's source region
    // harvested during the pass. That guess could render a different list than
    // the one authored, which is exactly the ambiguity `bucket` exists to remove.
    const { results } = run([
      lens([
        op("harvest", "feed", {
          harvest: {
            itemSelector: ":scope > li",
            fields: [{ name: "text", selector: ":scope", attribute: "text" }],
            into: "posts",
          },
        }),
        op("insert", "feed", { target: "tray" }),
      ]),
    ]);

    expect(results[1]?.status).toBe("failed");
    expect(results[1]?.message).toContain("bucket");
    expect(document.querySelector("#tray")?.children).toHaveLength(0);
  });

  it("stacks two lenses on one element and lets the cascade settle it", () => {
    // There used to be an arbitration model here: a conflict class per kind, a
    // key per region, and a second pass that asked the DOM whether two
    // differently-named regions had landed on one element. The earlier op was
    // suppressed and the report said which lens had beaten it.
    //
    // The browser already answers this, in public, by specificity and by rule
    // order — and answering it twice is how an op came to be reported `skipped`
    // by a rule the page had never applied. So both ops run, both rules are in
    // the sheet, and what the user sees is what the cascade says.
    const quiet = lens([op("hide", "main")], { id: "a", name: "Quiet" });
    const reading = lens([op("keep", "main")], { id: "b", name: "Reading" });

    const { reports } = run([quiet, reading]);

    expect(reports[0]?.results[0]?.status).toBe("applied");
    expect(reports[1]?.results[0]?.status).toBe("applied");

    const css = sheet([quiet, reading], document);
    expect(css).toContain("#content{display:none!important}");
    expect(css).toContain(":has(> #content)");
  });

  it("does not collide two lenses that merely named a region alike", () => {
    // `op.region` is a lens-local id. One model called the timeline `feed` and so
    // did the other, and they meant two different boxes. Keying the conflict on
    // the bare name suppressed one of them and then let the popover explain the
    // suppression by naming a lens that had nothing to do with it — attribution
    // by the wrong name, which sends the user to edit the innocent lens.
    const quiet = lens([op("hide", "feed")], {
      id: "a",
      name: "Quiet",
      regions: [{ id: "feed", intent: "the list of posts", selectors: ["#feed"] }],
    });
    const reading = lens([op("keep", "feed")], {
      id: "b",
      name: "Reading",
      regions: [{ id: "feed", intent: "the article", selectors: ["#content"] }],
    });

    const { reports } = run([quiet, reading]);

    expect(reports[0]?.results[0]?.status).toBe("applied");
    expect(reports[1]?.results[0]?.status).toBe("applied");
  });

  it("runs two structural ops on one region and lets DOM order decide", () => {
    // Two labels on one box, from two lenses that named the box differently. Both
    // land; the second one is the one the reader's eye reaches first, because
    // that is where `applyLabel` puts it. No arbitration, and nothing reported
    // as suppressed by a rule that never ran.
    const quiet = lens([op("label", "rail", { text: "Quiet" })], {
      id: "a",
      name: "Quiet",
      regions: [{ id: "rail", intent: "the suggestions rail", selectors: ["#related"] }],
    });
    const reading = lens([op("label", "sidebar", { text: "Reading" })], {
      id: "b",
      name: "Reading",
      regions: [{ id: "sidebar", intent: "the suggestions rail", selectors: ["aside.rail"] }],
    });

    const { reports } = run([quiet, reading]);

    expect(reports[0]?.results[0]?.status).toBe("applied");
    expect(reports[1]?.results[0]?.status).toBe("applied");

    const labels = Array.from(document.querySelectorAll("#related zentic-lens-label"));
    expect(labels.map((node) => node.textContent)).toEqual(["Reading", "Quiet"]);
  });

  it("gives a harvest bucket to the later of two lenses, and tells the earlier", () => {
    // The one clash the cascade cannot settle, because it is not on the page.
    // `HarvestStore` is a single store keyed by bucket name and `put` overwrites,
    // so two lenses harvesting into `posts` clobber rather than stack: whichever
    // ran last is what every `insert` reading `posts` renders, including the one
    // belonging to the other lens.
    //
    // Left alone the loser reported `applied, 3` while nothing it read reached
    // the page — invariant 8 exactly. `failed` rather than `skipped`, because
    // `skipped` is a budget and this is the lens asking for something incoherent.
    const quiet = lens(
      [
        op("harvest", "feed", {
          harvest: {
            itemSelector: ":scope > li",
            fields: [{ name: "text", selector: ":scope", attribute: "text" }],
            into: "posts",
          },
        }),
      ],
      { id: "a", name: "Quiet" },
    );
    const reading = lens(
      [
        op("harvest", "feed", {
          harvest: {
            itemSelector: ":scope > li:not(.item)",
            fields: [{ name: "text", selector: ":scope", attribute: "text" }],
            into: "posts",
          },
        }),
      ],
      { id: "b", name: "Reading" },
    );

    const { reports } = run([quiet, reading]);

    expect(reports[0]?.results[0]?.status).toBe("failed");
    expect(reports[0]?.results[0]?.message).toContain('lens "Reading"');
    expect(reports[0]?.results[0]?.message).toContain("posts");
    expect(reports[0]?.results[0]?.matchedCount).toBe(0);

    // And the bucket really is the later lens's: its item selector matches
    // nothing on this page, so `posts` is empty rather than holding the three
    // items the earlier harvest would have put there.
    expect(reports[1]?.results[0]?.status).toBe("missed");
  });

  it("lets one lens harvest two buckets, because two buckets are two questions", () => {
    const { results } = run([
      lens([
        op("harvest", "feed", {
          harvest: {
            itemSelector: ":scope > li",
            fields: [{ name: "text", selector: ":scope", attribute: "text" }],
            into: "posts",
          },
        }),
        op("harvest", "feed", {
          harvest: {
            itemSelector: ":scope > li",
            fields: [{ name: "text", selector: ":scope", attribute: "text" }],
            into: "headlines",
          },
        }),
      ]),
    ]);

    expect(results.map((entry) => entry.status)).toEqual(["applied", "applied"]);
  });

  it("runs two independent ops on one region", () => {
    const { results } = run([
      lens([op("width", "main", { fraction: 0.6 }), op("restyle", "main", { style: { paddingPx: 8 } })]),
    ]);

    expect(results.map((entry) => entry.status)).toEqual(["applied", "applied"]);
  });

  it("stops at the pass ceiling and reports the remainder, rather than going quiet", () => {
    // Injected clock: the deadline is set on the first read, the first op sees
    // time it can afford, and the second finds the budget gone.
    const readings = [0, 0, 1000];
    let index = 0;
    const now = () => readings[Math.min(index++, readings.length - 1)] ?? 0;

    const { results } = run([lens([op("hide", "related"), op("hide", "header")])], undefined, now);

    expect(results[0]?.status).toBe("applied");
    expect(results[1]?.status).toBe("skipped");
    expect(results[1]?.message).toContain("120ms");
  });

  it("caps the ops one lens may carry", () => {
    const budget: OpBudget = { ...DEFAULT_OP_BUDGET, maxOpsPerLens: 1 };
    const { results } = run([lens([op("hide", "related"), op("hide", "header")])], budget);

    expect(results[0]?.status).toBe("applied");
    expect(results[1]?.status).toBe("skipped");
    expect(results[1]?.message).toContain("1-op budget");
  });

  it("caps the items one pass may touch", () => {
    const list = document.querySelector("#feed")!;
    for (let index = 0; index < 20; index += 1) {
      const item = document.createElement("li");
      item.className = "item";
      item.textContent = `filler ${index}`;
      list.appendChild(item);
    }

    const budget: OpBudget = { ...DEFAULT_OP_BUDGET, maxItemsPerPass: 5 };
    const filter = op("filter", "feed", {
      itemSelector: ":scope > li",
      filterMode: "keep",
      predicate: { terms: ["nothing matches this"], matchMode: "any", field: "text" },
    });

    const { results } = run([lens([filter])], budget);

    expect(results[0]?.matchedCount).toBe(5);
    expect(document.querySelectorAll("#feed [data-zentic-lens-hidden]")).toHaveLength(5);
  });

  it("keeps new cards in the window once a feed has outgrown the item budget", () => {
    // `slice(0, limit)` from the top freezes an infinite feed: past the cap every
    // later pass re-decides the same first cards and the ones the user just
    // scrolled to are never filtered — while the op still reports `applied`, so a
    // filter that has stopped working looks exactly like one that is working.
    const list = document.querySelector("#feed")!;
    list.innerHTML = "";
    for (let index = 0; index < 4; index += 1) {
      const item = document.createElement("li");
      item.textContent = `old ${index}`;
      list.appendChild(item);
    }

    const budget: OpBudget = { ...DEFAULT_OP_BUDGET, maxItemsPerPass: 4 };
    const filter = op("filter", "feed", {
      itemSelector: ":scope > li",
      filterMode: "drop",
      predicate: { terms: ["sponsored"], matchMode: "any", field: "text" },
    });
    const journal = new LensJournal(document);
    const harvests = new HarvestStore();

    runStructuralOps(document, [lens([filter])], { budget, journal, harvests });

    // The feed grows, as feeds do. The observer re-runs against the same journal.
    for (let index = 0; index < 3; index += 1) {
      const item = document.createElement("li");
      item.textContent = `sponsored ${index}`;
      list.appendChild(item);
    }

    runStructuralOps(document, [lens([filter])], { budget, journal, harvests });

    const hidden = Array.from(document.querySelectorAll("#feed [data-zentic-lens-hidden]"));
    expect(hidden).toHaveLength(3);
    expect(hidden.map((item) => item.textContent)).toEqual([
      "sponsored 0",
      "sponsored 1",
      "sponsored 2",
    ]);
  });

  it("spends one item allowance across the whole pass, not one per op", () => {
    // Twelve watched regions with a filter each used to be twelve times the
    // budget: 4,800 items of predicate matching inside a ceiling written for 400.
    document.body.insertAdjacentHTML(
      "beforeend",
      `<ul id="feed-two"><li>one</li><li>two</li><li>three</li></ul>`,
    );

    const budget: OpBudget = { ...DEFAULT_OP_BUDGET, maxItemsPerPass: 4 };
    const predicate: ItemPredicate = { terms: ["nothing"], matchMode: "any", field: "text" };
    const both = lens(
      [
        op("filter", "feed", { itemSelector: ":scope > li", filterMode: "drop", predicate }),
        op("filter", "second", { itemSelector: ":scope > li", filterMode: "drop", predicate }),
      ],
      {
        regions: [
          { id: "feed", intent: "the list of posts", selectors: ["#feed"] },
          { id: "second", intent: "the other list", selectors: ["#feed-two"] },
        ],
      },
    );

    const { results } = run([both], budget);

    // Six rows between them, four in the allowance: two each, and neither op gets
    // to spend the other's share.
    expect(results.map((entry) => entry.matchedCount)).toEqual([2, 2]);
    expect(results.every((entry) => entry.status === "applied")).toBe(true);
  });

  it("never lets an earlier item op starve a later one, pass after pass", () => {
    // The failure the pass-level allowance introduced. Spent strictly in plan
    // order, the first op to meet a large feed takes all of it and every op behind
    // it reports `skipped` — not once, but on every pass for the life of the page,
    // so `filter(sidebar)` never runs a single time. And `skipped` is not `missed`,
    // so `LensReport.isDrifted` is false: the badge shows the calm accent tint
    // reading 1/2, no amber, no Re-fit offered. A lens doing half of what it says
    // with nothing in the UI able to explain why.
    document.body.innerHTML = `
      <ul id="timeline"></ul>
      <ul id="rail"><li>a real link</li><li>Sponsored: an ad in the rail</li></ul>
    `;
    const timeline = document.querySelector("#timeline")!;
    for (let index = 0; index < 12; index += 1) {
      const item = document.createElement("li");
      item.textContent = `post ${index}`;
      timeline.appendChild(item);
    }

    const budget: OpBudget = { ...DEFAULT_OP_BUDGET, maxItemsPerPass: 8 };
    const predicate: ItemPredicate = { terms: ["sponsored"], matchMode: "any", field: "text" };
    const stacked = lens(
      [
        op("filter", "timeline", { itemSelector: ":scope > li", filterMode: "drop", predicate }),
        op("filter", "rail", { itemSelector: ":scope > li", filterMode: "drop", predicate }),
      ],
      {
        regions: [
          { id: "timeline", intent: "the timeline", selectors: ["#timeline"] },
          { id: "rail", intent: "the sidebar", selectors: ["#rail"] },
        ],
      },
    );

    const journal = new LensJournal(document);
    const harvests = new HarvestStore();
    const ad = document.querySelector("#rail li:last-child")!;

    // Three passes, because the point is that the second op is not starved *ever*
    // — a single pass could get lucky on which items the window happened to hold.
    for (let pass = 0; pass < 3; pass += 1) {
      const [report] = runStructuralOps(document, [stacked], { budget, journal, harvests });
      expect(report?.results.map((entry) => entry.status)).toEqual(["applied", "applied"]);
      expect(ad.hasAttribute("data-zentic-lens-hidden")).toBe(true);
    }
  });

  it("holds `op.limit` across the life of the page, not one limit per pass", () => {
    // `itemRun` deliberately hands a truncated feed a window of items nothing has
    // judged yet, so counting kept items only within that window means "keep the
    // first three headlines" keeps three *new* ones on every pass while the three
    // kept last pass stay visible. Ten observer passes and a top-ten filter leaves
    // the user looking at a hundred items.
    document.body.innerHTML = `<ul id="wire"></ul>`;
    const wire = document.querySelector("#wire")!;
    for (let index = 0; index < 6; index += 1) {
      const item = document.createElement("li");
      item.textContent = `headline ${index}`;
      wire.appendChild(item);
    }

    // Smaller than the list, so every pass gets a window rather than the whole
    // thing — which is exactly the condition an infinite feed is always in.
    const budget: OpBudget = { ...DEFAULT_OP_BUDGET, maxItemsPerPass: 3 };
    const top = lens(
      [
        op("filter", "wire", {
          itemSelector: ":scope > li",
          filterMode: "keep",
          limit: 3,
          predicate: { terms: ["headline"], matchMode: "any", field: "text" },
        }),
      ],
      { regions: [{ id: "wire", intent: "the headlines", selectors: ["#wire"] }] },
    );

    const journal = new LensJournal(document);
    const harvests = new HarvestStore();
    const judged = () => Array.from(wire.querySelectorAll("[data-zentic-lens-item]"));

    runStructuralOps(document, [top], { budget, journal, harvests });
    expect(judged()).toHaveLength(3);

    // The second pass reaches the three rows the first one could not. They are
    // over the limit, so they are hidden rather than kept beside the first three.
    runStructuralOps(document, [top], { budget, journal, harvests });
    expect(judged()).toHaveLength(6);
    expect(wire.querySelectorAll("[data-zentic-lens-hidden]")).toHaveLength(3);

    // And it stays true: every later pass re-decides a window and the count does
    // not creep, which is what "the first three" has to mean to be worth writing.
    for (let pass = 0; pass < 4; pass += 1) {
      runStructuralOps(document, [top], { budget, journal, harvests });
      expect(wire.querySelectorAll(":scope > li:not([data-zentic-lens-hidden])")).toHaveLength(3);
    }
  });

  it("caps how many selectors one region may offer", () => {
    // `regions.ts` derives at most six, best-first, so this is a bound on what a
    // lens from anywhere else can carry: five hundred selectors across forty ops
    // is a multi-megabyte stylesheet, rebuilt on every SPA navigation. Here the only
    // candidate that resolves sits past the cap, so the region honestly misses
    // rather than the engine walking the whole list to find it.
    document.body.innerHTML = `<aside id="ninth">the rail</aside>`;
    const selectors = [
      ...Array.from({ length: 8 }, (_, index) => `#absent-${index}`),
      "#ninth",
    ];

    const { results } = run([
      lens([op("hide", "wide")], {
        regions: [{ id: "wide", intent: "the rail", selectors }],
      }),
    ]);

    expect(results[0]?.status).toBe("missed");
  });

  const harvestingWith = (selector: string): string => {
    document.body.innerHTML = `
      <ul id="feed"><li><span>Alpha</span></li><li><b>Beta</b></li></ul>
      <div id="tray"></div>
    `;
    run([
      lens([
        op("harvest", "feed", {
          harvest: {
            itemSelector: ":scope > li",
            fields: [{ name: "text", selector, attribute: "text" }],
            into: "posts",
          },
        }),
        op("insert", "feed", { target: "tray", bucket: "posts" }),
      ]),
    ]);
    return document.querySelector("#tray")?.textContent ?? "";
  };

  it("lets a harvest field name a list, because a card marks its title up either way", () => {
    // The comma is a *region* rule: a region is one thing, and a list is a way to
    // smuggle a second, broader subject into a rule authored for the first. A
    // field is read with `querySelector` inside one card, where `span, b` means
    // "whichever of these this card uses" — which is how a real feed is written.
    // Banned everywhere, it silently harvested an empty string instead.
    expect(harvestingWith("span, b")).toBe("AlphaBeta");
  });

  it("puts a harvest field selector through the shape gate all the same", () => {
    // `[title*="url("]` is legal CSS carrying a token that must never reach a
    // stylesheet. It reaches none from here — which is exactly why `readField`
    // was the one selector path that never asked — and one validated path beside
    // one unvalidated path is how the next caller picks the wrong one.
    expect(harvestingWith('span[title*="url("]')).toBe("");
  });

  it("fails an item op whose selector it cannot use, rather than guessing", () => {
    // `itemRun` falls back to the region's own children when no item selector was
    // named, which is the right default for "sort this list". Doing it for a
    // selector the op *did* name turns "drop the cards matching X" into "drop
    // everything directly inside this region" — on a `drop` filter, an emptied
    // feed. A1.2's rule, and the reason a list is refused here.
    document.body.innerHTML = `<ul id="feed"><li>one</li><li>two</li></ul>`;

    const { results } = run([
      lens([
        op("filter", "feed", {
          itemSelector: "li, div",
          filterMode: "drop",
          predicate: { terms: ["one"], matchMode: "any", field: "text" },
        }),
      ]),
    ]);

    expect(results[0]?.status).toBe("failed");
    expect(document.querySelectorAll("#feed [data-zentic-lens-hidden]")).toHaveLength(0);
  });

  it("gives every lens a report, even one whose ops all missed", () => {
    const { reports } = run([
      lens([op("hide", "gone")], { id: "a", name: "One" }),
      lens([], { id: "b", name: "Two" }),
    ]);

    expect(reports).toHaveLength(2);
    expect(reports[1]?.results).toEqual([]);
  });

  it("restores the page exactly, which is the promise the feature makes", () => {
    const before = document.body.innerHTML;

    const { journal } = run([
      lens([
        op("move", "related", { target: "tray", index: 0 }),
        op("label", "main", { text: "Reading" }),
        op("reorder", "feed", {
          itemSelector: ":scope > li",
          sort: { key: "textLength", ascending: true },
        }),
        op("filter", "feed", {
          itemSelector: ":scope > li",
          filterMode: "drop",
          predicate: { terms: ["sponsored"], matchMode: "any", field: "text" },
        }),
        op("harvest", "feed", {
          harvest: {
            itemSelector: ":scope > li",
            fields: [{ name: "text", selector: ":scope", attribute: "text" }],
            into: "posts",
          },
        }),
        op("insert", "feed", { target: "tray", bucket: "posts" }),
      ]),
    ]);

    expect(document.body.innerHTML).not.toBe(before);

    journal.undo();

    expect(document.body.innerHTML).toBe(before);
  });

  it("does not resurrect a node the site deleted while the lens was on", () => {
    // The reversibility test above never touches the DOM between applying and
    // clearing, which is why this went unnoticed: `insertBefore` **re-attaches** a
    // detached node rather than throwing, so the catch in `undo` never fires for
    // one the site removed — it puts it back. A virtualised feed that recycled six
    // cards gets them all back on ⌘\, and a cookie banner the strip layer
    // dismissed returns, undoing work that was never ours to undo.
    const { journal } = run([
      lens([
        op("reorder", "feed", {
          itemSelector: ":scope > li",
          sort: { key: "textLength", ascending: true },
        }),
      ]),
    ]);

    const recycled = document.querySelector("#feed li")!;
    recycled.remove();
    const remaining = document.querySelectorAll("#feed li").length;

    journal.undo();

    expect(document.querySelectorAll("#feed li")).toHaveLength(remaining);
    expect(document.contains(recycled)).toBe(false);
  });

  it("does not post children into a parent the site detached, which would lose them", () => {
    // The failure direction that costs the user content. `insertBefore` into a
    // detached parent succeeds silently, so a node that is on screen right now —
    // because the site re-parented it somewhere that survived — is taken off the
    // page by our own undo and never comes back.
    const { journal } = run([
      lens([
        op("reorder", "feed", {
          itemSelector: ":scope > li",
          sort: { key: "textLength", ascending: true },
        }),
      ]),
    ]);

    const feed = document.querySelector("#feed")!;
    const survivor = feed.querySelector("li")!;
    const tray = document.querySelector("#tray")!;
    feed.remove();
    tray.appendChild(survivor);

    journal.undo();

    expect(tray.contains(survivor)).toBe(true);
    expect(document.contains(survivor)).toBe(true);
  });

  it("survives a second undo, so a double clear cannot corrupt the page", () => {
    const before = document.body.innerHTML;
    const { journal } = run([lens([op("label", "main", { text: "Reading" })])]);

    journal.undo();
    journal.undo();

    expect(document.body.innerHTML).toBe(before);
  });
});

// MARK: - W1: exhaustiveness, driven from the types

const HARVEST_POSTS: LensOp = op("harvest", "feed", {
  harvest: {
    itemSelector: ":scope > li",
    fields: [{ name: "text", selector: ":scope", attribute: "text" }],
    into: "posts",
  },
});

const fixtures = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
  "..",
  "Tests",
  "Fixtures",
  "wire",
);

/**
 * One op of every kind, with the DOM difference it must make.
 *
 * `Record<LensOpKind, …>` is the whole point of the shape: an eleventh kind added
 * to the wire union fails to compile here until someone writes down what it does
 * to a page — and then fails at runtime until the runner actually does it. A
 * runner branch that returns `applied` and touches nothing is the failure this is
 * written against, and it is the one the first build shipped.
 *
 * Each case says what the page looks like before and asserts a concrete
 * difference after: a node moved, an attribute set, an element inserted, an order
 * changed. Nothing here asserts on a *status*; the statuses have their own table
 * below, and a test that checks only the report is a test that would pass against
 * a runner that reports without running.
 */
const KIND_CASES: Record<
  LensOpKind,
  {
    ops: LensOp[];
    /**
     * One concrete fact, read off the page — or off the sheet, since a CSS op's
     * whole effect is a rule and a rule in the cascade is what the user sees.
     */
    observable: (css: string) => string;
    expected: string;
  }
> = {
  hide: {
    ops: [op("hide", "related")],
    observable: (css) => hideSelector(css) ?? "",
    expected: "#related",
  },
  keep: {
    ops: [op("keep", "main")],
    observable: (css) => ruleContaining(css, ":not(") ?? "",
    expected: ":has(> #content) > *:not(#content)",
  },
  width: {
    ops: [op("width", "main", { fraction: 0.5 })],
    observable: (css) => css.match(/max-width:([\d.]+%)/)?.[1] ?? "",
    expected: "50.0%",
  },
  restyle: {
    ops: [op("restyle", "main", { style: { paddingPx: 8 } })],
    observable: (css) => css.match(/padding:(\d+px)/)?.[1] ?? "",
    expected: "8px",
  },
  move: {
    ops: [op("move", "related", { target: "tray", index: 0 })],
    observable: () => document.querySelector("#tray")?.firstElementChild?.id ?? "",
    expected: "related",
  },
  reorder: {
    ops: [
      op("reorder", "feed", {
        itemSelector: ":scope > li",
        sort: { key: "textLength", ascending: true },
      }),
    ],
    observable: () => document.querySelector("#feed li")?.textContent ?? "",
    expected: "A short one",
  },
  filter: {
    ops: [
      op("filter", "feed", {
        itemSelector: ":scope > li",
        filterMode: "drop",
        predicate: { terms: ["sponsored"], matchMode: "any", field: "text" },
      }),
    ],
    observable: () => String(document.querySelectorAll("#feed [data-zentic-lens-hidden]").length),
    expected: "1",
  },
  label: {
    ops: [op("label", "main", { text: "Reading" })],
    observable: () => document.querySelector("#content zentic-lens-label")?.textContent ?? "",
    expected: "Reading",
  },
  harvest: {
    // A harvest writes nothing into the page by itself — its whole output is the
    // bucket — so the difference it must make is the one an `insert` can read
    // back out. Paired deliberately: `harvest` alone changing nothing observable
    // is exactly why the pair is the unit.
    ops: [HARVEST_POSTS, op("insert", "feed", { target: "tray", bucket: "posts" })],
    observable: () => String(document.querySelectorAll("#tray zentic-lens-row").length),
    expected: "3",
  },
  insert: {
    ops: [HARVEST_POSTS, op("insert", "feed", { target: "tray", bucket: "posts" })],
    observable: () =>
      document.querySelector("#tray zentic-lens-insert")?.getAttribute("data-bucket") ?? "",
    expected: "posts",
  },
};

/** The first rule in a sheet whose selector carries `needle`, without its block. */
function ruleContaining(css: string, needle: string): string | undefined {
  return css
    .split("\n")
    .map((rule) => rule.slice(0, rule.indexOf("{")))
    .find((selector) => selector.includes(needle));
}

describe("every op kind is wired", () => {
  beforeEach(() => {
    document.body.innerHTML = PAGE;
  });

  it("covers exactly the kinds the wire declares, in both languages", () => {
    // The `Record` above is checked by the compiler against the TypeScript union.
    // This checks the union against the fixture Swift is driven from, so a kind
    // added on one side of the bridge cannot sit there unimplemented on the other.
    const declared = (
      JSON.parse(readFileSync(join(fixtures, "lens-op-kinds.json"), "utf8")) as {
        kinds: LensOpKind[];
      }
    ).kinds;

    expect(Object.keys(KIND_CASES).sort()).toEqual([...declared].sort());
  });

  for (const [kind, entry] of Object.entries(KIND_CASES)) {
    it(`makes a difference to the page for ${kind}`, () => {
      // The same fact, read against a lens carrying no ops at all: whatever the
      // op is supposed to produce, it must not already be true.
      expect(
        entry.observable(sheet([lens([])], document)),
        `${kind} was already true before the pass`,
      ).not.toBe(entry.expected);

      const { results } = run([lens(entry.ops)]);

      expect(
        entry.observable(sheet([lens(entry.ops)], document)),
        `${kind} reported without doing anything`,
      ).toBe(entry.expected);
      // And nothing in the lens quietly failed on the way there.
      expect(results.every((item) => item.status === "applied")).toBe(true);
    });
  }
});

/**
 * A scenario that produces each status, and only that status.
 *
 * `Record<LensOpStatus, …>` again: a sixth status added to the wire fails to
 * compile until there is a path that reaches it. A status nothing produces is
 * dead vocabulary in the UI; a status *nobody can reach* is worse, because the
 * failure it was meant to describe is being reported as something else.
 */
const STATUS_CASES: Record<LensOpStatus, () => LensOpResult> = {
  applied: () => run([lens([op("hide", "related")])]).results[0]!,
  missed: () => run([lens([op("hide", "gone")])]).results[0]!,
  // A CSS op on a selector that names two boxes. The rule hides both.
  ambiguous: () => run([lens([op("hide", "dupe")])]).results[0]!,
  // The per-lens op cap, which is a budget rather than an override.
  skipped: () =>
    run([lens([op("hide", "related"), op("hide", "header")])], {
      ...DEFAULT_OP_BUDGET,
      maxOpsPerLens: 1,
    }).results[1]!,
  failed: () => run([lens([op("move", "main", { target: "main" })])]).results[0]!,
};

describe("every op status is reachable", () => {
  beforeEach(() => {
    document.body.innerHTML = PAGE;
  });

  for (const [status, produce] of Object.entries(STATUS_CASES)) {
    it(`produces ${status}`, () => {
      expect(produce().status).toBe(status);
    });
  }
});

describe("a CSS op reports what the rule actually did", () => {
  beforeEach(() => {
    document.body.innerHTML = PAGE;
  });

  it("reports ambiguous when the rule's selector named more than one element", () => {
    // The `applyOp` CSS branch returned a flat `applied` and never asked
    // `singleStatus`. So a `hide` on NYT's `div.jXhsNG_gridCell.jXhsNG_positioned`
    // — the *preferred* anchor for one box, and a class 160 elements share —
    // removed 160 boxes and badged green. The cascade makes this worse than the
    // structural case rather than better: a `move` acts on the first match and
    // leaves the rest, a rule hits every one of them.
    const { results } = run([lens([op("hide", "dupe")])]);

    expect(results[0]?.status).toBe("ambiguous");
    expect(results[0]?.matchedCount).toBe(2);
    expect(results[0]?.message).toContain("applies to all of them");
    // And the sheet really does say so, which is what makes the report true.
    expect(sheet([lens([op("hide", "dupe")])], document)).toContain(
      "div.dupe{display:none!important}",
    );
  });

  it("does not call a single match ambiguous", () => {
    const { results } = run([lens([op("hide", "related")])]);

    expect(results[0]?.status).toBe("applied");
    expect(results[0]?.message).toBeUndefined();
  });

  it("reports a restyle carrying columns, which used to compile to nothing that worked", () => {
    const { results } = run([lens([op("restyle", "main", { style: { columns: 2 } })])]);

    expect(results[0]?.status).toBe("applied");
    expect(sheet([lens([op("restyle", "main", { style: { columns: 2 } })])], document)).toContain(
      "grid-template-columns",
    );
  });
});

/**
 * `columns` against a page that has already chosen its own `display`.
 *
 * The rule above only reads the string we wrote. This reads what the *cascade*
 * makes of it against a site's own stylesheet, which is where `column-count`
 * died: CSS multicol is defined to be inert on an element that is already a grid
 * or a flex container, and a feed, a rail and a card list are all one of those.
 * The declaration reached the sheet, changed nothing on any page the token was
 * ever written for, and `applied` was reported for it — invariant 8, arrived at
 * through CSS rather than through a count.
 *
 * So the site's `display` comes from a stylesheet here rather than an inline
 * style: that is how real pages set it, and it is the comparison that decides
 * whether our rule wins. Three of them, because the failure was not uniform — a
 * block container was the one shape multicol did work on, which is why the bug
 * survived a test written against a plain `<div>`.
 */
describe("columns lays a box out in tracks whatever the site made it", () => {
  const TRACKS = "repeat(2,minmax(0,1fr))";

  const columnsLens = lens([op("restyle", "main", { style: { columns: 2 } })]);

  beforeEach(() => {
    document.head.innerHTML = "";
    document.body.innerHTML = PAGE;
  });

  afterEach(() => {
    document.head.innerHTML = "";
  });

  /** Put the site's own rule in the cascade, then ours after it, as the engine
   * does — `injectStylesheet` re-appends to the end of `head` for this reason. */
  function render(siteDisplay: string): CSSStyleDeclaration {
    const site = document.createElement("style");
    site.textContent = `#content{display:${siteDisplay}}`;
    document.head.append(site);

    const ours = document.createElement("style");
    ours.textContent = sheet([columnsLens], document);
    document.head.append(ours);

    return getComputedStyle(document.querySelector("#content")!);
  }

  for (const siteDisplay of ["block", "flex", "grid"]) {
    it(`overrides a site that made the region display:${siteDisplay}`, () => {
      const before = getComputedStyle(document.querySelector("#content")!);
      expect(before.getPropertyValue("grid-template-columns")).not.toBe(TRACKS);

      const computed = render(siteDisplay);

      // Both halves matter. The template alone does nothing on a flex container,
      // and `display:grid` alone is not two columns.
      expect(computed.display).toBe("grid");
      expect(computed.getPropertyValue("grid-template-columns")).toBe(TRACKS);
    });
  }

  it("emits no multicol, which is the declaration that silently did nothing", () => {
    expect(sheet([columnsLens], document)).not.toContain("column-count");
  });

  it("reports applied only because the compile really wrote the rule", () => {
    // The status comes from `PlannedOp.emitted`, so a `columns` token that
    // stopped compiling would report `failed`, not `applied` — the specific lie
    // the emitted flag exists to prevent.
    const { results } = run([columnsLens]);

    expect(results[0]?.status).toBe("applied");
    expect(results[0]?.usedSelector).toBe("#content");
  });
});

describe("a harvest that read nothing says so", () => {
  beforeEach(() => {
    document.body.innerHTML = `
      <ul id="feed"><li><h3>Alpha</h3></li><li><h3>Beta</h3></li></ul>
      <div id="tray"></div>
    `;
  });

  const harvestAndInsert = (fieldSelector: string): LensOpResult[] =>
    run([
      lens(
        [
          op("harvest", "feed", {
            harvest: {
              itemSelector: ":scope > li",
              fields: [{ name: "text", selector: fieldSelector, attribute: "text" }],
              into: "posts",
            },
          }),
          op("insert", "feed", { target: "tray", bucket: "posts" }),
        ],
        {
          regions: [
            { id: "feed", intent: "the list of posts", selectors: ["#feed"] },
            { id: "tray", intent: "the tray at the bottom", selectors: ["#tray"] },
          ],
        },
      ),
    ]).results;

  it("reports missed rather than applied when every field selector read an empty value", () => {
    // The silent-success bug, end to end. A field selector the site does not use
    // makes `readField` return `""` — it cannot tell "this card has no byline"
    // from "`.byline` is not what this site calls it" — records still come back
    // one per item, so the count is right and the status was `applied`. Then
    // `buildInsertion` skips every empty cell, the block renders childless, and a
    // harvest-and-insert pair that put literally nothing on the page badged green
    // with `applied, matchedCount: 0`.
    const results = harvestAndInsert(".byline-that-does-not-exist");

    expect(results[0]?.status).toBe("missed");
    expect(results[0]?.message).toContain("empty value");
    // And the insert that depended on it says the same, rather than inserting an
    // empty node and reporting it.
    expect(results[1]?.status).toBe("missed");
    expect(document.querySelector("#tray")?.children).toHaveLength(0);
    expect(document.querySelector("zentic-lens-insert")).toBeNull();
  });

  it("still applies when the selector is the one the site actually uses", () => {
    const results = harvestAndInsert("h3");

    expect(results.map((entry) => entry.status)).toEqual(["applied", "applied"]);
    expect(document.querySelectorAll("#tray zentic-lens-row")).toHaveLength(2);
  });

  it("reports missed when the rendered block would have no children", () => {
    // The other half, reachable on its own: a harvest whose fields *did* read
    // something, and an insert whose only field is the one `buildInsertion`
    // deliberately does not render a cell for. The block comes out childless and
    // the op used to report `applied, 0`.
    const results = run([
      lens(
        [
          op("harvest", "feed", {
            harvest: {
              itemSelector: ":scope > li",
              fields: [{ name: "href", selector: ":scope", attribute: "text" }],
              into: "posts",
            },
          }),
          op("insert", "feed", { target: "tray", bucket: "posts" }),
        ],
        {
          regions: [
            { id: "feed", intent: "the list of posts", selectors: ["#feed"] },
            { id: "tray", intent: "the tray at the bottom", selectors: ["#tray"] },
          ],
        },
      ),
    ]).results;

    expect(results[0]?.status).toBe("applied");
    expect(results[1]?.status).toBe("missed");
    expect(results[1]?.message).toContain("value to render");
    expect(document.querySelector("#tray")?.children).toHaveLength(0);
  });
});

describe("a predicate pays only for what it asks", () => {
  beforeEach(() => {
    document.body.innerHTML = PAGE;
  });

  const linkQueries = (predicate: ItemPredicate): string[] => {
    const seen: string[] = [];
    const original = Element.prototype.querySelectorAll;
    Element.prototype.querySelectorAll = function (this: Element, selector: string) {
      seen.push(selector);
      return original.call(this, selector) as never;
    } as typeof original;

    try {
      run([
        lens([
          op("filter", "feed", { itemSelector: ":scope > li", filterMode: "drop", predicate }),
        ]),
      ]);
    } finally {
      Element.prototype.querySelectorAll = original;
    }
    return seen.filter((selector) => selector === "a[href]");
  };

  it("counts an item's links only when the predicate names a link bound", () => {
    // `matchesPredicate` ran `querySelectorAll("a[href]")` on every item before
    // reading a single field of the predicate — a subtree scan per item, 400 of
    // them per pass and 3,200 a second at the observer cap, discarded unread on
    // every predicate that only wanted to match a word. Which is nearly all of
    // them: `minLinks`/`maxLinks` are the rarest fields a predicate carries.
    expect(linkQueries({ terms: ["sponsored"], matchMode: "any", field: "text" })).toEqual([]);
  });

  it("still counts them when the predicate does name one", () => {
    // Lazy, not gone. A predicate that asks about links gets an answer, and gets
    // it once however many bounds it names.
    const asked = linkQueries({
      terms: [],
      matchMode: "any",
      field: "text",
      minLinks: 0,
      maxLinks: 3,
    });

    expect(asked.length).toBe(document.querySelectorAll("#feed > li").length);
  });
});

describe("the journal holds no references to the page", () => {
  beforeEach(() => {
    document.body.innerHTML = PAGE;
  });

  it("removes our marks from cards a later pass never looked at", () => {
    // `recordAttribute` kept a `{element, name, previous}` record per marked item
    // in a **strong** array, and `previous` was structurally always null: the two
    // attributes are ours, so nothing else can have written them. So the array was
    // doing a `querySelectorAll`'s job while pinning every element it named — and
    // `rerunLive` re-marks items pass after pass without an undo in between, so a
    // five-thousand-card scroll held every virtualised subtree the feed had ever
    // recycled.
    //
    // The behavioural half of that, which a sweep gets right and a replay does
    // not: a mark left by a pass whose journal was replaced still comes off.
    const filter = op("filter", "feed", {
      itemSelector: ":scope > li",
      filterMode: "drop",
      predicate: { terms: ["sponsored"], matchMode: "any", field: "text" },
    });

    // A pass whose journal is then thrown away, exactly as a re-fit throws one away.
    runStructuralOps(document, [lens([filter])], {
      journal: new LensJournal(document),
      harvests: new HarvestStore(),
    });
    expect(document.querySelectorAll("[data-zentic-lens-item]").length).toBeGreaterThan(0);

    // A fresh journal that has recorded nothing at all still gives the page back.
    new LensJournal(document).undo();

    expect(document.querySelectorAll("[data-zentic-lens-item]")).toHaveLength(0);
    expect(document.querySelectorAll("[data-zentic-lens-hidden]")).toHaveLength(0);
  });
});

describe("a region its selectors have drifted off", () => {
  // The measured failure, and the only reason a fingerprint is stored at all.
  //
  // A best-first selector list degrades gracefully when a stale anchor matches
  // *nothing* — the runner falls through, the op reports `missed`, the badge says
  // so. Across five live sites the preferred anchor is a structural path or a
  // build hash on four of them, and after a redesign those keep matching: a
  // *different* element. Utility classes do the same thing one tier down, where
  // `.rail` "resolves" to whichever box happens to be first in document order. So
  // the failure that actually occurs is a lens hiding, restyling or labelling the
  // wrong box while reporting `applied` — invisible to the badge, to Re-fit and to
  // the user.
  //
  // Every test here is about the two halves of the fix: the fingerprint finds the
  // box the user pointed at, and when it cannot it declines rather than guessing.

  /** The page on the day the lens was written. */
  const AUTHORED = `
    <div id="page">
      <main id="content"><p>The article the user was reading that day.</p></main>
      <aside class="rail sidebar" role="complementary" data-testid="sidebarColumn">
        <h2>Suggested</h2>
        <p>Godwits, dunlin and knot arrive together when the tide turns.</p>
        <p>Curlews came back in numbers nobody expected after the restoration.</p>
      </aside>
    </div>
  `;

  /** The same page after a redesign that put a promo box in front of the rail.
   * Both of the lens's anchors now match two elements and the *impostor* is first
   * in document order, so first-match resolution lands squarely on it. */
  const REDESIGNED = `
    <div id="page">
      <aside class="rail" data-promo><p>Subscribe</p></aside>
      <main id="content"><p>The article the user was reading that day.</p></main>
      <aside class="rail sidebar" role="complementary" data-testid="sidebarColumn">
        <h2>Suggested</h2>
        <p>Godwits, dunlin and knot arrive together when the tide turns.</p>
        <p>Curlews came back in numbers nobody expected after the restoration.</p>
      </aside>
    </div>
  `;

  /** The rail's signature, taken from the page as it was authored — which is what
   * `LensEditorOverlay.save` does with the element the user pointed at. */
  function railPrint(): RegionFingerprint {
    document.body.innerHTML = AUTHORED;
    const rail = document.querySelector("#page > aside");
    if (!rail) throw new Error("the authored page has no rail");
    return buildFingerprint(rail);
  }

  /** A lens anchored the way `regions.ts` really anchors a box like this: a class
   * pair and a structural path, neither of which survives the redesign. */
  function railLens(
    ops: LensOp[],
    fingerprint?: RegionFingerprint,
    selectors: string[] = ["aside.rail", "body>div>aside"],
  ): Lens {
    return lens(ops, {
      regions: [
        {
          id: "rail",
          intent: "the suggestions rail",
          selectors,
          ...(fingerprint ? { fingerprint } : {}),
        },
      ],
    });
  }

  const impostor = (): Element => document.querySelectorAll("#page > aside")[0] as Element;
  const rail = (): Element => document.querySelectorAll("#page > aside")[1] as Element;

  it("labels the box the fingerprint recognises, not the impostor the anchors name", () => {
    const print = railPrint();
    document.body.innerHTML = REDESIGNED;

    const { results } = run([railLens([op("label", "rail", { text: "Suggestions" })], print)]);

    expect(rail().querySelector("zentic-lens-label")).not.toBeNull();
    expect(impostor().querySelector("zentic-lens-label")).toBeNull();
    expect(results[0]?.status).toBe("applied");
  });

  it("says the region was found by structure rather than badging a rescue green", () => {
    // `applied` is the truth — the label really is on the rail. But it is on a box
    // no anchor the lens carries can name any more, so the next redesign has
    // nothing left to fall back to. A badge that cannot tell "still fits" from
    // "held together by structure" is the same silence the fingerprint exists to
    // break, so the rescue is said out loud and `usedSelector` stays unset:
    // nothing the lens calls this region matched it.
    const print = railPrint();
    document.body.innerHTML = REDESIGNED;

    const { results } = run([railLens([op("label", "rail", { text: "Suggestions" })], print)]);

    expect(results[0]?.usedSelector).toBeUndefined();
    expect(results[0]?.message).toBe(
      "the region's selectors no longer match; the element was found by its structure",
    );
  });

  it("writes the rule against the box the fingerprint found, not the stale anchor", () => {
    // The half that would otherwise make this mechanism worse than no mechanism at
    // all. The sheet and the pass are compiled and run from one resolver so they
    // can never name different boxes — but the sheet is written against a
    // *selector*, and after a rescue every selector the lens carries names the
    // impostor. So a path is minted from the rescued element, and the rule and the
    // report describe the same rail.
    const print = railPrint();
    document.body.innerHTML = REDESIGNED;

    const css = sheet([railLens([op("hide", "rail")], print)], document);
    const selector = hideSelector(css);

    expect(selector).toBeDefined();
    expect(document.querySelectorAll(selector!)).toHaveLength(1);
    expect(document.querySelector(selector!)).toBe(rail());
    expect(css).not.toContain("aside.rail{");
  });

  it("reports missed when the region is genuinely gone", () => {
    // The answer the threshold exists to produce. A fingerprint that always found
    // *something* would be a confident wrong answer machine; declining is what
    // turns drift into an honest amber badge instead of a lens quietly acting on
    // whatever is nearest.
    const print = railPrint();
    document.body.innerHTML = `
      <div id="page">
        <main id="content"><p>The article, and nothing beside it any more.</p></main>
      </div>
    `;

    const { results } = run([railLens([op("label", "rail", { text: "Suggestions" })], print)]);

    expect(results[0]?.status).toBe("missed");
    expect(document.querySelector("zentic-lens-label")).toBeNull();
  });

  it("declines rather than choose between two boxes it cannot tell apart", () => {
    // The scorer's margin, seen from the runner. A redesign renamed the anchor —
    // so the selectors have nothing to say — and left two rails that differ in
    // nothing the fingerprint records. Two answers is not an answer, and taking
    // the first one would be the wrong-box defect with an extra step in front of
    // it, so the only honest outcome is the one a deleted region gets.
    const print = railPrint();
    document.body.innerHTML = AUTHORED;
    const only = document.querySelector("#page > aside") as Element;
    document.querySelector("#page")?.append(only.cloneNode(true));

    const { results } = run([
      railLens([op("label", "rail", { text: "Suggestions" })], print, ["#rail-2026"]),
    ]);

    expect(results[0]?.status).toBe("missed");
    expect(document.querySelector("zentic-lens-label")).toBeNull();
  });

  it("leaves a lens saved before fingerprinting existed exactly as it was", () => {
    // `fingerprint` is optional on the wire for this case, and this is the test
    // that says what "optional" buys. The same drifted page, the same anchors, no
    // print: the runner does what it has always done — first match wins, several
    // matches is `ambiguous`, and the impostor gets the label.
    document.body.innerHTML = REDESIGNED;

    const { results } = run([railLens([op("label", "rail", { text: "Suggestions" })])]);

    expect(results[0]?.status).toBe("ambiguous");
    expect(results[0]?.usedSelector).toBe("aside.rail");
    expect(results[0]?.message).not.toContain("found by its structure");
    expect(impostor().querySelector("zentic-lens-label")).not.toBeNull();
  });

  it("keeps an ambiguous anchor when the fingerprint declines, rather than dropping to missed", () => {
    // A fingerprint that cannot answer must not make a lens *worse* than it was
    // without one. The anchors still name something, so the op still runs and
    // still reports the ambiguity — the print adds an answer, it never removes the
    // one the selectors gave.
    document.body.innerHTML = REDESIGNED;
    const unrelated: RegionFingerprint = {
      ...railPrint(),
      tag: "section",
    };
    document.body.innerHTML = REDESIGNED;

    const { results } = run([
      railLens([op("label", "rail", { text: "Suggestions" })], unrelated),
    ]);

    expect(results[0]?.status).toBe("ambiguous");
    expect(results[0]?.usedSelector).toBe("aside.rail");
  });
});

describe("the fingerprint is in the shipped graph", () => {
  // The defect this whole file's drift story was built on top of, and the one no
  // behavioural test can see: `fingerprint.ts` existed, was unit-tested, and was
  // imported by nothing. esbuild tree-shakes an unimported module in silence, so
  // both bundles shipped without a byte of it while every test passed.
  //
  // So the claim under test is *reachability*, asserted the way a bundler decides
  // it: follow the imports that survive erasure, from each entry point that is
  // actually built, and see whether this module is among them.

  /** `web/src`, so a test can walk the module graph it makes a claim about. */
  const src = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "src");

  /**
   * Every module a bundle rooted at `entry` would carry.
   *
   * `import type` is erased before bundling, so a type-only edge is not an edge —
   * which is exactly the distinction that made the old `fingerprint.ts` look wired
   * from the file list and be absent from the script.
   */
  function valueGraph(entry: string): Set<string> {
    const seen = new Set<string>();
    const queue = [entry];

    while (queue.length > 0) {
      const file = queue.pop() as string;
      if (seen.has(file)) continue;
      seen.add(file);

      const source = readFileSync(join(src, file), "utf8");
      for (const match of source.matchAll(/^import\s+(?!type\s)[^;]*?from\s+"(\.[^"]+)";$/gm)) {
        queue.push(join(dirname(file), (match[1] as string).replace(/\.js$/, ".ts")));
      }
    }

    return seen;
  }

  it("reaches fingerprint.ts from both entry points build.mjs bundles", () => {
    // `main.ts` is the document-start script, where the fingerprint is *read* to
    // rescue a drifted region; `editor-entry.ts` is the on-demand editor bundle,
    // where it is *written* at save time. A producer with no consumer and a
    // consumer with no producer are both dead code, so both are asserted.
    for (const entry of ["main.ts", "lens/editor-entry.ts"]) {
      const graph = valueGraph(entry);
      expect(Array.from(graph).sort(), `${entry} must bundle the fingerprint`).toContain(
        "lens/fingerprint.ts",
      );
    }
  });
});
