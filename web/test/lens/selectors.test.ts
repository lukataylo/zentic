import { describe, expect, it } from "vitest";

import {
  safeItemSelector,
  safeRegionSelector,
  safeSelector,
} from "../../src/lens/selectors.js";

// The last gate before a lens selector reaches the stylesheet.
//
// The tables below are Swift's, from `LensValidationTests`. Driving both
// implementations over one set of cases is the only way this stays a port, and it
// has to stay one: the Swift validator runs when a lens is saved or read back off
// disk, and this one runs at the point of use — but a lens reaches the page in a
// bootstrap configuration, and then this side is the only gate there was.
//
// The acceptance half matters as much as the rejection half. A validator that
// rejects ordinary markup is one whoever hits it next quietly loosens, and a
// loosening is what put a literal word list here in the first place.

describe("safeRegionSelector", () => {
  // The breadth check without a DOM.
  //
  // There used to be a 233-line CSS subject parser behind this table: it found
  // the subject compound, broke it into simple selectors, and decided whether
  // anything in it *narrowed*, so that `:is(body)`, `body.dark` and
  // `body:not(#nope)` were caught as the page-blankers they are. The platform
  // answers that question exactly — `RegionResolver` rejects any candidate whose
  // match set contains `<html>` or `<body>` — so those cases moved to
  // `ops.test.ts`, where there is a document to ask and where the answer is the
  // browser's rather than an approximation of it. Two spellings the parser
  // provably could not catch went with them.
  //
  // What is left here is what has to hold at `document-start`, where `body` is
  // null and nothing resolves: the literal spellings a typo or an old build
  // produces — a port of Swift's `pageRoots` — and a universal subject, which is
  // "every box this thing has" however narrow the thing is.
  const unbounded = [
    "*",
    "html",
    "body",
    ":root",
    ":scope",
    "BODY",
    // A universal subject narrows nothing: on `<body>` these are the page.
    "body > *",
    "#feed *",
    "body *:not(script)",
    // A selector list smuggles a second, broader subject into a rule authored for
    // the first — the reason `,` is a region-only ban.
    ":is(main, body)",
    "#feed, body",
    "a, b",
  ];

  for (const value of unbounded) {
    it(`refuses ${value} as a region`, () => {
      // `hide` on `html` is otherwise a perfectly legal lens that blanks every
      // visit to a site — §1's no-flash rule inverted into a permanent one.
      expect(safeRegionSelector(value)).toBeUndefined();
    });
  }

  const narrow = [
    "article",
    "#secondary",
    ".sidebar",
    "[data-testid=rail]",
    "body > article.post",
    "body>div:nth-of-type(2)>article",
    ":scope > li",
    // `:is()` resolving to something narrow is narrow: this is the half a blanket
    // ban on `:is` would have broken.
    ":is(.card)",
    "#feed:has(> .ad)",
    'div[data-x="a>b"]',
    // Tailwind. A blanket ban on `\` rejected every one of these.
    ".md\\:flex",
  ];

  for (const value of narrow) {
    it(`keeps ${value} as a region`, () => {
      expect(safeRegionSelector(value)).toBe(value);
    });
  }
});

describe("the breadth limit is a region rule", () => {
  it("leaves item and field selectors alone", () => {
    // Matched inside one element, so `:scope` is the narrowest subject there is
    // rather than the broadest. Banning it everywhere would silently disable every
    // filter, reorder and harvest ever written.
    expect(safeSelector(":scope")).toBe(":scope");
    expect(safeItemSelector(":scope > li")).toBe(":scope > li");
    expect(safeRegionSelector(":scope > li")).toBe(":scope > li");
  });

  it("bans a comma in a region and in an item, and allows it in a field", () => {
    // Three rules, three reasons. A region is one thing. An item selector the
    // runner cannot use falls back to the region's own children, so a list handed
    // to it is a list it silently does not use — A1.2. A field is read inside one
    // card, where `h3, .title` is how a real feed is marked up.
    expect(safeRegionSelector("#feed, body")).toBeUndefined();
    expect(safeItemSelector(".card, .row")).toBeUndefined();
    expect(safeSelector("h3, .title")).toBe("h3, .title");
  });
});

describe("safeSelector", () => {
  const hostile = [
    "#a{color:red}",
    "#a;#b",
    "#a/*x*/",
    "@media",
    "a[href^='javascript:']url(x)",
    // Unbalanced: `#secondary:has(` compiles to `#secondary:has( { … }` and per
    // CSS Syntax §5.4.8 the unclosed block swallows every rule after it to the end
    // of the sheet — while the structural pass still reports those ops `applied`.
    "#secondary:has(",
    'div[a="',
    // A unicode escape reconstructing `url(` past a literal search.
    "\\75 rl(",
    // A `\` at the very end takes its digits from whatever follows.
    "#a\\",
    // Not a function call — CSS reads `\(` as a literal character — but a check
    // one backslash steps around is a check nobody can reason about.
    "expression\\(x)",
  ];

  for (const value of hostile) {
    it(`refuses ${JSON.stringify(value)}`, () => {
      expect(safeSelector(value)).toBeUndefined();
    });
  }

  it("keeps a class that only looks like a banned function", () => {
    // `expression(` is banned as a call, not as a substring: the raw ban also
    // rejected `.expression-editor`, an ordinary class on an ordinary page, and a
    // validator that fails on legitimate markup gets loosened by whoever hits it.
    expect(safeSelector(".expression-editor")).toBe(".expression-editor");
  });
});
