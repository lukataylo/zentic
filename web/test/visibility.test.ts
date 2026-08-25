import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { VisibilityController } from "../src/visibility.js";
import type { RevealPayload } from "../src/wire.js";

// The reveal failsafe is the single most consequential piece of logic in the
// bundle. Everything else degrades gracefully: a bad extraction shows a poor
// reading view, a bad recipe falls back to generic. But a document hidden with
// nothing scheduled to unhide it is a permanently blank window — the browser
// looks broken, and no amount of retrying helps the user.
//
// So these tests are about one property: **the page always becomes visible.**

describe("VisibilityController", () => {
  let reveals: RevealPayload[];
  let controller: VisibilityController;

  const rootVisibility = () => document.documentElement.style.getPropertyValue("visibility");

  beforeEach(() => {
    vi.useFakeTimers();
    document.documentElement.style.removeProperty("visibility");
    document.documentElement.removeAttribute("data-zentic-hidden");
    document.getElementById("zentic-canvas-suppress")?.remove();
    reveals = [];
    controller = new VisibilityController((payload) => reveals.push(payload));
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("hides the document", () => {
    controller.hide(1500);

    expect(controller.isHidden).toBe(true);
    expect(rootVisibility()).toBe("hidden");
  });

  it("sets the hide with !important, to beat a site's own !important rule", () => {
    // Asserted through a spy rather than `getPropertyPriority`, because jsdom
    // silently drops the priority for `visibility` specifically (it keeps it for
    // `color`). Spying on the call tests our intent independently of how
    // faithfully the test DOM models the cascade; that the flag has the intended
    // effect is verified on-device against the M3 corpus.
    //
    // The flag matters because an inline style already beats a normal stylesheet
    // rule — what it does not beat is `html { visibility: visible !important }`,
    // which a site can ship.
    const spy = vi.spyOn(document.documentElement.style, "setProperty");
    controller.hide(1500);

    expect(spy).toHaveBeenCalledWith("visibility", "hidden", "important");
    spy.mockRestore();
  });

  it("reveals unconditionally when the failsafe expires", () => {
    controller.hide(1500);
    expect(reveals).toHaveLength(0);

    vi.advanceTimersByTime(1499);
    expect(reveals).toHaveLength(0);
    expect(controller.isHidden).toBe(true);

    vi.advanceTimersByTime(1);
    expect(reveals).toHaveLength(1);
    expect(reveals[0]?.reason).toBe("failsafe");
    expect(rootVisibility()).toBe("");
    expect(controller.isHidden).toBe(false);
  });

  it("cancels the failsafe once revealed, so there is no second reveal", () => {
    controller.hide(1500);
    controller.reveal("rendered");

    vi.advanceTimersByTime(10_000);

    expect(reveals).toHaveLength(1);
    expect(reveals[0]?.reason).toBe("rendered");
  });

  it("is idempotent — the first reason wins", () => {
    controller.hide(1500);
    controller.reveal("rendered");
    controller.reveal("extractionEmpty");
    controller.reveal("userRequested");

    expect(reveals).toHaveLength(1);
    expect(reveals[0]?.reason).toBe("rendered");
  });

  it("reveals even when it was never hidden, so passthrough still reports", () => {
    // Ineligible pages skip hide() entirely but the app still wants the event, to
    // distinguish "declined" from "bundle never ran".
    controller.reveal("passthrough");

    expect(reveals).toHaveLength(1);
    expect(reveals[0]?.reason).toBe("passthrough");
    expect(rootVisibility()).toBe("");
  });

  it("refuses to hide after revealing", () => {
    controller.reveal("passthrough");
    controller.hide(1500);

    expect(controller.isHidden).toBe(false);
    expect(rootVisibility()).toBe("");
  });

  it("ignores a repeated hide, so the failsafe deadline cannot be extended", () => {
    controller.hide(1000);
    controller.hide(60_000);

    vi.advanceTimersByTime(1000);
    expect(reveals).toHaveLength(1);
  });

  it("reports elapsed time so a rising failsafe rate is visible", () => {
    controller.hide(1500);
    vi.advanceTimersByTime(1500);

    expect(reveals[0]?.elapsedMs).toBeGreaterThanOrEqual(0);
    expect(Number.isFinite(reveals[0]?.elapsedMs)).toBe(true);
  });

  it("still arms the failsafe when the document cannot be hidden", () => {
    // The timer is armed before the style is touched, precisely so this case
    // cannot strand the page. Simulated here by making setProperty throw.
    const setProperty = document.documentElement.style.setProperty;
    document.documentElement.style.setProperty = () => {
      throw new Error("no style for you");
    };

    try {
      expect(() => controller.hide(1500)).not.toThrow();
      expect(controller.isHidden).toBe(false);

      vi.advanceTimersByTime(1500);
      expect(reveals).toHaveLength(1);
    } finally {
      document.documentElement.style.setProperty = setProperty;
    }
  });

  it("gives an SPA navigation a fresh cycle without leaking the old timer", () => {
    controller.hide(1500);
    const next = controller.restartedForNavigation();

    // The previous timer must not fire a reveal against the new cycle.
    vi.advanceTimersByTime(10_000);
    expect(reveals).toHaveLength(0);

    next.hide(1500);
    vi.advanceTimersByTime(1500);
    expect(reveals).toHaveLength(1);
    expect(reveals[0]?.reason).toBe("failsafe");
  });

  // On a slow page the failsafe fires while the pipeline is still working, and the
  // pipeline then renders anyway — the reader overlay is opaque and covers the
  // viewport, so it lands on top of the already-revealed original. The app decides
  // whether the page can be switched back to the original from the reveal reason,
  // so being told only "failsafe" left the mode toggle disabled on a page that had
  // in fact been restructured.
  it("reports a render that lands after the failsafe already revealed", () => {
    controller.hide(1500);
    vi.advanceTimersByTime(1500);
    expect(reveals.map((r) => r.reason)).toEqual(["failsafe"]);

    controller.settle("rendered");

    expect(reveals.map((r) => r.reason)).toEqual(["failsafe", "rendered"]);
  });

  it("does not repeat an outcome that matches what was already reported", () => {
    controller.hide(1500);
    controller.settle("rendered");
    controller.settle("rendered");

    expect(reveals.map((r) => r.reason)).toEqual(["rendered"]);
  });

  it("settle reveals normally when the failsafe has not fired", () => {
    controller.hide(1500);
    controller.settle("rendered");

    expect(rootVisibility()).toBe("");
    expect(reveals.map((r) => r.reason)).toEqual(["rendered"]);
  });
});

// The reader's overlay is translucent, so the original document can no longer be
// revealed underneath it — its text and images would bleed through the reading
// view. It therefore stays hidden for exactly as long as the overlay is confirmed
// to be covering the viewport, and not one moment longer.
//
// That trades one guarantee for another, so these tests are about the same single
// property as the block above: **the page always becomes visible.** Concealment is
// only ever entered with a watchdog already running, and every way out of it —
// every reveal reason, ⌘\, a cleared overlay, a host the page tore out of the DOM —
// ends with the document on screen.

describe("VisibilityController concealment", () => {
  let reveals: RevealPayload[];
  let covering: boolean;

  const rootVisibility = () => document.documentElement.style.getPropertyValue("visibility");
  const canvasStyle = () => document.getElementById("zentic-canvas-suppress");

  const build = () =>
    new VisibilityController(
      (payload) => reveals.push(payload),
      () => covering,
    );

  beforeEach(() => {
    vi.useFakeTimers();
    document.documentElement.style.removeProperty("visibility");
    document.documentElement.removeAttribute("data-zentic-hidden");
    canvasStyle()?.remove();
    reveals = [];
    covering = true;
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("keeps the original hidden while the reader is rendered over it", () => {
    const controller = build();
    controller.hide(1500);
    controller.reveal("rendered");

    // The app is still told the page is up — the reveal event is about the
    // reader being on screen, not about `<html>` losing an inline style.
    expect(reveals).toHaveLength(1);
    expect(reveals[0]?.reason).toBe("rendered");
    expect(rootVisibility()).toBe("hidden");
    expect(controller.isHidden).toBe(true);
  });

  it("stops the original painting the canvas, which visibility:hidden does not", () => {
    // A `background-color` on `<html>` or `<body>` is propagated to the canvas and
    // painted by the viewport rather than by the hidden box, so a site's white
    // would still fill the window behind a translucent reader.
    const controller = build();
    controller.hide(1500);

    expect(canvasStyle()?.textContent).toContain("transparent");

    controller.reveal("passthrough");
    expect(canvasStyle()).toBeNull();
  });

  it("reveals when the reader did not end up covering the viewport", () => {
    covering = false;
    const controller = build();
    controller.hide(1500);
    controller.reveal("rendered");

    expect(rootVisibility()).toBe("");
    expect(controller.isHidden).toBe(false);
  });

  it.each(["passthrough", "extractionEmpty", "failsafe", "userRequested"] as const)(
    "reveals on %s even with the overlay up",
    (reason) => {
      const controller = build();
      controller.hide(1500);
      controller.reveal(reason);

      expect(rootVisibility()).toBe("");
      expect(canvasStyle()).toBeNull();
      expect(reveals[0]?.reason).toBe(reason);
    },
  );

  it("still reveals on the failsafe when the pipeline never finishes", () => {
    const controller = build();
    controller.hide(1500);

    vi.advanceTimersByTime(1500);

    expect(reveals).toHaveLength(1);
    expect(reveals[0]?.reason).toBe("failsafe");
    expect(rootVisibility()).toBe("");
  });

  it("reveals for ⌘\\, after the reader already revealed as rendered", () => {
    // `setMode("original")` hides the overlay and calls `reveal("userRequested")`
    // on a controller that has already revealed. That second call is what puts the
    // site's own page back on screen, so it cannot be a no-op.
    const controller = build();
    controller.hide(1500);
    controller.reveal("rendered");
    expect(rootVisibility()).toBe("hidden");

    covering = false;
    controller.reveal("userRequested");

    expect(rootVisibility()).toBe("");
    expect(canvasStyle()).toBeNull();
    // Still one reveal event: the first reason wins, as it always did.
    expect(reveals).toHaveLength(1);
    expect(reveals[0]?.reason).toBe("rendered");
  });

  it("puts the original back behind the reader when ⌘\\ is pressed again", () => {
    const controller = build();
    controller.hide(1500);
    controller.reveal("rendered");
    covering = false;
    controller.reveal("userRequested");

    covering = true;
    controller.conceal();

    expect(rootVisibility()).toBe("hidden");
    expect(canvasStyle()).not.toBeNull();
  });

  it("refuses to conceal a page the reader is not covering", () => {
    covering = false;
    const controller = build();
    controller.conceal();

    expect(rootVisibility()).toBe("");
    expect(canvasStyle()).toBeNull();
  });

  it("reveals the moment the overlay stops covering, with no reveal call at all", () => {
    // The page's own script can remove our host — an SPA rewriting `body.innerHTML`
    // does exactly that. Nothing calls `reveal()` on that path, so the watchdog is
    // the only thing standing between the user and a blank window.
    const controller = build();
    controller.hide(1500);
    controller.reveal("rendered");
    expect(rootVisibility()).toBe("hidden");

    covering = false;
    vi.advanceTimersByTime(500);

    expect(rootVisibility()).toBe("");
    expect(canvasStyle()).toBeNull();
    expect(controller.isHidden).toBe(false);
  });

  it("reveals rather than conceal when the watchdog cannot be armed", () => {
    // Same ordering rule as `hide()`: nothing is hidden until the thing that will
    // unhide it is already running.
    const setInterval = globalThis.setInterval;
    (globalThis as { setInterval: unknown }).setInterval = () => {
      throw new Error("no timers for you");
    };

    try {
      const controller = build();
      controller.hide(1500);
      controller.reveal("rendered");

      expect(rootVisibility()).toBe("");
    } finally {
      (globalThis as { setInterval: unknown }).setInterval = setInterval;
    }
  });

  it("does not leave the previous cycle's watchdog running across an SPA navigation", () => {
    const controller = build();
    controller.hide(1500);
    controller.reveal("rendered");

    const next = controller.restartedForNavigation();
    // The new cycle re-hides for its own extraction, under its own failsafe.
    next.hide(1500);
    covering = false;

    // The old watchdog must not be the thing that reveals this cycle's page…
    vi.advanceTimersByTime(1000);
    expect(reveals).toHaveLength(1);
    expect(rootVisibility()).toBe("hidden");

    // …the new failsafe is.
    vi.advanceTimersByTime(500);
    expect(reveals).toHaveLength(2);
    expect(reveals[1]?.reason).toBe("failsafe");
    expect(rootVisibility()).toBe("");
  });

  it("carries the coverage predicate into the next cycle", () => {
    const controller = build();
    const next = controller.restartedForNavigation();
    next.hide(1500);
    next.reveal("rendered");

    expect(rootVisibility()).toBe("hidden");
  });

  it("reveals a document a later cycle hid, even if this cycle never hid it", () => {
    // `hide()` can fail — an exotic document, a detached root — and the failsafe
    // it armed first is then the only thing that runs. If a *previous* cycle left
    // the document concealed, that reveal has to release it anyway, so the release
    // is driven by a mark on the document rather than by one controller's memory.
    const first = build();
    first.hide(1500);
    first.reveal("rendered");
    expect(rootVisibility()).toBe("hidden");

    const second = first.restartedForNavigation();
    covering = false;
    second.reveal("failsafe");

    expect(rootVisibility()).toBe("");
  });

  it("leaves a visibility style the site set on its own root alone", () => {
    // The release is unconditional in effect but not indiscriminate: it only
    // removes an inline `visibility` that the reader itself put there.
    document.documentElement.style.setProperty("visibility", "collapse");

    const controller = build();
    controller.reveal("passthrough");

    expect(rootVisibility()).toBe("collapse");
    document.documentElement.style.removeProperty("visibility");
  });
});
