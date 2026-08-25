import { describe, expect, it } from "vitest";

import { atLeast, plan } from "../src/level.js";
import type { PageLevel, ReaderConfiguration } from "../src/wire.js";

// `plan` is the single place the bundle decides what it may do to a page, and it
// is a plain function precisely so it can be tested: `main.ts` calls `main()` on
// import, so importing it to test it would run it against a jsdom document.
//
// The property that matters most is that `hide` has exactly one source. A hidden
// page with no armed failsafe is a permanently blank window — invariant 1 — and
// the way that bug arrives is two places both deciding whether to hide.

function config(level: PageLevel): ReaderConfiguration {
  return { level } as unknown as ReaderConfiguration;
}

describe("plan", () => {
  it("does nothing at all at Original", () => {
    expect(plan(config("original"), true, false)).toEqual({
      hide: false,
      consent: false,
      pipeline: false,
      render: false,
    });
  });

  it("dismisses the cookie wall at Clean, and does nothing else", () => {
    // Consent used to start at Calm, on the reasoning that blocking a request and
    // pressing a button in the user's name are different kinds of thing. The line
    // moved because a consent wall is not the site's own layout — it is the
    // tracking-consent apparatus, so it belongs with what Clean already removes.
    // Everything else at Clean stays untouched: no hiding, no extraction.
    const allowed = plan(config("clean"), true, false);
    expect(allowed.consent).toBe(true);
    expect(allowed.hide).toBe(false);
    expect(allowed.pipeline).toBe(false);
    expect(allowed.render).toBe(false);
  });

  it("presses nothing at Original", () => {
    // The stop that means untouched. Pressing a button is a touch, so this is the
    // one level where a cookie wall is left exactly as the site put it.
    expect(plan(config("original"), true, false).consent).toBe(false);
  });

  it("extracts but never renders or hides at Calm", () => {
    // The pipeline still runs so the app learns this origin's archetype for next
    // time — but the page was never hidden, so putting an overlay up would be a
    // content swap in front of someone already reading.
    expect(plan(config("calm"), true, false)).toEqual({
      hide: false,
      consent: true,
      pipeline: true,
      render: false,
    });
  });

  it("takes the full path at Reader", () => {
    expect(plan(config("reader"), true, false)).toEqual({
      hide: true,
      consent: true,
      pipeline: true,
      render: true,
    });
  });

  it("still runs the pipeline on an instant origin, but does not hide", () => {
    // The learning path: we stopped hiding this origin because it kept declining,
    // and the only way to notice it has started publishing is to keep looking.
    const allowed = plan(config("reader"), true, true);
    expect(allowed.hide).toBe(false);
    expect(allowed.pipeline).toBe(true);
  });

  it("never hides a page it is not eligible to restructure", () => {
    for (const level of ["calm", "reader", "rewritten"] as PageLevel[]) {
      expect(plan(config(level), false, false).hide).toBe(false);
    }
  });

  it("fails closed on a level it does not recognise", () => {
    // Same rule as `isEligible`: anything unrecognised means leave the page alone.
    // A future level added in Swift and not yet here must not hide a document.
    const unknown = { level: "telepathic" } as unknown as ReaderConfiguration;
    expect(plan(unknown, true, false)).toEqual({
      hide: false,
      consent: false,
      pipeline: false,
      render: false,
    });
  });

  // The bug this guards: permissions were computed once, at load. A page that
  // arrived at Calm carried `render: false` for the rest of its life, so raising
  // the level later ran the whole pipeline and then declined to show the result.
  // The label moved and the page did not, which reads as a control that stops
  // working after the first click. `setLevel` recomputes both halves.
  it("re-planning at a higher level grants render", () => {
    const atCalm = plan(config("calm"), true, false);
    expect(atCalm.render).toBe(false);

    // What the setLevel command does: level moves, mode moves with it, re-plan.
    const raised = { level: "reader", mode: "restructured" } as unknown as ReaderConfiguration;
    expect(plan(raised, true, false).render).toBe(true);
  });

  it("re-planning down to Original withdraws consent", () => {
    // Clean keeps it now; Original is where it stops.
    expect(plan(config("reader"), true, false).consent).toBe(true);
    expect(plan(config("clean"), true, false).consent).toBe(true);
    expect(plan(config("original"), true, false).consent).toBe(false);
  });

  it("only ever hides when it also renders", () => {
    // The pairing that keeps invariant 1 honest: hiding a document commits us to
    // showing something, so there must be no combination that hides without a
    // render path behind it.
    for (const level of ["original", "clean", "calm", "reader", "rewritten"] as PageLevel[]) {
      for (const eligible of [true, false]) {
        for (const instant of [true, false]) {
          const allowed = plan(config(level), eligible, instant);
          if (allowed.hide) expect(allowed.render).toBe(true);
        }
      }
    }
  });
});

describe("atLeast", () => {
  it("orders the ladder", () => {
    expect(atLeast("reader", "calm")).toBe(true);
    expect(atLeast("calm", "reader")).toBe(false);
    expect(atLeast("reader", "reader")).toBe(true);
    expect(atLeast("rewritten", "original")).toBe(true);
  });

  it("sorts an unknown level below everything", () => {
    expect(atLeast("nonsense" as PageLevel, "original")).toBe(false);
  });
});
