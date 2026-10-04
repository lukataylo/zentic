import { describe, expect, it } from "vitest";
import { ScrollTracker } from "../src/scroll";

describe("ScrollTracker", () => {
  it("reports direction flips only past the hysteresis", () => {
    const t = new ScrollTracker();
    expect(t.update(0)).toBeNull();
    expect(t.update(20)).toEqual({ type: "scroll", y: 20, direction: "down" }); // flip + zone 1
    expect(t.update(40)).toEqual({ type: "scroll", y: 40, direction: "down" }); // zone 2
    expect(t.update(300)).toBeNull();
    expect(t.update(295)).toBeNull(); // jitter
    expect(t.update(305)).toBeNull();
    expect(t.update(296)).toEqual({ type: "scroll", y: 296, direction: "up" }); // 305 - 8 crossed
    expect(t.update(200)).toBeNull();
    expect(t.update(205)).toBeNull();
    expect(t.update(209)).toEqual({ type: "scroll", y: 209, direction: "down" });
  });

  it("always reports reaching the top", () => {
    const t = new ScrollTracker();
    t.update(500);
    t.update(100);
    expect(t.update(0)).toEqual({ type: "scroll", y: 0, direction: "up" });
  });
});
