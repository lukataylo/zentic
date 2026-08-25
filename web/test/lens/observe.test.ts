import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { DEFAULT_ENGINE_OPTIONS, LensEngine } from "../../src/lens/index.js";
import { LensObservers } from "../../src/lens/observe.js";
import type { Lens } from "../../src/wire.js";

// Feeds are the reason lenses need observers at all: a filter that only runs at
// DOM ready is a filter that stops working the moment the user scrolls, which
// reads as a broken lens rather than a busy one.
//
// The two failure modes worth testing are both about the observer's relationship
// with itself. It watches a subtree it also mutates, so without a guard it
// schedules itself forever; and it watches something that can change thousands of
// times a minute, so without a cap it owns the main thread.

/** Mutation records are delivered as a microtask, so a pass needs the microtask
 * queue drained before its debounce timer can be advanced. */
const flush = async () => {
  await Promise.resolve();
  await Promise.resolve();
};

describe("LensObservers", () => {
  let feed: Element;
  let runs: Element[];
  let observers: LensObservers;

  beforeEach(() => {
    vi.useFakeTimers();
    document.body.innerHTML = `<ul id="feed"><li>first</li></ul>`;
    feed = document.querySelector("#feed")!;
    runs = [];
  });

  afterEach(() => {
    observers?.disconnectAll();
    vi.useRealTimers();
  });

  const watch = (
    budget = { debounceMs: 80, maxPassesPerSecond: 8 },
    now?: () => number,
  ): LensObservers => {
    observers = now
      ? new LensObservers(budget, (target) => runs.push(target), now)
      : new LensObservers(budget, (target) => runs.push(target));
    observers.watch(feed);
    return observers;
  };

  const append = (text = "next") => {
    const item = document.createElement("li");
    item.textContent = text;
    feed.appendChild(item);
  };

  it("re-runs the live ops when the feed grows", async () => {
    watch();

    append();
    await flush();
    // Debounced: infinite scroll appends in bursts, and one pass per card would
    // be one pass per frame.
    expect(runs).toHaveLength(0);

    vi.advanceTimersByTime(80);
    expect(runs).toEqual([feed]);
  });

  it("coalesces a burst into one pass", async () => {
    watch();

    append("a");
    append("b");
    append("c");
    await flush();
    vi.advanceTimersByTime(80);

    expect(runs).toHaveLength(1);
  });

  it("does not schedule a pass for our own nodes", async () => {
    watch();

    feed.appendChild(document.createElement("zentic-lens-label"));
    await flush();
    vi.advanceTimersByTime(1000);

    expect(runs).toHaveLength(0);
  });

  it("does not loop when its own pass mutates what it is watching", async () => {
    // The crux. Our mutations are delivered after the pass returns, so a "busy"
    // flag would already be false; `takeRecords()` consumes them instead.
    observers = new LensObservers({ debounceMs: 10, maxPassesPerSecond: 8 }, (target) => {
      runs.push(target);
      const item = document.createElement("li");
      item.textContent = "added by the pass";
      target.appendChild(item);
    });
    observers.watch(feed);

    append();
    await flush();
    vi.advanceTimersByTime(10);
    expect(runs).toHaveLength(1);

    // Nothing else touched the page, so nothing else should run.
    await flush();
    vi.advanceTimersByTime(5000);
    await flush();
    vi.advanceTimersByTime(5000);
    expect(runs).toHaveLength(1);
  });

  it("holds the passes-per-second cap, and defers rather than drops", async () => {
    let clock = 0;
    watch({ debounceMs: 1, maxPassesPerSecond: 2 }, () => clock);

    for (let index = 0; index < 3; index += 1) {
      append(`burst ${index}`);
      await flush();
      vi.advanceTimersByTime(1);
    }

    // The third pass is over the cap for this window.
    expect(runs).toHaveLength(2);

    // Still capped while the window has not moved: waiting is the point.
    vi.advanceTimersByTime(1000);
    expect(runs).toHaveLength(2);

    // A deferred pass is not a dropped one — the cards it would have filtered are
    // still on the page, so it has to arrive eventually.
    clock = 1500;
    vi.advanceTimersByTime(1000);
    expect(runs).toHaveLength(3);
  });

  it("does not ping-pong between nested watched regions", async () => {
    // Regions nest — a feed inside a column, a column inside a main — and every
    // watch is `subtree: true`, so an ancestor sees every mutation a descendant's
    // pass makes. Draining only the watch that fired left those records queued:
    // our own work woke the ancestor, whose pass touched the descendant, whose
    // observer had not been drained either. Two regions, one card appended, and
    // the page then ran passes at the rate cap until the tab closed.
    //
    // Every other test in this file watches exactly one region, which is
    // precisely why this was invisible.
    document.body.innerHTML = `<div id="outer"><ul id="inner"><li>first</li></ul></div>`;
    const outer = document.querySelector("#outer")!;
    const inner = document.querySelector("#inner")!;

    // A lens whose live ops on both regions land on the same rows — one `filter`
    // on the list and one `reorder` on the column that holds it.
    observers = new LensObservers({ debounceMs: 10, maxPassesPerSecond: 8 }, (target) => {
      runs.push(target);
      inner.appendChild(document.createElement("li"));
    });
    observers.watch(outer);
    observers.watch(inner);

    inner.appendChild(document.createElement("li"));
    await flush();
    vi.advanceTimersByTime(10);

    // Both regions genuinely changed, so both re-run once. What must not happen
    // is a third pass, caused by nothing but the first two.
    const settled = runs.length;
    expect(settled).toBeLessThanOrEqual(2);

    for (let index = 0; index < 5; index += 1) {
      await flush();
      vi.advanceTimersByTime(1000);
    }
    expect(runs).toHaveLength(settled);
  });

  it("does not drain a sibling region's mutations along with its own", async () => {
    // The other half of the drain. Consuming our own records before they can be
    // delivered is what stops a pass scheduling itself forever — but doing it to
    // *every* watch threw the page's work away with ours, and a region that
    // changed while this pass ran was never looked at again. On an infinite feed
    // that self-corrects, because another card is along in a moment. For a column
    // that updates once it is permanent, and the lens simply never applies there.
    //
    // A site reacting synchronously to our pass is ordinary rather than exotic:
    // moving a card runs the custom element's `connectedCallback` on the spot.
    document.body.innerHTML = `<ul id="left"><li>a</li></ul><ul id="right"><li>b</li></ul>`;
    const left = document.querySelector("#left")!;
    const right = document.querySelector("#right")!;

    let reacted = false;
    observers = new LensObservers({ debounceMs: 10, maxPassesPerSecond: 8 }, (target) => {
      runs.push(target);
      if (target !== left || reacted) return;
      reacted = true;
      // The site's own code, updating the other column because ours moved.
      right.appendChild(document.createElement("li"));
    });
    observers.watch(left);
    observers.watch(right);

    left.appendChild(document.createElement("li"));
    await flush();
    vi.advanceTimersByTime(10);
    expect(runs).toEqual([left]);

    // The right column genuinely changed, so its ops have to re-run.
    await flush();
    vi.advanceTimersByTime(10);
    expect(runs).toEqual([left, right]);

    // And it settles: nothing mutated the page after that, so nothing runs again.
    for (let index = 0; index < 3; index += 1) {
      await flush();
      vi.advanceTimersByTime(1000);
    }
    expect(runs).toHaveLength(2);
  });

  it("keeps the rate window when the watches are torn down", async () => {
    // `disconnectAll()` runs on every same-document navigation, and the cap it
    // used to clear is a budget on this second of this tab's main thread. A
    // router that navigates on every click could therefore buy itself unlimited
    // quota simply by navigating.
    let clock = 0;
    watch({ debounceMs: 1, maxPassesPerSecond: 2 }, () => clock);

    for (let index = 0; index < 2; index += 1) {
      append(`burst ${index}`);
      await flush();
      vi.advanceTimersByTime(1);
    }
    expect(runs).toHaveLength(2);

    observers.disconnectAll();
    observers.watch(feed);

    append("after the navigation");
    await flush();
    vi.advanceTimersByTime(1);

    // Still the same second, so still no quota.
    expect(runs).toHaveLength(2);

    clock = 1500;
    vi.advanceTimersByTime(1000);
    expect(runs).toHaveLength(3);
  });

  it("watches one region once, however many ops name it", () => {
    watch();
    observers.watch(feed);

    expect(observers.count).toBe(1);
  });

  it("stops on disconnect, so a cleared lens leaves nothing running", async () => {
    watch();
    observers.disconnectAll();

    append();
    await flush();
    vi.advanceTimersByTime(1000);

    expect(runs).toHaveLength(0);
    expect(observers.count).toBe(0);
  });
});

describe("LensEngine live regions", () => {
  const feedLens = (): Lens => ({
    id: "lens-live",
    name: "No ads",
    origin: location.host,
    pathPattern: "*",
    isEnabled: true,
    prompt: "hide the sponsored posts",
    regions: [{ id: "feed", intent: "the timeline", selectors: ["#feed"] }],
    ops: [
      {
        id: "op-1",
        kind: "filter",
        region: "feed",
        note: "drop sponsored posts",
        itemSelector: ":scope > li",
        filterMode: "drop",
        predicate: { terms: ["sponsored"], matchMode: "any", field: "text" },
      },
    ],
    createdAt: "2026-01-01T00:00:00Z",
    updatedAt: "2026-01-01T00:00:00Z",
    schemaVersion: 1,
  });

  beforeEach(() => {
    vi.useFakeTimers();
    document.body.innerHTML = `<ul id="feed"><li>Sponsored: a thing</li><li>A real post</li></ul>`;
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("keeps filtering as the feed grows, then gives the page back on clear", async () => {
    const before = document.body.innerHTML;
    const engine = new LensEngine(document, DEFAULT_ENGINE_OPTIONS);
    engine.setLenses([feedLens()]);

    const reports = engine.runPass();
    expect(reports[0]?.results[0]?.status).toBe("applied");
    expect(document.querySelectorAll("[data-zentic-lens-hidden]")).toHaveLength(1);

    const grown = document.createElement("li");
    grown.textContent = "Sponsored: another thing";
    document.querySelector("#feed")!.appendChild(grown);

    await flush();
    vi.advanceTimersByTime(DEFAULT_ENGINE_OPTIONS.observer.debounceMs);

    expect(grown.hasAttribute("data-zentic-lens-hidden")).toBe(true);

    engine.clear();
    grown.remove();

    expect(document.body.innerHTML).toBe(before);
    expect(document.getElementById("zentic-lens-style")).toBeNull();
  });

  it("resolves each live region once per observer callback, not once per op", async () => {
    // The measured version of this used to assert `<= ops.length + 1`, a bound
    // eight times the truth that passed against every implementation anyone
    // could write. An exact set of selectors is the only form of this assertion
    // that can fail.
    //
    // The implementation it was supposed to be watching resolved a region by
    // constructing a whole `RegionResolver` **per region**, on every callback:
    // `liveRegions()` built one, and `runStructuralOps` built another. Twelve
    // lenses of forty ops is 480 regions of up to eight candidates — 4,208
    // whole-document `querySelectorAll` calls per callback, 33,664 a second at
    // the rate cap, none of it inside `passCeilingMs`.
    //
    // Measured on that shape — twelve lenses of forty ops over forty feeds, each
    // region carrying seven dead candidates ahead of the live one — the callback
    // ran 3,925 whole-document queries. It now runs 85, and none of them is a
    // region the observer did not fire about.
    document.body.innerHTML = `
      <ul id="feed"><li>Sponsored: a thing</li><li>A real post</li></ul>
      <ul id="rail"><li>Sponsored: a rail ad</li><li>A real link</li></ul>
    `;

    const base = feedLens();
    const filter = base.ops[0]!;
    const many: Lens = {
      ...base,
      regions: [
        { id: "feed", intent: "the timeline", selectors: ["#feed"] },
        { id: "rail", intent: "the sidebar", selectors: ["#rail"] },
      ],
      // Four ops on each of two regions, every one of which runs — the cost this
      // is watching is per *region* resolved, not per op.
      ops: Array.from({ length: 8 }, (_, index) => ({
        ...filter,
        id: `op-${index}`,
        region: index % 2 === 0 ? "feed" : "rail",
      })),
    };

    const engine = new LensEngine(document, DEFAULT_ENGINE_OPTIONS);
    engine.setLenses([many]);
    engine.runPass();

    const resolves = vi.spyOn(document, "querySelectorAll");
    const grown = document.createElement("li");
    grown.textContent = "Sponsored: another thing";
    document.querySelector("#feed")!.appendChild(grown);

    await flush();
    vi.advanceTimersByTime(DEFAULT_ENGINE_OPTIONS.observer.debounceMs);
    expect(grown.hasAttribute("data-zentic-lens-hidden")).toBe(true);

    // One document-wide query, for the one region the observer fired about. The
    // rail is screened out by `Element.matches()` without the document being
    // touched, and the op runner that follows shares the answer rather than
    // resolving `#feed` a second time.
    expect(resolves.mock.calls.map((call) => call[0])).toEqual(["#feed"]);

    resolves.mockRestore();
    engine.clear();
  });

  it("posts no report and builds no stylesheet when no lens applies", () => {
    // Nearly every page. `setLenses([])` still compiled, still appended a
    // `<style>` element to `documentElement` and still handed the app an empty
    // report to cross the bridge with — a style recalculation and a node the
    // page's own script can see, bought on every load of every unlensed page.
    const posted: unknown[] = [];
    const engine = new LensEngine(document, DEFAULT_ENGINE_OPTIONS, {
      onReport: (reports) => posted.push(reports),
    });

    engine.setLenses([]);
    expect(document.getElementById("zentic-lens-style")).toBeNull();

    expect(engine.runPass()).toEqual([]);
    expect(document.getElementById("zentic-lens-style")).toBeNull();

    vi.advanceTimersByTime(5000);
    expect(posted).toHaveLength(0);

    engine.clear();
  });

  it("stops writing the sheet when the compile produced the same bytes", () => {
    // Assigning `textContent` invalidates style for the whole document whether or
    // not a byte moved, and on a page whose router navigates within itself the
    // common case is that no byte moves: the same lenses compile to the same
    // sheet on every SPA navigation and every re-fit.
    const engine = new LensEngine(document, DEFAULT_ENGINE_OPTIONS);
    engine.setLenses([feedLens()]);

    const style = document.getElementById("zentic-lens-style")!;
    let writes = 0;
    const original = Object.getOwnPropertyDescriptor(Node.prototype, "textContent")!;
    Object.defineProperty(style, "textContent", {
      configurable: true,
      get: () => original.get!.call(style),
      set: (value) => {
        writes += 1;
        original.set!.call(style, value);
      },
    });

    engine.injectStylesheet();
    engine.injectStylesheet();

    expect(writes).toBe(0);

    engine.clear();
  });
});
