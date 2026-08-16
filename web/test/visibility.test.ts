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
