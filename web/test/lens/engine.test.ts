import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  DEFAULT_ENGINE_OPTIONS,
  LensEngine,
  engineOptions,
  lensPathMatches,
  matchingLenses,
} from "../../src/lens/index.js";
import { buildFingerprint } from "../../src/lens/fingerprint.js";
import type { Lens, LensReport, ReaderCommand, ReaderConfiguration } from "../../src/wire.js";

// The engine's decisions, as distinct from the ops it runs.
//
// Which lenses apply, in what order, under which budgets, and what the toolbar is
// told about the result. Every one of these is a way for the feature to be wrong
// without anything looking broken: a lens that never fires and cannot report why,
// a budget that silently stops existing, a badge that describes a page the user is
// not looking at.

/** `web/`, so a test can read the source it is making a claim about. */
const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

const fixtures = join(root, "..", "Tests", "Fixtures", "wire");

function fixture(name: string): unknown {
  return JSON.parse(readFileSync(join(fixtures, `${name}.json`), "utf8"));
}

function lens(overrides: Partial<Lens> = {}): Lens {
  return {
    id: "lens-1",
    name: "Focus",
    origin: "www.example.com",
    pathPattern: "*",
    isEnabled: true,
    prompt: "hide the rail",
    regions: [{ id: "rail", intent: "the sidebar", selectors: ["#rail"] }],
    ops: [{ id: "op-1", kind: "hide", region: "rail", note: "hide the rail" }],
    createdAt: "2026-01-01T00:00:00Z",
    updatedAt: "2026-01-01T00:00:00Z",
    schemaVersion: 1,
    ...overrides,
  };
}

describe("lens path matching", () => {
  // The cases and the answers are Swift's, from
  // `Tests/ZenticKitTests/LensPathContractTests.swift`. Driving both
  // implementations over one table is the only way this stays a port: a
  // divergence produces no `LensReport` at all on the side that filters the lens
  // out, so nothing else in either suite can see it.
  const table = fixture("lens-path-cases") as {
    cases: Array<{ pattern: string; path: string; matches: boolean }>;
  };

  it("agrees with the Swift matcher on every shared case", () => {
    expect(table.cases.length).toBeGreaterThan(10);

    for (const entry of table.cases) {
      expect(
        lensPathMatches(entry.pattern, entry.path),
        `${entry.pattern} vs ${entry.path}`,
      ).toBe(entry.matches);
    }
  });

  it("applies a lens whose pattern generalises the page it was made on", () => {
    // The exact shape that used to be dropped here after Swift had already
    // matched it and sent it down: no ops ran, no report was posted, and the
    // popover had nothing to explain.
    const wildcards = lens({ pathPattern: "/posts/*/*" });
    const matched = matchingLenses(
      [wildcards],
      "https://www.example.com/posts/12345/my-title",
      12,
    );

    expect(matched.map((entry) => entry.id)).toEqual(["lens-1"]);
  });
});

describe("lens stacking order", () => {
  it("stacks by last edit, newest last, so the lens just edited wins", () => {
    // Later wins on the page, so the sequence decides which of two clashing ops
    // the user actually sees. There used to be an explicit `Lens.order`, a
    // drag-to-reorder row to set it, and a path-specificity tie-break underneath
    // — three mechanisms for a question people answer by editing the lens that is
    // not doing what they wanted. "The one I just edited wins" is the rule every
    // other stack of rules they use already follows.
    const old = lens({ id: "b", updatedAt: "2025-01-01T00:00:00Z" });
    const newest = lens({ id: "a", updatedAt: "2026-06-01T00:00:00Z" });
    const middle = lens({ id: "c", updatedAt: "2025-06-01T00:00:00Z" });

    const matched = matchingLenses(
      [newest, middle, old],
      "https://www.example.com/posts/12345",
      12,
    );

    expect(matched.map((entry) => entry.id)).toEqual(["b", "c", "a"]);
  });

  it("keeps the sequence total when two lenses were saved in the same instant", () => {
    // Two lenses saved in the same millisecond must not swap places between one
    // page load and the next: the page resolves a clash by "later wins", so an
    // unstable order is a page that looks different on every visit for no reason
    // the user can see.
    const twins = [
      lens({ id: "d", updatedAt: "2026-01-01T00:00:00Z" }),
      lens({ id: "c", updatedAt: "2026-01-01T00:00:00Z" }),
    ];

    const forwards = matchingLenses(twins, "https://www.example.com/x", 12);
    const backwards = matchingLenses([...twins].reverse(), "https://www.example.com/x", 12);

    expect(forwards.map((entry) => entry.id)).toEqual(["d", "c"]);
    expect(backwards.map((entry) => entry.id)).toEqual(["d", "c"]);
  });

  it("is the exact reverse of the list the store hands over, ties included", () => {
    // Two sorts of one field, pointing opposite ways on purpose: `LensStore`
    // sorts `updatedAt` descending because its list is *read* by a person, and
    // `appliesBefore` sorts it ascending because its list is *applied* and later
    // wins. Deliberate, and both halves document it — which is exactly the shape
    // that produced the path-matcher divergence, where one side matched, shipped
    // the lens down, and the other side silently filtered it out.
    //
    // So the relationship is pinned rather than argued: the page's application
    // order is the store's list, reversed, whole. It used to be reversed only
    // where the timestamps differed — both sides broke a tie on ascending id, so
    // two lenses saved in the same millisecond gave the popover a first row that
    // was not the lens the cascade let stand.
    const sameInstant = "2026-01-01T00:00:00Z";
    const fromTheStore = [
      // `LensStore.newestFirst`, exactly: `updatedAt` descending, ties on
      // ascending id.
      lens({ id: "newer", updatedAt: "2026-06-01T00:00:00Z" }),
      lens({ id: "a", updatedAt: sameInstant }),
      lens({ id: "b", updatedAt: sameInstant }),
    ];

    const applied = matchingLenses(fromTheStore, "https://www.example.com/x", 12);

    expect(applied.map((entry) => entry.id)).toEqual(
      [...fromTheStore].reverse().map((entry) => entry.id),
    );
  });

  it("puts the most recently edited lens's effect on the page", () => {
    // The observable end of the same rule, through the real engine rather than
    // through the comparator. Two lenses move one box to two different places;
    // the box ends up where the lens the user edited last said to put it.
    //
    // The Swift half of this claim is `LensStoreTests.popoverListsTheLensThePageIsShowing`:
    // the same pair, and the same lens at the top of the popover's list. Between
    // the two, "the one I just edited wins" is true of the page and true of what
    // the user is shown, rather than true of each half separately.
    document.body.innerHTML = `
      <aside id="rail">links</aside>
      <ul id="feed"></ul>
      <div id="tray"></div>
    `;

    const stacked = (id: string, updatedAt: string, target: string): Lens =>
      lens({
        id,
        origin: location.host,
        updatedAt,
        regions: [
          { id: "rail", intent: "the suggestions rail", selectors: ["#rail"] },
          { id: "feed", intent: "the timeline", selectors: ["#feed"] },
          { id: "tray", intent: "the tray", selectors: ["#tray"] },
        ],
        ops: [{ id: `${id}-op`, kind: "move", region: "rail", target, note: "move the rail" }],
      });

    const older = stacked("older", "2026-01-01T00:00:00Z", "feed");
    const newer = stacked("newer", "2026-06-01T00:00:00Z", "tray");

    // Handed over newest-edit-*first*, which is the order `LensStore` produces.
    // Pre-sorting the input here would cancel out the very thing under test.
    const engine = new LensEngine(document, DEFAULT_ENGINE_OPTIONS);
    engine.setLenses([newer, older]);
    const reports = engine.runPass();

    expect(document.querySelector("#tray > #rail")).not.toBeNull();
    expect(document.querySelector("#feed > #rail")).toBeNull();
    // Both ops ran. Nothing arbitrated, nothing was reported suppressed by a rule
    // the page never applied — the second move simply happened after the first.
    expect(reports.flatMap((report) => report.results).map((entry) => entry.status)).toEqual([
      "applied",
      "applied",
    ]);

    engine.clear();
  });
});

describe("engineOptions", () => {
  it("is the defaults plus the one setting the bootstrap still carries", () => {
    // The budgets used to arrive in seven `ReaderConfiguration` fields, each read
    // back with its own fallback — and each fallback was a copy of the very
    // compile-time constant the Swift side had sent. Two copies of one number,
    // shipped over a bridge, to arrive at the value the receiver already had. All
    // that is left to read is `debugLogging`, which is a real setting.
    const bare = { debugLogging: false } as ReaderConfiguration;

    expect(engineOptions(bare)).toEqual(DEFAULT_ENGINE_OPTIONS);
  });

  it("carries the debug flag through, which is the only thing it reads", () => {
    const noisy = { debugLogging: true } as ReaderConfiguration;

    expect(engineOptions(noisy).debug).toBe(true);
    // And every budget is still a real number, because a budget that is not one
    // fails permissively: `now() > NaN` is false forever, so a ceiling that keeps
    // a lens from janking a page would simply never trip.
    const options = engineOptions(noisy);
    for (const value of [
      options.ops.passCeilingMs,
      options.ops.maxItemsPerPass,
      options.ops.maxOpsPerLens,
      options.observer.debounceMs,
      options.observer.maxPassesPerSecond,
      options.regionCandidateLimit,
      options.maxLenses,
    ]) {
      expect(Number.isFinite(value)).toBe(true);
    }
  });
});

describe("LensEngine reporting", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    document.body.innerHTML = `<aside id="rail">links</aside>`;
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  const localLens = (overrides: Partial<Lens> = {}) =>
    lens({ origin: location.host, ...overrides });

  it("reports the path only, never the query string", () => {
    // `LensReport` is persisted into `Lenses.json`, which is still there next
    // week. A path says which page a lens ran on; a query string is where the
    // session tokens and the search terms live.
    const engine = new LensEngine(document, DEFAULT_ENGINE_OPTIONS);
    engine.setLenses([localLens()]);

    const [report] = engine.runPass();
    expect(report?.url).toBe(location.pathname);
    expect(report?.url).not.toContain("?");
    expect(report?.url).not.toContain("#");

    engine.clear();
  });

  it("re-appends the stylesheet to the end of head on every pass", () => {
    // `document.head` is null at `document-start`, so the sheet lands as a direct
    // child of `<html>` — the weakest position in the cascade there is. A page rule
    // of equal specificity, `!important` against our `!important`, then wins on
    // order alone, and the lens quietly does nothing on exactly the sites that
    // fight hardest. Setting `textContent` in place left it there for the life of
    // the page.
    const engine = new LensEngine(document, DEFAULT_ENGINE_OPTIONS);
    engine.setLenses([localLens()]);

    const style = document.getElementById("zentic-lens-style")!;
    // Where document-start actually put it, and a page stylesheet arriving after.
    document.documentElement.appendChild(style);
    const theirs = document.createElement("style");
    document.head.appendChild(theirs);

    engine.runPass();

    expect(style.parentNode).toBe(document.head);
    expect(document.head.lastElementChild).toBe(style);

    engine.clear();
    theirs.remove();
  });

  it("claims nothing while the reader is rendered over the page", () => {
    // The ops resolve perfectly well against the hidden original, so the pass
    // would report `1/1, no drift` for a lens whose every effect is invisible.
    // Invariant 8's spirit: never show a number that is not true of the screen.
    let rendered = false;
    const engine = new LensEngine(document, DEFAULT_ENGINE_OPTIONS, {
      isReaderRendered: () => rendered,
    });
    engine.setLenses([localLens()]);

    const [applied] = engine.runPass();
    expect(applied?.results[0]?.status).toBe("applied");

    rendered = true;
    const [suppressed] = engine.runPass();
    expect(suppressed?.results[0]?.status).toBe("skipped");
    expect(suppressed?.results[0]?.message).toContain("original page");
    expect(suppressed?.results.every((entry) => entry.status !== "missed")).toBe(true);

    // And the report still covers every op, so the badge is `0/1` rather than
    // blank — the lens is loaded, it is simply not on screen.
    expect(suppressed?.results).toHaveLength(1);

    engine.clear();
  });

  it("keeps filtering a feed the fingerprint rescued, as the feed grows", async () => {
    // The screen in front of the observer is `couldBe`, and a rescued region
    // matches none of its own selectors — that is what being rescued means. Left
    // to the selectors alone the screen rejects the very element the pass just
    // resolved this region to, so the filter applies once, reports `applied`, and
    // then quietly stops working within a screenful of scrolling. Applied, badged
    // green, and wrong.
    document.body.innerHTML = `
      <div id="page">
        <ul class="timeline" role="feed" data-testid="primaryColumn">
          <li>Sponsored: a thing</li>
          <li>An ordinary post about the saltmarsh</li>
        </ul>
      </div>
    `;
    const timeline = document.querySelector("#page > ul") as Element;
    const print = buildFingerprint(timeline);

    const engine = new LensEngine(document, DEFAULT_ENGINE_OPTIONS);
    engine.setLenses([
      localLens({
        // The id the site shipped last year and renamed in the redesign, which
        // is what leaves the region reachable by nothing but its fingerprint.
        regions: [
          {
            id: "feed",
            intent: "the timeline",
            selectors: ["#timeline-2025"],
            fingerprint: print,
          },
        ],
        ops: [
          {
            id: "op-filter",
            kind: "filter",
            region: "feed",
            note: "drop sponsored posts",
            itemSelector: ":scope > li",
            filterMode: "drop",
            predicate: { terms: ["sponsored"], matchMode: "any", field: "text" },
          },
        ],
      }),
    ]);

    const [first] = engine.runPass();
    expect(first?.results[0]?.status).toBe("applied");
    // Rescued, not merely resolved — otherwise this would be an ordinary filter
    // test wearing a drift story.
    expect(first?.results[0]?.message).toContain("found by its structure");
    expect((timeline.children[0] as Element).hasAttribute("data-zentic-lens-hidden")).toBe(true);

    // The next batch of cards arrives, as it does on any feed worth lensing.
    const later = document.createElement("li");
    later.textContent = "Sponsored: another thing";
    timeline.appendChild(later);

    await Promise.resolve();
    await Promise.resolve();
    vi.advanceTimersByTime(DEFAULT_ENGINE_OPTIONS.observer.debounceMs);

    expect(later.hasAttribute("data-zentic-lens-hidden")).toBe(true);

    engine.clear();
  });

  it("re-posts a whole report when a live pass changes what an op did", async () => {
    // On an infinite feed the DOM-ready report is arbitrarily old. A region that
    // lazy-renders below the fold reports `missed` once and the badge stays amber
    // for the life of the page, while the observer is quietly applying that op on
    // every batch of cards.
    document.body.innerHTML = `<aside id="rail">links</aside><ul id="feed"></ul>`;

    const posted: LensReport[][] = [];
    const engine = new LensEngine(document, DEFAULT_ENGINE_OPTIONS, {
      onReport: (reports) => posted.push(reports),
    });

    const feedLens = localLens({
      regions: [
        { id: "rail", intent: "the sidebar", selectors: ["#rail"] },
        { id: "feed", intent: "the timeline", selectors: ["#feed"] },
      ],
      ops: [
        { id: "op-hide", kind: "hide", region: "rail", note: "hide the rail" },
        {
          id: "op-filter",
          kind: "filter",
          region: "feed",
          note: "drop sponsored posts",
          itemSelector: ":scope > li",
          filterMode: "drop",
          predicate: { terms: ["sponsored"], matchMode: "any", field: "text" },
        },
      ],
    });
    engine.setLenses([feedLens]);

    const [first] = engine.runPass();
    // Nothing has rendered into the feed yet, so the filter honestly misses.
    expect(first?.results.map((entry) => entry.status)).toEqual(["applied", "missed"]);

    // The feed arrives after first paint, as feeds do.
    const feed = document.querySelector("#feed")!;
    const item = document.createElement("li");
    item.textContent = "Sponsored: a thing";
    feed.appendChild(item);

    await Promise.resolve();
    await Promise.resolve();
    vi.advanceTimersByTime(DEFAULT_ENGINE_OPTIONS.observer.debounceMs);
    expect(item.hasAttribute("data-zentic-lens-hidden")).toBe(true);

    // Coalesced: a badge that re-renders on every pass of a scroll burst is the
    // countdown this replaced.
    expect(posted).toHaveLength(0);
    vi.advanceTimersByTime(1000);

    expect(posted).toHaveLength(1);
    const merged = posted[0]?.[0];
    // The re-run op is current, and the op it did not re-run keeps what it said.
    expect(merged?.results.map((entry) => entry.status)).toEqual(["applied", "applied"]);
    expect(merged?.results).toHaveLength(first?.results.length ?? 0);

    engine.clear();
  });

  it("stops posting once the lens set is cleared", () => {
    // A pending report describing lenses that are no longer applied would badge a
    // page for a lens the user just switched off.
    const posted: LensReport[][] = [];
    const engine = new LensEngine(document, DEFAULT_ENGINE_OPTIONS, {
      onReport: (reports) => posted.push(reports),
    });
    engine.setLenses([localLens()]);
    engine.runPass();
    engine.clear();

    vi.advanceTimersByTime(5000);
    expect(posted).toHaveLength(0);
  });
});

// MARK: - W1: every lens command has an engine entry point

/**
 * Who answers each `ReaderCommand`.
 *
 * `satisfies Record<ReaderCommand["type"], …>` is the point: a command added to
 * the wire union fails to compile here until somebody has decided whether the
 * engine is responsible for it — and, if it is, named the method that answers it.
 * The first build's worst defect was not a bug but an absence, `applyLenses`
 * arriving at a dispatcher with no branch while 259 tests passed, and this is the
 * shape of test that would have caught it.
 *
 * `"reader"` means the command belongs to the reader path and the engine has
 * nothing to do with it. Everything else names a method that must exist.
 */
const COMMAND_OWNER = {
  applyRecipe: "reader",
  setMode: "reader",
  requestSkeleton: "reader",
  applyRewrite: "reader",
  discardRewrite: "reader",
  applyTheme: "reader",
  applyDocument: "reader",
  // The lens half. `enterLensMode` and `requestRegions` both need the textless
  // description of the page; `proposeOps` previews a draft by applying it.
  applyLenses: "setLenses",
  enterLensMode: "catalog",
  requestRegions: "catalog",
  exitLensMode: "clear",
  proposeOps: "setLenses",
} satisfies Record<ReaderCommand["type"], "reader" | keyof LensEngine>;

describe("every lens command reaches the engine", () => {
  it("names a real method for each command the engine owns", () => {
    const engine = new LensEngine(document, DEFAULT_ENGINE_OPTIONS);

    for (const [command, owner] of Object.entries(COMMAND_OWNER)) {
      if (owner === "reader") continue;
      expect(
        typeof (engine as unknown as Record<string, unknown>)[owner],
        `${command} names ${owner}, which is not a method on the engine`,
      ).toBe("function");
    }

    engine.clear();
  });

  it("covers every command the wire declares", () => {
    // The compiler checks the union against this table. This checks the table
    // against the fixtures the Swift side is driven from, so a command that
    // exists on the bridge but was never added to the union cannot slip past
    // both.
    const onDisk = readdirSync(fixtures)
      .filter((name) => name.startsWith("command-") && name.endsWith(".json"))
      .map((name) => name.slice("command-".length, -".json".length).split("-")[0]!);

    for (const command of new Set(onDisk)) {
      expect(Object.keys(COMMAND_OWNER), `${command} has a fixture and no owner`).toContain(
        command,
      );
    }
  });

  it("has a branch in the dispatcher for every one of them", () => {
    // The table above proves each command *names* something. It cannot prove the
    // dispatcher ever reaches it: `bridge.onCommand` switches on `command.type`
    // with no `default`, and TypeScript does not require a `switch` over a union
    // to be exhaustive when nothing reads its result. So a command could be added
    // to the wire, given an owner here, encoded by Swift, sent to the page — and
    // fall through the switch in silence. That is `applyLenses` arriving at a
    // dispatcher with no branch, which is the exact shape of the first build's
    // worst defect, and every test in this file passed while it was true.
    const main = readFileSync(join(root, "src", "main.ts"), "utf8");

    for (const command of Object.keys(COMMAND_OWNER)) {
      expect(main, `main.ts has no \`case "${command}"\` — the page would ignore it`).toContain(
        `case "${command}":`,
      );
    }
  });
});

describe("the budgets on both sides of the bridge are one set of numbers", () => {
  it("matches the Swift constants, which no longer travel over the wire", () => {
    // These used to ride down in seven `ReaderConfiguration` fields, so a
    // divergence was a decode away from being caught. Now each side holds its own
    // copy of the same compile-time constant and nothing on the wire compares
    // them — which is cheaper on every pageview and completely silent when the
    // two drift. `Budget.swift` writes this fixture (`LensContractTests`), and
    // this reads it, so the pin is back without the bytes.
    const budgets = fixture("lens-budgets") as Record<string, number>;

    expect({
      lensOpPassCeilingMs: DEFAULT_ENGINE_OPTIONS.ops.passCeilingMs,
      lensMaxItemsPerPass: DEFAULT_ENGINE_OPTIONS.ops.maxItemsPerPass,
      lensMaxOpsPerLens: DEFAULT_ENGINE_OPTIONS.ops.maxOpsPerLens,
      lensObserverDebounceMs: DEFAULT_ENGINE_OPTIONS.observer.debounceMs,
      lensObserverMaxPassesPerSecond: DEFAULT_ENGINE_OPTIONS.observer.maxPassesPerSecond,
      lensRegionCandidateLimit: DEFAULT_ENGINE_OPTIONS.regionCandidateLimit,
      lensMaxLensesPerOrigin: DEFAULT_ENGINE_OPTIONS.maxLenses,
    }).toEqual(budgets);
  });
});

describe("a suppressed op is distinguishable from one that did nothing", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    document.body.innerHTML = `<aside id="rail">links</aside>`;
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("says why it did not run, in words no budget skip uses", () => {
    // Both are `skipped`, and they mean opposite things. One is "your lens is
    // fine, you are looking at our render of the page instead of the page"; the
    // other is "we ran out of frame". A user who cannot tell them apart reads the
    // first as a broken lens and goes looking for something to fix.
    const engine = new LensEngine(document, DEFAULT_ENGINE_OPTIONS, {
      isReaderRendered: () => true,
    });
    engine.setLenses([lens({ origin: location.host })]);

    const [report] = engine.runPass();
    const suppressed = report?.results[0];

    expect(suppressed?.status).toBe("skipped");
    expect(suppressed?.message).toContain("original page");
    expect(suppressed?.message).not.toContain("budget");
    expect(suppressed?.message).not.toContain("ms");
    // And it is not drift: nothing about the site changed, so offering Re-fit
    // would send the user to re-derive selectors that are perfectly good.
    expect(suppressed?.status).not.toBe("missed");

    engine.clear();
  });
});
