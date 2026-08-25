import { describe, expect, it, vi } from "vitest";

import { WIRE_VERSION } from "../src/wire.js";

vi.mock("../src/consent.js", () => ({
  dismissConsent: () => Promise.resolve("unavailable"),
}));

// Moving the rail back up to Reader must put the site's page *behind* ours.
//
// The bug this pins: `setMode` concealed the document when the reader came back,
// and `setLevel` did not. Both branches show the same overlay, but only one was
// written after the overlay became translucent — so the rail left the site's own
// page revealed underneath, and the user read our article through their hero
// image and their furniture. ⌘\ was fine; the rail was not.

const HIDDEN_MARK = "data-zentic-hidden";

/** Enough prose, in an article, that extraction will actually restructure it. */
function article(): string {
  const p = Array.from(
    { length: 12 },
    () =>
      `<p>${"The tablet occupies the space between a full-fledged device and a low-distraction one. ".repeat(4)}</p>`,
  ).join("");
  return `<article><h1>A kinder, gentler tablet</h1>${p}</article>`;
}

async function boot(): Promise<(command: unknown) => Promise<void>> {
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
    lenses: [],
    debugLogging: false,
  };
  vi.resetModules();
  await import("../src/main.js");
  const zentic = global.__zentic as { receive(json: string): Promise<void> };
  return (command) => zentic.receive(JSON.stringify(command));
}

const settle = () => new Promise((r) => setTimeout(r, 260));

describe("the rail and ⌘\\ agree about concealment", () => {
  it("puts the site's page back behind ours when the rail returns to Reader", async () => {
    document.documentElement.removeAttribute(HIDDEN_MARK);
    document.documentElement.style.removeProperty("visibility");
    document.body.innerHTML = article();

    const send = await boot();
    await settle();

    // Rendered, and the site's page is behind ours.
    expect(document.getElementById("zentic-reader-root")).not.toBeNull();
    expect(document.documentElement.hasAttribute(HIDDEN_MARK)).toBe(true);

    // Rail down below Reader: the site's own page is what the user wants to see.
    await send({ v: WIRE_VERSION, type: "setLevel", payload: "clean" });
    await settle();
    expect(document.documentElement.hasAttribute(HIDDEN_MARK)).toBe(false);

    // And back up. Without the conceal this is where the artefact appeared: the
    // overlay returns, translucent, over a document still visible underneath.
    await send({ v: WIRE_VERSION, type: "setLevel", payload: "reader" });
    await settle();
    expect(document.documentElement.hasAttribute(HIDDEN_MARK)).toBe(true);
  }, 30_000);
});
