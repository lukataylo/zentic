import { describe, expect, it, vi } from "vitest";

import { WIRE_VERSION, type Lens } from "../../src/wire.js";

vi.mock("../../src/consent.js", () => ({
  dismissConsent: () => Promise.resolve("unavailable"),
}));

// A lens's structural ops must run the moment the user asks for the site's own
// page back.
//
// The bug this pins: the engine was asked "is the reader rendered" and answered
// from `ReaderView.isRendered`, which stays true for the life of the document.
// `hide()` sets `display: none` on the overlay host and leaves it mounted, so
// after ⌘\ — or a rail step that does not reload — the engine went on reporting
// every op `skipped, the reader is showing its own render` while the user was
// looking at the site's own page. The CSS half of the lens applied and the
// structural half did not, which is a lens that half-works with no way to tell.
//
// `isCovering` is the reading that answers the question actually being asked,
// and it is the one `VisibilityController` was already using for it.

/** Enough prose, in an article, that extraction will actually restructure it. */
function article(): string {
  const paragraphs = Array.from(
    { length: 12 },
    () =>
      `<p>${"The tablet occupies the space between a full-fledged device and a low-distraction one. ".repeat(4)}</p>`,
  ).join("");
  return `<main id="story"><article><h1>A kinder, gentler tablet</h1>${paragraphs}</article></main>`;
}

/** One structural op, so the assertion is a node in the page rather than a
 * stylesheet rule: a `label` is the cheapest op that leaves a mark. */
function labellingLens(): Lens {
  return {
    id: "lens-label",
    name: "Mark it",
    origin: location.host,
    pathPattern: "*",
    isEnabled: true,
    prompt: "mark the story",
    regions: [{ id: "story", intent: "the article", selectors: ["#story"] }],
    ops: [{ id: "op-label", kind: "label", region: "story", text: "Lensed", note: "mark it" }],
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
    schemaVersion: 1,
  };
}

async function boot(lenses: Lens[]): Promise<(command: unknown) => Promise<void>> {
  const global = globalThis as unknown as Record<string, unknown>;
  global.webkit = { messageHandlers: { zentic: { postMessage: () => {} } } };
  global.__zenticConfig = {
    mode: "restructured",
    level: "reader",
    passthroughOrigins: [],
    revealFailsafeMs: 1500,
    settleQuietPeriodMs: 20,
    settleCeilingMs: 50,
    skeletonNodeLimit: 100,
    lenses,
    debugLogging: false,
  };
  vi.resetModules();
  await import("../../src/main.js");
  const zentic = global.__zentic as { receive(json: string): Promise<void> };
  return (command) => zentic.receive(JSON.stringify(command));
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 260));
const label = () => document.querySelector("zentic-lens-label");

describe("a lens and the reader take turns", () => {
  it("runs the structural ops the moment ⌘\\ gives the page back", async () => {
    document.documentElement.removeAttribute("data-zentic-hidden");
    document.documentElement.style.removeProperty("visibility");
    document.body.innerHTML = article();

    const send = await boot([labellingLens()]);
    await settle();

    // The reader is painting over the page, so the lens is correctly quiet: its
    // ops would act on a document nobody can see.
    expect(document.getElementById("zentic-reader-root")).not.toBeNull();
    expect(label()).toBeNull();

    // ⌘\ — the site's own page, untouched, is what the user is looking at now.
    // This is the moment the lens becomes true of something.
    await send({ v: WIRE_VERSION, type: "setMode", payload: "original" });
    await settle();
    expect(label()).not.toBeNull();
    expect(label()?.textContent).toBe("Lensed");

    // And back: the reader covers the page again and the op is undone rather
    // than left standing on a document that is no longer on screen.
    await send({ v: WIRE_VERSION, type: "setMode", payload: "restructured" });
    await settle();
    expect(label()).toBeNull();
  }, 30_000);

  it("runs them when the rail steps below Reader without a reload", async () => {
    document.documentElement.removeAttribute("data-zentic-hidden");
    document.documentElement.style.removeProperty("visibility");
    document.body.innerHTML = article();

    const send = await boot([labellingLens()]);
    await settle();
    expect(label()).toBeNull();

    await send({ v: WIRE_VERSION, type: "setLevel", payload: "clean" });
    await settle();
    expect(label()).not.toBeNull();
  }, 30_000);
});
