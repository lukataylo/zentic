import { beforeEach, describe, expect, it } from "vitest";
import { validate } from "../src/validate";
import { reset } from "./helpers";

describe("validate()", () => {
  beforeEach(() =>
    reset(`<body><div id="wrap"><main id="main"><p>${"word ".repeat(200)}</p></main><aside class="rail">Suggested ${"x ".repeat(10)}</aside></div></body>`),
  );

  it("accepts a selector that hides a part", () => {
    expect(validate([".rail"])[0]).toEqual({ selector: ".rail", count: 1, ok: true });
  });

  it("rejects the document itself, bad syntax and rule-breaking characters", () => {
    const [body, html, bad, inject] = validate(["body", "html", "div[", "a{}body{display:none"]);
    expect(body!.ok).toBe(false);
    expect(html!.ok).toBe(false);
    expect(bad!.reason).toBe("invalid selector");
    expect(inject!.reason).toBe("unsafe characters");
  });

  it("rejects selectors that would hide most of the page's text", () => {
    const [wrap, main] = validate(["#wrap", "#main"]);
    expect(wrap!.reason).toBe("hides most of the page");
    expect(main!.reason).toBe("hides most of the page");
  });

  it("reports zero matches as ok — a stale selector no-ops", () => {
    expect(validate([".nope"])[0]).toEqual({ selector: ".nope", count: 0, ok: true });
  });
});
