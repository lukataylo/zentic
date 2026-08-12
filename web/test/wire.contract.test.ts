import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

import {
  isRewritable,
  WIRE_VERSION,
  type ReaderConfiguration,
  type ReaderEvent,
  type SectionKind,
} from "../src/wire.js";

// The other half of the bridge contract. Swift asserts it *encodes* to these
// fixtures (Tests/ZenticKitTests/WireContractTests.swift); this file asserts the
// bundle can *read* them.
//
// TypeScript types vanish at runtime, so a cast would prove nothing. Instead the
// fields the bundle actually depends on are checked explicitly: if Swift renames
// or drops one, this fails here rather than at 2am on someone's news site.

const fixtures = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
  "Tests",
  "Fixtures",
  "wire",
);

function fixture(name: string): unknown {
  return JSON.parse(readFileSync(join(fixtures, `${name}.json`), "utf8"));
}

type JSTypeName =
  | "string"
  | "number"
  | "bigint"
  | "boolean"
  | "symbol"
  | "undefined"
  | "object"
  | "function";

/** Assert a value has the given dotted key path, holding the given `typeof`. */
function expectField(object: unknown, path: string, type: JSTypeName): void {
  const segments = path.split(".");
  let current: unknown = object;

  for (const segment of segments) {
    expect(current, `missing at "${path}" (stopped before "${segment}")`).toBeTypeOf("object");
    expect(current).not.toBeNull();
    current = (current as Record<string, unknown>)[segment];
  }

  expect(current, `field "${path}" should be ${type}`).toBeTypeOf(type);
}

describe("bootstrap configuration", () => {
  const config = fixture("configuration") as ReaderConfiguration;

  it("carries every budget the reveal failsafe depends on", () => {
    // If any of these went missing the bundle would hide the page with an
    // undefined timeout, which is the one unrecoverable failure mode.
    expectField(config, "revealFailsafeMs", "number");
    expectField(config, "settleQuietPeriodMs", "number");
    expectField(config, "settleCeilingMs", "number");
    expect(config.revealFailsafeMs).toBeGreaterThan(0);
    expect(config.settleCeilingMs).toBeLessThan(config.revealFailsafeMs);
  });

  it("carries the eligibility inputs", () => {
    expectField(config, "mode", "string");
    expect(["restructured", "original"]).toContain(config.mode);
    expect(Array.isArray(config.passthroughOrigins)).toBe(true);
    expectField(config, "minConfidence", "number");
    expectField(config, "minWordCount", "number");
    expectField(config, "skeletonNodeLimit", "number");
    expectField(config, "debugLogging", "boolean");
  });

  it("carries a complete theme, so first paint is already styled", () => {
    expectField(config, "theme.id", "string");
    expectField(config, "theme.tokens.typography.body", "string");
    expectField(config, "theme.tokens.typography.baseSize", "number");
    expectField(config, "theme.tokens.light.background", "string");
    expectField(config, "theme.tokens.light.text", "string");
    expectField(config, "theme.tokens.dark.background", "string");
    expectField(config, "theme.tokens.dark.text", "string");
    expectField(config, "theme.tokens.shape.radius", "number");
    expectField(config, "theme.tokens.ornament.rule", "string");
    expectField(config, "theme.tokens.density", "number");
  });

  it("encodes Swift Sets as arrays", () => {
    expect(Array.isArray(config.passthroughOrigins)).toBe(true);
    expect(Array.isArray(config.recipe?.quirks)).toBe(true);
  });

  it("encodes dates as ISO-8601 strings, not epoch numbers", () => {
    const created = config.theme.createdAt;
    expect(created).toBeTypeOf("string");
    expect(Number.isNaN(Date.parse(created))).toBe(false);
  });

  it("omits nil optionals rather than emitting null", () => {
    // Swift's synthesised encoding uses encodeIfPresent, so absent means absent.
    // The bundle's `?.` and `??` handling relies on that.
    expect(config.theme.prompt).toBeUndefined();
    expect("prompt" in config.theme).toBe(false);
  });
});

describe("events", () => {
  it("use a tagged envelope the bundle can switch on", () => {
    for (const name of ["event-extracted", "event-needsRecipe", "event-revealed"]) {
      const event = fixture(name) as ReaderEvent;
      expect(event.v).toBe(WIRE_VERSION);
      expectField(event, "type", "string");
    }
  });

  it("extracted carries the fields the reader renders from", () => {
    const event = fixture("event-extracted") as Extract<ReaderEvent, { type: "extracted" }>;
    expect(event.type).toBe("extracted");
    expectField(event, "payload.archetype", "string");
    expectField(event, "payload.title", "string");
    expectField(event, "payload.wordCount", "number");
    expectField(event, "payload.confidence", "number");
    expectField(event, "payload.isFidelitySensitive", "boolean");
    expect(Array.isArray(event.payload.sections)).toBe(true);

    const section = event.payload.sections[0];
    expect(section).toBeDefined();
    expectField(section, "id", "string");
    expectField(section, "kind", "string");
    expectField(section, "markdown", "string");
  });

  it("needsRecipe carries structure but no page text", () => {
    const event = fixture("event-needsRecipe") as Extract<ReaderEvent, { type: "needsRecipe" }>;
    const node = event.payload.nodes[0];
    expect(node).toBeDefined();
    expectField(node, "textLength", "number");
    expectField(node, "path", "string");
    // The privacy contract, asserted from this side too: a skeleton node must
    // never gain a field holding characters from the page.
    for (const forbidden of ["text", "content", "innerText", "textContent", "html"]) {
      expect(node, `skeleton node must not carry "${forbidden}"`).not.toHaveProperty(forbidden);
    }
  });

  it("revealed carries a reason and an elapsed time", () => {
    const event = fixture("event-revealed") as Extract<ReaderEvent, { type: "revealed" }>;
    expectField(event, "payload.reason", "string");
    expectField(event, "payload.elapsedMs", "number");
  });
});

describe("commands", () => {
  it("a payload-free command still carries type and version", () => {
    const command = fixture("command-requestSkeleton") as { v: number; type: string };
    expect(command.v).toBe(WIRE_VERSION);
    expect(command.type).toBe("requestSkeleton");
  });

  it("applyTheme carries a full token set", () => {
    const command = fixture("command-applyTheme") as { payload: { tokens: unknown } };
    expectField(command, "payload.tokens.typography.body", "string");
    expectField(command, "payload.tokens.light.accent", "string");
  });
});

describe("cross-language invariants", () => {
  it("isRewritable agrees with Swift's SectionKind.isRewritable", () => {
    // This predicate is implemented twice by necessity. The fixture is generated
    // from the Swift enum, so a change on either side breaks this test instead of
    // letting a model rewrite a code block.
    const rules = fixture("section-kinds") as Record<string, boolean>;
    expect(Object.keys(rules).length).toBeGreaterThan(0);

    for (const [kind, expected] of Object.entries(rules)) {
      expect(isRewritable(kind as SectionKind), `${kind} rewritability`).toBe(expected);
    }
  });

  it("covers every kind the bundle knows about", () => {
    const rules = fixture("section-kinds") as Record<string, boolean>;
    const known: SectionKind[] = [
      "heading",
      "paragraph",
      "list",
      "quote",
      "code",
      "table",
      "math",
      "figure",
      "embed",
      "footnotes",
    ];
    expect(Object.keys(rules).sort()).toEqual([...known].sort());
  });
});
