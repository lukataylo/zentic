import { describe, expect, it, vi } from "vitest";

import { WIRE_VERSION } from "../src/wire.js";

// The cookie-wall dismissal is the strip layer's job and it is not what is under
// test here. Left real, autoconsent schedules an undo-prehide timer that fires
// after the environment has been torn down and reports as a test-run error.
vi.mock("../src/consent.js", () => ({
  dismissConsent: () => Promise.resolve("unavailable"),
}));

// What a page with no lenses costs.
//
// The engine is built on every page — ⌥⌘L needs its region catalog — but a page
// with no lens on it must not be driven: `setLenses([])` and a pass over an empty
// set resolve nothing and query nothing, yet each still appends a `<style>` to
// `documentElement` and posts an empty report over the bridge. That is bought on
// nearly every page load, and it regresses silently.

interface Post {
  type: string;
}

/**
 * Run `main.ts` against this document with a given lens set, and collect
 * everything it posts over the bridge.
 *
 * The reader declines the page — a lens's primary path is a page we do not
 * restructure — so nothing here is about extraction.
 */
async function boot(lenses: unknown[]): Promise<Post[]> {
  const posts: Post[] = [];
  const global = globalThis as unknown as Record<string, unknown>;

  global.webkit = {
    messageHandlers: {
      zentic: {
        postMessage: (body: unknown) => {
          posts.push(JSON.parse(String(body)) as Post);
        },
      },
    },
  };
  global.__zenticConfig = {
    mode: "original",
    passthroughOrigins: [],
    revealFailsafeMs: 1500,
    settleQuietPeriodMs: 20,
    settleCeilingMs: 50,
    skeletonNodeLimit: 100,
    lenses,
    debugLogging: false,
  };

  vi.resetModules();
  await import("../src/main.js");
  // `main` runs its lens pass from `whenReady`, and the document is already
  // complete under vitest, so the pass has run by the time the import resolves.
  return posts;
}

function styleNode(): Element | null {
  return document.getElementById("zentic-lens-style");
}

describe("a page with no lenses", () => {
  it("puts nothing in the document and says nothing over the bridge", async () => {
    document.body.innerHTML = `<div id="rail">rail</div>`;

    const posts = await boot([]);

    // A `<style>` on `documentElement` is a style recalc and a node the page's
    // own script can see, bought on every load of nearly every page.
    expect(styleNode()).toBeNull();
    // `lensReport: []` is a bridge crossing that changes no number in the app:
    // reports are keyed by lens id and dropped per navigation already.
    expect(posts.map((post) => post.type)).not.toContain("lensReport");
    // The page still reports that the bundle ran. "No lenses" must stay
    // distinguishable from "no bundle".
    expect(posts.map((post) => post.type)).toContain("ready");
  }, 30_000);

  it("still starts the engine the moment a lens arrives", async () => {
    document.body.innerHTML = `<div id="rail">rail</div>`;
    await boot([]);
    expect(styleNode()).toBeNull();

    const lens = {
      id: "lens-1",
      name: "Focus",
      origin: location.host,
      pathPattern: "*",
      isEnabled: true,
      prompt: "hide the rail",
      regions: [{ id: "rail", intent: "the rail", selectors: ["#rail"] }],
      ops: [{ id: "op-1", kind: "hide", region: "rail", note: "hide the rail" }],
      createdAt: "2026-01-01T00:00:00Z",
      updatedAt: "2026-01-01T00:00:00Z",
      schemaVersion: 1,
    };

    const zentic = (globalThis as unknown as { __zentic: { receive(json: string): Promise<void> } })
      .__zentic;
    await zentic.receive(JSON.stringify({ v: WIRE_VERSION, type: "applyLenses", payload: [lens] }));

    // The guard is a guard, not a removal: the first lens to arrive over the
    // wire gets the same engine every other lens gets.
    expect(styleNode()).not.toBeNull();
    expect(styleNode()?.textContent).toContain("#rail");
  }, 30_000);
});
