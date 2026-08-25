import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

import { plan } from "../src/level.js";

import {
  isRewritable,
  WIRE_VERSION,
  type Lens,
  type LensOp,
  type LensOpKind,
  type LensProposal,
  type ReaderCommand,
  type ReaderConfiguration,
  type ReaderEvent,
  type RegionCatalog,
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

  it("carries the level, which decides whether the page is hidden at all", () => {
    expectField(config, "level", "string");
    expect(["original", "clean", "calm", "reader", "rewritten"]).toContain(config.level);
    // Both languages must agree on the plan for the level Swift actually sent, or
    // one of them hides a page the other thinks is untouched.
    expect(plan(config, true, false).hide).toBe(true);
  });

  it("clamps mode to original below Reader", () => {
    // Swift asked for `restructured` at level `clean` and got `original` back. A
    // second fixture, because a clamp is invisible in a file where the requested
    // and stored values happen to agree.
    const clean = fixture("configuration-clean") as ReaderConfiguration;
    expect(clean.level).toBe("clean");
    expect(clean.mode).toBe("original");
    const allowed = plan(clean, true, false);
    expect(allowed.hide).toBe(false);
    expect(allowed.consent).toBe(false);
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

  it("applyDocument carries markup the bundle can insert as-is", () => {
    const command = fixture("command-applyDocument") as {
      type: string;
      payload: { html: string };
    };
    expect(command.type).toBe("applyDocument");
    expectField(command, "payload.html", "string");
    // Sanitising happens in Swift, before the command is ever sent. If a script
    // reaches this side, the boundary has already failed.
    expect(command.payload.html).not.toContain("<script");
  });
});

// The lens half of the contract. It was missing entirely: Swift wrote eleven
// lens fixtures and nothing on this side read one, so a rename in `Lens.swift`
// broke no test at all — while `wire.ts`'s own header promised the opposite.
//
// Every assertion below names a field the runner actually branches on. If Swift
// drops or renames one, the failure lands here rather than as an op that quietly
// stops working on somebody's feed.

describe("lens wire types", () => {
  it("applyLenses carries a lens the compiler and runner can both read", () => {
    const command = fixture("command-applyLenses") as Extract<
      ReaderCommand,
      { type: "applyLenses" }
    >;
    expect(command.v).toBe(WIRE_VERSION);
    expect(command.type).toBe("applyLenses");

    const lens = command.payload[0] as Lens;
    expectField(lens, "id", "string");
    expectField(lens, "name", "string");
    expectField(lens, "origin", "string");
    expectField(lens, "pathPattern", "string");
    expectField(lens, "isEnabled", "boolean");
    expectField(lens, "schemaVersion", "number");
    expectField(lens, "updatedAt", "string");
    // Stacking is `updatedAt` descending now. An `order` back on the wire means
    // the popover's list has started meaning something again, and the question of
    // which lens wins has two owners — which is the whole thing that was cut.
    expect(lens).not.toHaveProperty("order");
    expect(Array.isArray(lens.regions)).toBe(true);
    expect(Array.isArray(lens.ops)).toBe(true);

    const region = lens.regions[0];
    expectField(region, "id", "string");
    expectField(region, "intent", "string");
    // First-match-wins drift recovery reads this as an array, in order.
    expect(Array.isArray(region?.selectors)).toBe(true);
    expect(region?.selectors.length).toBeGreaterThan(1);
  });

  it("carries the fingerprint that catches a selector matching the wrong box", () => {
    // The selector list only degrades gracefully when a stale selector matches
    // *nothing*. The measured failure is the other one: a `cssPath` or a build
    // hash that still matches after a redesign, a different element, reported
    // `applied`. Scoring against this is what makes a `missed` honest — so if
    // Swift renames a field here the fallback silently stops having any input.
    const command = fixture("command-applyLenses") as Extract<
      ReaderCommand,
      { type: "applyLenses" }
    >;
    const region = (command.payload[0] as Lens).regions[0];
    const fingerprint = region?.fingerprint;

    expectField(fingerprint, "tag", "string");
    expectField(fingerprint, "childCount", "number");
    expectField(fingerprint, "textLengthBand", "number");
    expectField(fingerprint, "siblingIndex", "number");
    expectField(fingerprint, "rectBand.width", "number");
    expect(Array.isArray(fingerprint?.classes)).toBe(true);
    expect(Array.isArray(fingerprint?.attributeNames)).toBe(true);
    expect(Array.isArray(fingerprint?.ancestorTags)).toBe(true);

    // Names, never values — except `role`, whose values are a closed W3C
    // vocabulary and so cannot hold a character from the page.
    expect(fingerprint?.attributeNames).toContain("aria-label");
    expect(fingerprint?.role).toBeTypeOf("string");
    for (const forbidden of ["text", "textContent", "attributeValues", "html", "snippet"]) {
      expect(fingerprint, `fingerprint must not carry "${forbidden}"`).not.toHaveProperty(
        forbidden,
      );
    }

    // Optional on purpose: a lens written before fingerprinting must still
    // decode rather than be discarded as incompatible.
    expect((command.payload[0] as Lens).regions[1]?.fingerprint).toBeUndefined();
  });

  /** Every op in the fixture, by kind. */
  function opsByKind(): Map<LensOpKind, LensOp> {
    const command = fixture("command-applyLenses") as Extract<
      ReaderCommand,
      { type: "applyLenses" }
    >;
    const lens = command.payload[0] as Lens;
    const found = new Map<LensOpKind, LensOp>();
    for (const op of lens.ops) if (!found.has(op.kind)) found.set(op.kind, op);
    return found;
  }

  it("carries every op kind the runner switches on", () => {
    // `applyOp`'s switch is exhaustive over `LensOpKind`. A kind that reaches a
    // page but appears in no fixture is a branch neither suite has ever run.
    const kinds = new Set(opsByKind().keys());
    const runnerKinds: LensOpKind[] = [
      "hide",
      "keep",
      "width",
      "move",
      "restyle",
      "reorder",
      "filter",
      "label",
      "harvest",
      "insert",
    ];
    for (const kind of runnerKinds) {
      expect(kinds.has(kind), `no ${kind} op in command-applyLenses`).toBe(true);
    }
  });

  it("gives each op kind the field it is defined by", () => {
    const ops = opsByKind();

    expect(ops.get("width")?.fraction).toBeTypeOf("number");
    expect(ops.get("move")?.target).toBeTypeOf("string");
    expect(ops.get("move")?.index).toBeTypeOf("number");
    expect(ops.get("label")?.text).toBeTypeOf("string");
    expect(ops.get("restyle")?.style?.background).toBeTypeOf("string");
    // `reorder` and `filter` are defined by the item they act on: without it the
    // runner falls back to the region's own children, and a `drop` filter that
    // loses its scope empties the feed.
    expect(ops.get("reorder")?.itemSelector).toBeTypeOf("string");
    expect(ops.get("filter")?.itemSelector).toBeTypeOf("string");
    expect(ops.get("filter")?.filterMode).toBeTypeOf("string");
    // `insert` reads a bucket a `harvest` filled. `applyInsert` reads exactly
    // this field, with no fallback.
    expect(ops.get("insert")?.bucket).toBeTypeOf("string");
    expect(ops.get("insert")?.target).toBeTypeOf("string");

    const harvest = ops.get("harvest")?.harvest;
    expectField(harvest, "itemSelector", "string");
    expectField(harvest, "into", "string");
    expect(Array.isArray(harvest?.fields)).toBe(true);
    // A closed set on both sides: an arbitrary attribute name would let a lens
    // lift `data-*` payloads a site never meant to render.
    for (const field of harvest?.fields ?? []) {
      expect(["text", "href", "src", "alt", "title"]).toContain(field.attribute);
    }
    expect(
      ops.get("insert")?.bucket,
      "insert must name a bucket some harvest fills",
    ).toBe(harvest?.into);
  });

  it("exercises the whole predicate vocabulary", () => {
    const command = fixture("command-applyLenses") as Extract<
      ReaderCommand,
      { type: "applyLenses" }
    >;
    const filters = (command.payload[0] as Lens).ops.filter((op) => op.kind === "filter");
    const modes = new Set(filters.map((op) => op.predicate?.matchMode));
    const fields = new Set(filters.map((op) => op.predicate?.field));

    // `matchesPredicate` branches on every one of these. Until now no fixture
    // contained an `all`, a `none`, an `href` or an `ariaLabel`, so a rename on
    // the Swift side would have gone through both suites untouched.
    expect(modes).toContain("any");
    expect(modes).toContain("all");
    expect(modes).toContain("none");
    expect(fields).toContain("text");
    expect(fields).toContain("href");
    expect(fields).toContain("ariaLabel");

    const bounded = filters.find((op) => typeof op.predicate?.minLinks === "number");
    expectField(bounded?.predicate, "minLinks", "number");
    expectField(bounded?.predicate, "maxLinks", "number");
    expectField(bounded?.predicate, "minChars", "number");
    expectField(bounded?.predicate, "maxChars", "number");
  });

  it("exercises every sort key", () => {
    const command = fixture("command-applyLenses") as Extract<
      ReaderCommand,
      { type: "applyLenses" }
    >;
    const keys = new Set(
      (command.payload[0] as Lens).ops.map((op) => op.sort?.key).filter(Boolean),
    );
    expect(keys).toContain("textLength");
    expect(keys).toContain("linkCount");
    expect(keys).toContain("harvestedField");
  });

  it("omits nil op fields rather than emitting null", () => {
    // `applyInsert` and `applyFilter` read these with `??`, so a `null` would be
    // taken for a value.
    const command = fixture("command-applyLenses") as Extract<
      ReaderCommand,
      { type: "applyLenses" }
    >;
    const hide = (command.payload[0] as Lens).ops.find((op) => op.kind === "hide");
    for (const absent of [
      "target",
      "index",
      "fraction",
      "text",
      "style",
      "sort",
      "predicate",
      "filterMode",
      "harvest",
      "itemSelector",
      "bucket",
      "limit",
    ]) {
      expect(hide, `hide op should omit "${absent}"`).not.toHaveProperty(absent);
    }
  });

  it("lensReport carries every status the UI branches on", () => {
    const event = fixture("event-lensReport") as Extract<ReaderEvent, { type: "lensReport" }>;
    const report = event.payload[0];
    expectField(report, "lensID", "string");
    expectField(report, "url", "string");
    expectField(report, "generatedAt", "string");

    const statuses = new Set(report?.results.map((entry) => entry.status));
    // `ambiguous` and `failed` appeared in no fixture at all, so the two statuses
    // the badge has to treat as neither applied nor missed were never decoded.
    for (const status of ["applied", "missed", "skipped", "ambiguous", "failed"]) {
      expect(statuses, `no ${status} result in event-lensReport`).toContain(status);
    }

    // Derived on the Swift side, so the badge cannot read a counter that
    // disagrees with the results it was computed from.
    expect(report).not.toHaveProperty("appliedCount");
    expect(report).not.toHaveProperty("missedCount");
  });

  it("lensRegions carries structure but no page text", () => {
    const event = fixture("event-lensRegions") as Extract<ReaderEvent, { type: "lensRegions" }>;
    const catalog = event.payload as RegionCatalog;
    expectField(catalog, "origin", "string");
    expectField(catalog, "pathPattern", "string");
    expectField(catalog, "viewport.width", "number");

    const candidate = catalog.candidates[0];
    expectField(candidate, "selector", "string");
    expectField(candidate, "kindGuess", "string");
    expectField(candidate, "rect.width", "number");
    expectField(candidate, "textLength", "number");
    expectField(candidate, "itemCount", "number");

    // The privacy contract, asserted from this side too. `alternates` and
    // `textLength` are allowed by name; anything else reading like prose is not.
    const allowed = new Set(Object.keys(candidate ?? {}));
    for (const forbidden of ["text", "excerpt", "innerText", "textContent", "html", "snippet"]) {
      expect(allowed.has(forbidden), `candidate must not carry "${forbidden}"`).toBe(false);
    }
  });

  it("offers the insides of one repeated item, so a harvest can be authored", () => {
    // `HarvestField.selector` is the one selector a model must supply and the one
    // that is deliberately not catalog-gated. Without this field the model was
    // shown an item selector and nothing inside an item, so it had to invent
    // `.title` — against a prompt that says invented selectors are discarded.
    const event = fixture("event-lensRegions") as Extract<ReaderEvent, { type: "lensRegions" }>;
    const feed = (event.payload as RegionCatalog).candidates.find(
      (entry) => entry.itemFields.length > 0,
    );
    expect(feed, "no candidate in the fixture offers item fields").toBeDefined();

    const field = feed?.itemFields[0];
    expectField(field, "selector", "string");
    expectField(field, "tag", "string");
    expectField(field, "textLength", "number");
    expect(Array.isArray(field?.attributesPresent)).toBe(true);

    // The same privacy line, one level down, and the place it is hardest to hold:
    // a model would pick a field instantly from a sample of the item's text, and
    // that sample is the sentence the user is reading.
    for (const forbidden of ["text", "value", "content", "innerText", "textContent"]) {
      expect(field, `item field must not carry "${forbidden}"`).not.toHaveProperty(forbidden);
    }
  });

  it("proposeOps carries the regions its ops are checked against", () => {
    const command = fixture("command-proposeOps") as Extract<
      ReaderCommand,
      { type: "proposeOps" }
    >;
    const proposal = command.payload as LensProposal;
    expectField(proposal, "note", "string");
    expect(Array.isArray(proposal.regions)).toBe(true);
    // Every op names a region the proposal declares — the whole validation
    // vocabulary travels with the ops, so the preview can highlight them.
    const declared = new Set(proposal.regions.map((region) => region.id));
    for (const op of proposal.ops) expect(declared.has(op.region)).toBe(true);
  });

  it("lensPrompt carries the user's words and the catalog they were typed against", () => {
    const event = fixture("event-lensPrompt") as Extract<ReaderEvent, { type: "lensPrompt" }>;
    expectField(event, "payload.text", "string");
    expect(Array.isArray(event.payload.selectedRegionIDs)).toBe(true);
    expectField(event, "payload.catalog.origin", "string");
  });

  it("lensDraft and lensModeChanged decode", () => {
    const draft = fixture("event-lensDraft") as Extract<ReaderEvent, { type: "lensDraft" }>;
    expect(draft.type).toBe("lensDraft");
    expectField(draft, "payload.id", "string");

    const mode = fixture("event-lensModeChanged") as Extract<
      ReaderEvent,
      { type: "lensModeChanged" }
    >;
    expect(mode.payload).toBe(true);
  });

  it("the payload-free lens commands still carry type and version", () => {
    for (const name of ["command-enterLensMode", "command-exitLensMode", "command-requestRegions"]) {
      const command = fixture(name) as { v: number; type: string };
      expect(command.v).toBe(WIRE_VERSION);
      expect(command.type).toBe(name.replace("command-", ""));
    }
  });

  it("a bootstrap configuration can arrive with lenses already in it", () => {
    // `configuration.json` has an empty `lenses`, which only proves the key
    // survives. The stylesheet has to be compiled at document-start from what is
    // *in* it, so the shape inside matters more than the key does.
    const config = fixture("configuration-lenses") as ReaderConfiguration;
    expect(config.lenses.length).toBeGreaterThan(0);
    expectField(config, "lenses.0.ops.0.kind", "string");

    // Seven lens budgets used to ride here, and `lens/index.ts` declared its own
    // copy of all seven and fell back to it per field — the same compile-time
    // constants serialised into a bootstrap script to arrive at the value the
    // receiver already held. Asserting their absence is what stops an eighth.
    for (const budget of [
      "lensOpPassCeilingMs",
      "lensObserverDebounceMs",
      "lensObserverMaxPassesPerSecond",
      "lensMaxItemsPerPass",
      "lensMaxOpsPerLens",
      "lensMaxLensesPerOrigin",
      "lensRegionCandidateLimit",
    ]) {
      expect(config, `${budget} is a build constant, not wire state`).not.toHaveProperty(budget);
    }
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

  it("enterLensMode decodes with and without an edit target", () => {
    // The authoring form carries no payload at all and the editing form carries a
    // lens id. Swift encodes the key only when non-nil, so the two fixtures differ
    // by the presence of `payload` rather than by a null — and the bundle has to
    // read both. Getting this wrong is what made "Edit…" duplicate a lens instead
    // of revising it, so the distinction is pinned on both sides.
    const authoring = fixture("command-enterLensMode") as ReaderCommand;
    expect(authoring.type).toBe("enterLensMode");
    expect(authoring.v).toBe(WIRE_VERSION);
    expect("payload" in authoring).toBe(false);

    const editing = fixture("command-enterLensMode-editing") as ReaderCommand;
    expect(editing.type).toBe("enterLensMode");
    expect(editing.v).toBe(WIRE_VERSION);
    if (editing.type !== "enterLensMode") throw new Error("wrong command");
    expect(editing.payload?.editing).toBe("lens-focus");
  });

  it("lens-op-kinds is exactly the set the runner handles", () => {
    // `applyOp`'s switch is exhaustive over `LensOpKind` on this side and over
    // `LensOpKind` on the Swift side, and the two enums are hand-mirrored. A kind
    // added to one and not the other is not a compile error anywhere — it is an
    // op that arrives on a user's page and silently does nothing, or one the
    // model is never told it may author.
    const kinds = (fixture("lens-op-kinds") as { kinds: string[] }).kinds;
    const handled: LensOpKind[] = [
      "hide",
      "keep",
      "width",
      "move",
      "restyle",
      "reorder",
      "filter",
      "label",
      "harvest",
      "insert",
    ];
    expect([...kinds].sort()).toEqual([...handled].sort());
  });
});
