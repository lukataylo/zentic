import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { createLensEditor, type LensEditor } from "../../src/lens/editor.js";
import { HarvestStore } from "../../src/lens/harvest.js";
import { LensJournal, runStructuralOps } from "../../src/lens/ops.js";
import type { Lens, LensProposal, RegionCandidate, RegionCatalog } from "../../src/wire.js";

// The editor makes four promises, and each one is a test here.
//
//  1. **A proposal is a highlight, never an effect.** The model guesses at
//     regions; a wrong guess is one click from hiding someone's video player. So
//     `showProposal` must outline and describe, and nothing may reach the draft
//     until Apply.
//  2. **Authoring is not editing.** ⌥⌘L on a site with lenses writes a *new*
//     lens and adopts none of them; "Edit…" adopts exactly one and gives the
//     draft its id, which is the only thing that makes Save a replacement rather
//     than a duplicate with every op running twice.
//  3. **It draws over the page and never writes to it — and the page learns
//     nothing.** Mount, then unmount, and the document is what was found; while
//     it is up, a page-world listener must not be able to read the prompt or the
//     pointer. A closed shadow root hides the DOM, not the events.
//  4. **It is reachable from the keyboard.** Esc, Tab, Enter, ⌘⏎, and a prompt
//     field that does not trap Tab.
//
// The overlay lives in a *closed* shadow root, which is the point of it. That
// leaves the tests with the same problem a page has, solved the way a page
// cannot — by capturing the root `attachShadow` returns. `mode` is asserted, so
// the isolation itself is under test rather than quietly relaxed for testability.

const HOST_ID = "zentic-lens-editor";

function candidate(id: string, over: Partial<RegionCandidate> = {}): RegionCandidate {
  return {
    id,
    selector: `#${id}`,
    alternates: [`div.${id}`],
    tag: "div",
    classes: [id],
    kindGuess: "unknown",
    rect: { x: 20, y: 40, width: 100, height: 80 },
    depth: 2,
    textLength: 120,
    linkCount: 0,
    paragraphCount: 1,
    imageCount: 0,
    itemCount: 0,
    itemFields: [],
    ...over,
  };
}

const CATALOG: RegionCatalog = {
  origin: "example.com",
  // Deliberately different from the test document's own path ("/"), so "this
  // page" and "pages like this" cannot pass for each other.
  pathPattern: "/watch",
  viewport: { width: 1280, height: 900 },
  candidates: [
    candidate("r0", { elementID: "related", kindGuess: "aside" }),
    candidate("r1", { kindGuess: "feed", itemCount: 12 }),
    candidate("r2", { rect: { x: 0, y: 0, width: 0, height: 0 } }),
  ],
};

const PROPOSAL: LensProposal = {
  regions: [{ id: "related", intent: "the suggestions rail", selectors: ["#r0"] }],
  ops: [
    { id: "op-1", kind: "hide", region: "related", note: "hide the suggestions" },
    { id: "op-2", kind: "width", region: "related", note: "narrow the rail", fraction: 0.5 },
  ],
  note: "Two changes to the rail.",
};

function existingLens(over: Partial<Lens> = {}): Lens {
  return {
    id: "lens-existing",
    name: "Focus",
    origin: "example.com",
    pathPattern: "/watch",
    isEnabled: true,
    prompt: "hide the noise",
    regions: [{ id: "rail", intent: "the suggestions rail", selectors: ["#r0"] }],
    ops: [
      { id: "old-1", kind: "hide", region: "rail", note: "hide the rail" },
      { id: "old-2", kind: "restyle", region: "rail", note: "calm the colours" },
    ],
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
    schemaVersion: 1,
    ...over,
  };
}

/** A lens that harvests into a bucket and inserts that bucket somewhere else —
 * the shape that collides on names no region id is involved in. */
function harvestingLens(over: Partial<Lens> = {}): Lens {
  return existingLens({
    regions: [
      { id: "rail", intent: "the suggestions rail", selectors: ["#r0"] },
      { id: "main", intent: "the article", selectors: ["#r1"] },
    ],
    ops: [
      {
        id: "h-1",
        kind: "harvest",
        region: "rail",
        note: "collect the rail's links",
        harvest: {
          itemSelector: ":scope > li",
          fields: [{ name: "title", selector: "a", attribute: "text" }],
          into: "items",
        },
      },
      {
        id: "i-1",
        kind: "insert",
        region: "main",
        note: "list them under the article",
        target: "main",
        bucket: "items",
        sort: { key: "harvestedField", field: "title", ascending: true },
      },
    ],
    ...over,
  });
}

let editor: LensEditor;
let shadow: ShadowRoot;
let drafts: Lens[];
let prompts: Array<{ text: string; ids: string[] }>;
let closes: number;

const originalAttachShadow = Element.prototype.attachShadow;

beforeEach(() => {
  document.body.innerHTML = `<main id="page"><p>Untouched page content.</p><a href="#" id="anchor">link</a></main>`;
  drafts = [];
  prompts = [];
  closes = 0;

  Element.prototype.attachShadow = function (this: Element, init: ShadowRootInit): ShadowRoot {
    const root = originalAttachShadow.call(this, init);
    if (this.id === HOST_ID) shadow = root;
    return root;
  };

  editor = createLensEditor(document);
  editor.onDraft((lens) => drafts.push(lens));
  editor.onPrompt((text, ids) => prompts.push({ text, ids }));
  editor.onClose(() => {
    closes += 1;
  });
});

afterEach(() => {
  editor.unmount();
  Element.prototype.attachShadow = originalAttachShadow;
});

// MARK: - Reaching into the overlay

function all<T extends Element = HTMLElement>(selector: string): T[] {
  return Array.from(shadow.querySelectorAll(selector)) as unknown as T[];
}

function one<T extends Element = HTMLElement>(selector: string): T {
  const node = shadow.querySelector(selector);
  if (!node) throw new Error(`no ${selector} in the overlay`);
  return node as unknown as T;
}

const regions = (): HTMLElement[] => all(".region");
const draftChips = (): HTMLElement[] => all(".bar > .chips .chip");
const contextChips = (): HTMLElement[] => all(".context .chip");
const pendingChips = (): HTMLElement[] => all(".proposal .chip");
const prompt = (): HTMLInputElement => one<HTMLInputElement>(".prompt");
const notice = (): HTMLElement => one(".notice");

function labelled(text: string): HTMLButtonElement {
  const node = all<HTMLButtonElement>("button").find((button) => button.textContent === text);
  if (!node) throw new Error(`no button labelled "${text}"`);
  return node;
}

// `composed` is what a real user event carries, and it is the whole of why a
// closed shadow root does not isolate anything by itself: without it these
// events would not leave the root and the isolation tests would pass vacuously.
//
// The seal stops a composed click at `window` and replays it inside the root, and
// to do that it has to hit-test the point against its own tree. jsdom has no
// layout and so no `elementFromPoint`; supplying it is the same bargain the
// reflow tests strike with `getBoundingClientRect`, and without it every click
// here would exercise the fail-open path rather than the real one.
function click(node: Element, init: MouseEventInit = {}): void {
  (shadow as unknown as { elementFromPoint: (x: number, y: number) => Element }).elementFromPoint =
    () => node;
  // `detail: 1` is what a real pointer click carries, and the seal reads it: a
  // keyboard-synthesised click has `detail: 0` and no coordinates to hit-test.
  node.dispatchEvent(
    new MouseEvent("click", {
      bubbles: true,
      composed: true,
      detail: 1,
      clientX: 1,
      clientY: 1,
      ...init,
    }),
  );
}

function press(node: Element, key: string, init: KeyboardEventInit = {}): void {
  node.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, composed: true, ...init }));
}

function selectedIDs(): string[] {
  return regions()
    .filter((node) => node.hasAttribute("data-selected"))
    .map((node) => node.dataset.region ?? "");
}

/** Apply the standard proposal, so tests about saving start from a real draft. */
function acceptProposal(): void {
  editor.showProposal(PROPOSAL);
  click(labelled("Apply"));
}

// MARK: - Tests

describe("mounting", () => {
  it("draws one outline per candidate inside a closed shadow root", () => {
    editor.mount(CATALOG, []);

    const host = document.getElementById(HOST_ID);
    expect(host).not.toBeNull();
    // Closed keeps page script out of the tree. It does nothing about events,
    // which is what the isolation suite below is for.
    expect(host?.shadowRoot).toBeNull();
    expect(shadow.mode).toBe("closed");

    expect(regions()).toHaveLength(CATALOG.candidates.length);
    expect(regions().map((node) => node.dataset.region)).toEqual(["r0", "r1", "r2"]);

    const first = regions()[0]!;
    expect(first.style.left).toBe("20px");
    expect(first.style.width).toBe("100px");
    // One phrase, in a person's words, and it comes from the catalog's kind
    // guess rather than from page text. The tag name, our internal vocabulary
    // and the pixel size are all gone: see `regionLabel`.
    expect(one(".region .tag").textContent).toBe("Sidebar");
    // The accessible name still carries the identifier, because a screen reader
    // has 120 of these in a row and no boxes to tell them apart.
    expect(first.getAttribute("aria-label")).toBe("Sidebar, #related");
  });

  it("names a region we cannot classify after its identifier, never 'unknown'", () => {
    editor.mount(CATALOG, []);

    // `r2` has no kind guess we recognise, so the label falls back to the name
    // of the thing rather than printing our own word for "no idea".
    expect(regions()[2]!.querySelector(".tag")?.textContent).toBe("div.r2");
  });

  it("keeps a zero-size region addressable rather than dropping it", () => {
    editor.mount(CATALOG, []);

    const empty = regions()[2]!;
    expect(empty.hasAttribute("data-empty")).toBe(true);

    click(empty);
    expect(selectedIDs()).toEqual(["r2"]);
  });

  it("survives a document with no body", () => {
    const bare = document.implementation.createHTMLDocument("bare");
    bare.documentElement.removeChild(bare.body);

    // `<html>` is a parent too. What matters is that a document mid-parse costs
    // nothing: no throw on the way in, no throw on the way out.
    const orphan = createLensEditor(bare);
    expect(() => orphan.mount(CATALOG, [])).not.toThrow();
    expect(() => orphan.unmount()).not.toThrow();
  });

  it("says so and gives focus back when it cannot build itself", () => {
    // A hostile or half-built page: the caller announces lens mode on the
    // strength of the return value, and a caret left nowhere is a page the user
    // cannot type into.
    const anchor = document.getElementById("anchor") as HTMLElement;
    anchor.focus();
    Element.prototype.attachShadow = function (this: Element): ShadowRoot {
      throw new Error("no shadow roots on this page");
    };

    expect(editor.mount(CATALOG, [])).toBe(false);

    expect(document.getElementById(HOST_ID)).toBeNull();
    expect(document.activeElement).toBe(anchor);
    // It never opened, so it never closed.
    expect(closes).toBe(0);
  });

  it("adopts nothing when authoring, and shows other lenses as context only", () => {
    // The defect this replaces: every applied lens was adopted into one draft, so
    // Save minted a third lens holding both lenses' ops with the originals still
    // enabled — every op applied twice, and no way to revise either.
    const other = existingLens({ id: "lens-other", name: "Wide" });
    editor.mount(CATALOG, [existingLens(), other]);

    expect(draftChips()).toHaveLength(0);
    expect(labelled("Save Lens").disabled).toBe(true);

    // Visible, attributed, and not editable: no × to press, so nothing about them
    // can end up in this draft.
    expect(contextChips()).toHaveLength(4);
    expect(contextChips().map((chip) => chip.querySelector(".lens")?.textContent)).toEqual([
      "Focus",
      "Focus",
      "Wide",
      "Wide",
    ]);
    expect(contextChips().some((chip) => chip.querySelector(".x") !== null)).toBe(false);

    // Nor may they colour the page as if they were the draft's reach.
    expect(regions().some((node) => node.hasAttribute("data-touched"))).toBe(false);
  });

  it("adopts only the lens named for editing", () => {
    const other = existingLens({
      id: "lens-other",
      name: "Wide",
      ops: [{ id: "old-3", kind: "hide", region: "rail", note: "hide the nav" }],
    });

    editor.mount(CATALOG, [existingLens(), other], "lens-existing");

    expect(draftChips().map((chip) => chip.querySelector(".note")?.textContent)).toEqual([
      "hide the rail",
      "calm the colours",
    ]);
    expect(contextChips().map((chip) => chip.querySelector(".note")?.textContent)).toEqual([
      "hide the nav",
    ]);
  });

  it("refuses to open on a lens it was not handed", () => {
    // The popover offers Edit on every lens the site has — including the ones
    // switched off and the ones scoped to another path — while the editor is
    // handed only the set that is actually applied. Falling through to authoring
    // there is silent duplication: a blank overlay, a fresh id, and Save writes a
    // THIRD lens while the one the user pressed Edit on is never touched. An
    // `editing` id with no lens behind it is a caller error, so it is refused.
    const mounted = editor.mount(CATALOG, [existingLens()], "lens-gone");

    expect(mounted).toBe(false);
    expect(document.getElementById(HOST_ID)).toBeNull();
    // It never opened, so it never closed.
    expect(closes).toBe(0);
  });

  it("leaves an editor that is already up alone when it refuses", () => {
    editor.mount(CATALOG, [existingLens()], "lens-existing");

    expect(editor.mount(CATALOG, [existingLens()], "lens-gone")).toBe(false);
    expect(document.querySelectorAll(`#${HOST_ID}`)).toHaveLength(1);
    expect(draftChips()).toHaveLength(2);
    expect(closes).toBe(0);
  });
});

/**
 * The overlay's own stylesheet, as text.
 *
 * The rules below are the whole of what this surface draws, and jsdom has no
 * cascade to ask inside a closed shadow root — so they are read as the artefact
 * WebKit reads. Not a proxy for the design: on this surface the design *is* which
 * state paints what, and that lives nowhere else.
 */
function ruleBodies(selector: string): string[] {
  const sheet = shadow.querySelector("style")?.textContent ?? "";
  const bodies: string[] = [];
  // Comments first, or a selector named inside one counts as a rule.
  for (const rule of sheet.replace(/\/\*[\s\S]*?\*\//g, "").split("}")) {
    const [head, body] = rule.split("{");
    if (head === undefined || body === undefined) continue;
    const selectors = head.split(",").map((part) => part.trim());
    if (selectors.includes(selector)) bodies.push(body.trim());
  }
  return bodies;
}

describe("what the overlay draws", () => {
  // The fault: `Budget.lensRegionCandidateLimit` is 120, and every candidate was
  // outlined at once — nested three and four deep over the same paragraph, with
  // the page washed behind them. The surface exists so a person can point at the
  // box they mean, and a page covered in rectangles is one you cannot read well
  // enough to point at anything. So rest draws nothing and every mark is spent on
  // the box in play.

  it("draws no outline on a region at rest", () => {
    editor.mount(CATALOG, []);

    const base = ruleBodies(".region");
    expect(base).toHaveLength(1);
    expect(base[0]).toContain("box-shadow: none");
    // The ring that used to be on all 120 of them.
    expect(base[0]).not.toContain("var(--edge)");
    // And the pointer says the page is the control, since nothing else does.
    expect(base[0]).toContain("cursor: crosshair");
  });

  it("gives focus exactly what hover gets", () => {
    editor.mount(CATALOG, []);

    // Tab is the only way to reach a region without a pointer, so a focus ring
    // quieter than the hover ring would make the keyboard a second-class way to
    // use the surface. One rule, three ways in.
    const hovered = ruleBodies(".region:hover");
    const focused = ruleBodies(".region:focus-visible");
    expect(hovered).toHaveLength(1);
    expect(focused).toEqual(hovered);
    expect(hovered[0]).toContain("inset 0 0 0 2px var(--accent)");
  });

  it("lets a hovered region outdraw the quiet mark the draft leaves on it", () => {
    editor.mount(CATALOG, []);

    // Every state here is one attribute deep, so they all have the same
    // specificity and the last one declared wins. A region an op already acts on
    // therefore has to be declared before hover, or pointing at it would draw it
    // *fainter* than pointing at the region beside it.
    const sheet = shadow.querySelector("style")?.textContent ?? "";
    expect(sheet.indexOf(".region[data-touched]")).toBeLessThan(
      sheet.indexOf(".region:focus-visible {"),
    );
  });

  it("keeps the page readable behind the scrim", () => {
    editor.mount(CATALOG, []);

    // A wash, not a dimmer: the user is reading the page in order to point at
    // part of it. Anything heavy enough to push the prose back a plane is heavy
    // enough to stop them finding the box they mean.
    const scrim = ruleBodies(".scrim")[0] ?? "";
    const alpha = Number(/rgba\([^)]*?([0-9.]+)\)/.exec(scrim)?.[1] ?? "1");
    expect(alpha).toBeLessThanOrEqual(0.2);
  });

  it("puts the tightest box under the pointer on top of the ones around it", () => {
    // A pointer over a paragraph is over four candidates at once — the paragraph,
    // the article, the column, the page wrapper. Exactly one of them can be the
    // one the user means, and it is the smallest: the others are still reachable
    // by pointing at a part of them the smaller one does not cover.
    editor.mount(
      {
        ...CATALOG,
        candidates: [
          candidate("page", { rect: { x: 0, y: 0, width: 1200, height: 4000 } }),
          candidate("column", { rect: { x: 0, y: 0, width: 700, height: 3000 } }),
          candidate("para", { rect: { x: 0, y: 0, width: 700, height: 60 } }),
        ],
      },
      [],
    );

    const [page, column, para] = regions().map((node) => Number(node.style.zIndex));
    expect(para).toBeGreaterThan(column!);
    expect(column).toBeGreaterThan(page!);
    // Never behind the scrim, never over the prompt bar.
    expect(page).toBeGreaterThan(0);
    expect(para).toBeLessThanOrEqual(10_000);
  });

});

describe("what the overlay says about itself", () => {
  it("says nothing about the reader until it is told to", () => {
    editor.mount(CATALOG, []);
    expect(one(".aside").hidden).toBe(true);
  });

  it("says a lens authored over the reader will not show yet", () => {
    editor.mount(CATALOG, []);

    // At Reader the site's own DOM is underneath our render, so every op is
    // correctly reported `skipped` and a lens saved here changes nothing anyone
    // can see. The overlay draws over that hidden document either way, so
    // without this the surface looks exactly like it does when it works.
    editor.setReaderShowing(true);
    const aside = one(".aside");
    expect(aside.hidden).toBe(false);
    expect(aside.textContent).toContain("below Reader");
    // Not a failure: the lens is fine and will be saved.
    expect(notice().hidden).toBe(true);
    expect(labelled("Save Lens").disabled).toBe(true);

    // The rail is reachable while the editor is up, and a warning that has
    // stopped applying is worse than no warning.
    editor.setReaderShowing(false);
    expect(one(".aside").hidden).toBe(true);
  });

  it("does not carry the warning into the next editing session", () => {
    editor.mount(CATALOG, []);
    editor.setReaderShowing(true);
    expect(one(".aside").hidden).toBe(false);

    editor.mount(CATALOG, []);
    expect(one(".aside").hidden).toBe(true);
  });

  it("tells a person the page itself is the control", () => {
    editor.mount(CATALOG, []);

    // With nothing drawn at rest, this line is the whole of "what can I point
    // at" — and the honest answer is everything, so it is one sentence rather
    // than a legend.
    expect(one(".count").textContent).toBe("Point anywhere on the page");

    click(regions()[0]!);
    expect(one(".count").textContent).toBe("1 selected");
  });
});

describe("selection", () => {
  beforeEach(() => editor.mount(CATALOG, []));

  it("highlights on hover and clears on leave", () => {
    const region = regions()[1]!;
    region.dispatchEvent(new MouseEvent("mouseenter"));
    expect(region.hasAttribute("data-hovered")).toBe(true);

    region.dispatchEvent(new MouseEvent("mouseleave"));
    expect(region.hasAttribute("data-hovered")).toBe(false);
  });

  it("replaces the selection on a plain click and extends it with shift", () => {
    click(regions()[0]!);
    expect(selectedIDs()).toEqual(["r0"]);

    click(regions()[1]!);
    expect(selectedIDs()).toEqual(["r1"]);

    click(regions()[0]!, { shiftKey: true });
    expect(selectedIDs()).toEqual(["r0", "r1"]);

    click(regions()[0]!, { shiftKey: true });
    expect(selectedIDs()).toEqual(["r1"]);

    // A plain click on the sole selection clears it, so there is a way back to
    // "nothing selected" without hunting for empty space.
    click(regions()[1]!);
    expect(selectedIDs()).toEqual([]);
  });

  it("reports the selection to the user", () => {
    click(regions()[0]!, { shiftKey: true });
    click(regions()[1]!, { shiftKey: true });
    expect(one(".count").textContent).toBe("2 selected");
  });
});

describe("prompting", () => {
  beforeEach(() => editor.mount(CATALOG, []));

  it("sends the text and the selected region ids, and applies nothing itself", () => {
    click(regions()[0]!, { shiftKey: true });
    click(regions()[2]!, { shiftKey: true });

    prompt().value = "hide the suggestions rail";
    prompt().dispatchEvent(new Event("input"));
    click(labelled("Ask"));

    expect(prompts).toEqual([{ text: "hide the suggestions rail", ids: ["r0", "r2"] }]);
    expect(draftChips()).toHaveLength(0);
    expect(drafts).toEqual([]);
  });

  it("submits on Enter and refuses an empty prompt", () => {
    click(labelled("Ask"));
    expect(prompts).toEqual([]);

    prompt().value = "  ";
    press(prompt(), "Enter");
    expect(prompts).toEqual([]);

    prompt().value = "  drop the ads  ";
    press(prompt(), "Enter");
    expect(prompts).toEqual([{ text: "drop the ads", ids: [] }]);
  });

  it("recovers when the ask cannot be answered", () => {
    prompt().value = "hide the rail";
    prompt().dispatchEvent(new Event("input"));
    click(labelled("Ask"));

    expect(one(".count").textContent).toBe("asking…");
    expect(labelled("Ask").disabled).toBe(true);

    editor.promptFailed("The model is unavailable.");

    // Without this the editor sits at "asking…" for the rest of the session and
    // the only way out loses the draft.
    expect(notice().hidden).toBe(false);
    expect(notice().textContent).toBe("The model is unavailable.");
    expect(labelled("Ask").disabled).toBe(false);
    // Out of "asking…" and back to the standing hint, not to nothing: with no
    // outline drawn at rest this line is what says the page itself is the
    // control.
    expect(one(".count").textContent).toBe("Point anywhere on the page");

    // Asking again is a fresh start, not a second failure.
    click(labelled("Ask"));
    expect(prompts).toHaveLength(2);
    expect(notice().hidden).toBe(true);
  });

  it("treats an answer with no ops in it as a failure, not a silent stall", () => {
    prompt().value = "make it nice";
    prompt().dispatchEvent(new Event("input"));
    click(labelled("Ask"));

    editor.showProposal({ regions: [], ops: [], note: "Nothing on this page matches that." });

    expect(labelled("Ask").disabled).toBe(false);
    expect(notice().textContent).toBe("Nothing on this page matches that.");
    expect(pendingChips()).toHaveLength(0);
  });

  it("says something even when the app cannot say why", () => {
    editor.promptFailed("   ");
    expect(notice().hidden).toBe(false);
    expect(notice().textContent?.length).toBeGreaterThan(0);
  });
});

describe("proposals", () => {
  beforeEach(() => editor.mount(CATALOG, []));

  it("highlights the regions it names and applies nothing until Apply", () => {
    editor.showProposal(PROPOSAL);

    // The proposal's region resolves to r0 through its selector, and is marked
    // distinctly from a user selection.
    expect(regions()[0]!.hasAttribute("data-proposed")).toBe(true);
    expect(regions()[0]!.hasAttribute("data-selected")).toBe(false);
    expect(regions()[1]!.hasAttribute("data-proposed")).toBe(false);

    // Described in the user's words, not in op kinds.
    expect(pendingChips().map((chip) => chip.querySelector(".note")?.textContent)).toEqual([
      "hide the suggestions",
      "narrow the rail",
    ]);
    expect(one(".proposal .lead").textContent).toContain("Two changes to the rail.");

    // Nothing committed: no draft chips, nothing saved, Save still inert.
    expect(draftChips()).toHaveLength(0);
    expect(labelled("Save Lens").disabled).toBe(true);
    expect(drafts).toEqual([]);

    click(labelled("Apply"));

    expect(draftChips().map((chip) => chip.querySelector(".note")?.textContent)).toEqual([
      "hide the suggestions",
      "narrow the rail",
    ]);
    expect(shadow.querySelector(".proposal")?.hasAttribute("hidden")).toBe(true);
    expect(regions()[0]!.hasAttribute("data-proposed")).toBe(false);
    // The draft's reach is now shown on the page instead.
    expect(regions()[0]!.hasAttribute("data-touched")).toBe(true);
    expect(drafts).toEqual([]);
  });

  it("discards without trace", () => {
    editor.showProposal(PROPOSAL);
    click(labelled("Discard"));

    expect(pendingChips()).toHaveLength(0);
    expect(draftChips()).toHaveLength(0);
    expect(regions()[0]!.hasAttribute("data-proposed")).toBe(false);
  });

  it("tolerates a malformed proposal instead of taking the dispatcher down", () => {
    // The proposal crosses a JSON boundary, so its shape is a claim. A missing
    // array should cost a highlight, never the command loop that delivered it.
    const malformed = {
      regions: [{ id: "rail", intent: "the rail" }],
      ops: [{ id: "op-9", kind: "hide", region: "rail", note: "hide it" }],
    } as unknown as LensProposal;

    expect(() => editor.showProposal(malformed)).not.toThrow();
    expect(pendingChips()).toHaveLength(1);
    expect(regions().some((node) => node.hasAttribute("data-proposed"))).toBe(false);

    click(labelled("Apply"));
    expect(draftChips()).toHaveLength(1);
  });

  it("refuses an op naming a region the proposal does not carry", () => {
    // Such an op cannot travel: `save` only sends the regions its ops reference,
    // so this would build a lens whose op names nothing — which the app rejects
    // whole, taking the good ops with it.
    editor.showProposal({
      regions: [{ id: "rail", intent: "the rail", selectors: ["#r0"] }],
      ops: [
        { id: "op-a", kind: "hide", region: "rail", note: "hide the rail" },
        { id: "op-b", kind: "hide", region: "invented", note: "hide something else" },
        { id: "op-c", kind: "move", region: "rail", target: "invented", note: "move it there" },
      ],
      note: "",
    });

    expect(pendingChips().map((chip) => chip.querySelector(".note")?.textContent)).toEqual([
      "hide the rail",
    ]);

    click(labelled("Apply"));
    prompt().value = "hide the rail";
    click(labelled("Save Lens"));

    const lens = drafts[0]!;
    const known = new Set(lens.regions.map((region) => region.id));
    expect(lens.ops.map((op) => op.id)).toEqual(["op-a"]);
    expect(lens.ops.every((op) => known.has(op.region))).toBe(true);
  });

  it("queues a second answer instead of discarding the first", () => {
    editor.showProposal(PROPOSAL);
    editor.showProposal({
      regions: [{ id: "feed", intent: "the feed", selectors: ["#r1"] }],
      ops: [{ id: "op-1", kind: "hide", region: "feed", note: "hide the feed" }],
      note: "One more.",
    });

    // Nothing the user has not answered may vanish — including on an op id the
    // second answer happens to reuse.
    expect(pendingChips().map((chip) => chip.querySelector(".note")?.textContent)).toEqual([
      "hide the suggestions",
      "narrow the rail",
      "hide the feed",
    ]);
    expect(regions()[0]!.hasAttribute("data-proposed")).toBe(true);
    expect(regions()[1]!.hasAttribute("data-proposed")).toBe(true);

    click(labelled("Apply"));
    expect(draftChips()).toHaveLength(3);
    expect(new Set(draftChips().map((chip) => chip.dataset.op)).size).toBe(3);
  });

  it("keeps two queued answers' region ids apart from each other", () => {
    // Region ids are lens-local, and a queued proposal is its own group: two
    // answers that both call something "r1" mean two different elements. Renaming
    // through one shared map rewrites the *first* group's ops as well, so both
    // hides land on the second group's element — the sidebar survives and the
    // comments are hidden twice. A wrong-box hide is the failure the namespacing
    // exists to prevent.
    editor.showProposal({
      regions: [{ id: "r1", intent: "the sidebar", selectors: ["#r0"] }],
      ops: [{ id: "a-1", kind: "hide", region: "r1", note: "hide the sidebar" }],
      note: "",
    });
    editor.showProposal({
      regions: [{ id: "r1", intent: "the comments", selectors: ["#r1"] }],
      ops: [{ id: "b-1", kind: "hide", region: "r1", note: "hide the comments" }],
      note: "",
    });

    click(labelled("Apply"));
    prompt().value = "tidy up";
    click(labelled("Save Lens"));

    const lens = drafts[0]!;
    const sidebar = lens.ops.find((op) => op.note === "hide the sidebar")!;
    const comments = lens.ops.find((op) => op.note === "hide the comments")!;
    expect(sidebar.region).not.toBe(comments.region);
    expect(lens.regions.find((region) => region.id === sidebar.region)?.selectors).toEqual(["#r0"]);
    expect(lens.regions.find((region) => region.id === comments.region)?.selectors).toEqual([
      "#r1",
    ]);
    // Both regions survive `save()`, which keeps only what an op still names.
    expect(lens.regions).toHaveLength(2);
  });

  it("ignores a proposal that arrives after the editor closed", () => {
    editor.unmount();
    expect(() => editor.showProposal(PROPOSAL)).not.toThrow();
    expect(document.getElementById(HOST_ID)).toBeNull();
  });
});

describe("chips", () => {
  it("removes one without disturbing the others", () => {
    editor.mount(CATALOG, []);
    acceptProposal();

    click(draftChips()[0]!.querySelector(".x")!);

    expect(draftChips().map((chip) => chip.querySelector(".note")?.textContent)).toEqual([
      "narrow the rail",
    ]);

    prompt().value = "narrow the rail";
    click(labelled("Save Lens"));
    expect(drafts[0]!.ops.map((op) => op.id)).toEqual(["op-2"]);
  });

  it("drops one pending op without discarding the rest of the proposal", () => {
    editor.mount(CATALOG, []);
    editor.showProposal(PROPOSAL);

    click(pendingChips()[1]!.querySelector(".x")!);
    expect(pendingChips()).toHaveLength(1);

    click(labelled("Apply"));
    expect(draftChips().map((chip) => chip.querySelector(".note")?.textContent)).toEqual([
      "hide the suggestions",
    ]);
  });

  it("shows the edited lens as chips attributed to it", () => {
    editor.mount(CATALOG, [existingLens()], "lens-existing");

    expect(draftChips().map((chip) => chip.querySelector(".note")?.textContent)).toEqual([
      "hide the rail",
      "calm the colours",
    ]);
    expect(draftChips().map((chip) => chip.querySelector(".lens")?.textContent)).toEqual([
      "Focus",
      "Focus",
    ]);

    // Revising a lens is deleting a chip and saving.
    click(draftChips()[1]!.querySelector(".x")!);
    click(labelled("Save Lens"));

    expect(drafts[0]!.ops.map((op) => op.note)).toEqual(["hide the rail"]);
    expect(drafts[0]!.regions.map((region) => region.id)).toEqual(["rail"]);
    expect(drafts[0]!.name).toBe("Focus");
  });

  it("keeps a proposal's region ids apart from the edited lens's", () => {
    // Region ids are lens-local: the model naming a region "rail" does not make
    // it the rail the stored lens meant, and merging them would repoint an op at
    // another element — a hide landing on the wrong box.
    editor.mount(CATALOG, [existingLens()], "lens-existing");
    editor.showProposal({
      regions: [{ id: "rail", intent: "the left nav", selectors: ["#r1"] }],
      ops: [{ id: "new-1", kind: "hide", region: "rail", note: "hide the nav" }],
      note: "",
    });
    click(labelled("Apply"));
    click(labelled("Save Lens"));

    const lens = drafts[0]!;
    expect(lens.regions.map((region) => region.selectors[0])).toEqual(["#r0", "#r1"]);
    const nav = lens.ops.find((op) => op.note === "hide the nav")!;
    expect(nav.region).not.toBe("rail");
    expect(lens.regions.find((region) => region.id === nav.region)?.selectors).toEqual(["#r1"]);
  });

  it("keeps a proposal's harvest buckets apart from the edited lens's", () => {
    // Buckets and harvested field names are lens-local exactly as region ids are.
    // Merged unnamespaced, the cross-reference check keeps one harvest and both
    // inserts — and one insert then renders the *other* group's rows into the
    // page. Wrong content, injected, and nothing reports it.
    editor.mount(CATALOG, [harvestingLens()], "lens-existing");
    editor.showProposal({
      regions: [
        { id: "list", intent: "the comment list", selectors: ["#r2"] },
        { id: "top", intent: "the header", selectors: ["#r1"] },
      ],
      ops: [
        {
          id: "h-2",
          kind: "harvest",
          region: "list",
          note: "collect the comments",
          harvest: {
            itemSelector: ":scope > div",
            fields: [{ name: "title", selector: "h3", attribute: "text" }],
            into: "items",
          },
        },
        {
          id: "i-2",
          kind: "insert",
          region: "top",
          note: "list them at the top",
          target: "top",
          bucket: "items",
          sort: { key: "harvestedField", field: "title", ascending: false },
        },
      ],
      note: "",
    });
    click(labelled("Apply"));
    click(labelled("Save Lens"));

    const lens = drafts[0]!;
    const harvests = lens.ops.filter((op) => op.kind === "harvest");
    const inserts = lens.ops.filter((op) => op.kind === "insert");

    // Two harvests that survive as two buckets…
    const buckets = harvests.map((op) => op.harvest!.into);
    expect(new Set(buckets).size).toBe(2);
    // …and every insert reads the bucket its own group filled.
    expect(inserts.map((op) => op.bucket)).toEqual([
      harvests[0]!.harvest!.into,
      harvests[1]!.harvest!.into,
    ]);
    // The same for the field names a sort references.
    const fields = harvests.map((op) => op.harvest!.fields[0]!.name);
    expect(new Set(fields).size).toBe(2);
    expect(inserts.map((op) => op.sort?.field)).toEqual([fields[0], fields[1]]);
  });

  it("leaves a bucket the group did not harvest pointing where it pointed", () => {
    // A proposal may legitimately insert into a bucket the lens being edited
    // already fills; only names a group *declares* are renamed.
    editor.mount(CATALOG, [harvestingLens()], "lens-existing");
    editor.showProposal({
      regions: [{ id: "top", intent: "the header", selectors: ["#r1"] }],
      ops: [
        {
          id: "i-2",
          kind: "insert",
          region: "top",
          note: "list them at the top too",
          target: "top",
          bucket: "items",
        },
      ],
      note: "",
    });
    click(labelled("Apply"));
    click(labelled("Save Lens"));

    const lens = drafts[0]!;
    expect(lens.ops.find((op) => op.id === "i-2")?.bucket).toBe("items");
  });
});

describe("scope", () => {
  const patternFor = (label: string): Lens => {
    editor.mount(CATALOG, []);
    acceptProposal();
    click(labelled(label));
    prompt().value = "hide the suggestions rail";
    click(labelled("Save Lens"));
    return drafts[drafts.length - 1]!;
  };

  it("maps the three choices onto the three patterns matchingLenses understands", () => {
    expect(patternFor("This page").pathPattern).toBe("/");
    expect(patternFor("Pages like this").pathPattern).toBe("/watch");
    expect(patternFor("Whole site").pathPattern).toBe("*");
  });

  it("shows the literal pattern under the control", () => {
    editor.mount(CATALOG, []);
    expect(one(".pattern").textContent).toBe("example.com/watch");

    click(labelled("Whole site"));
    expect(one(".pattern").textContent).toBe("example.com/*");

    click(labelled("This page"));
    expect(one(".pattern").textContent).toBe("example.com/");
  });

  it("keeps an edited lens's own pattern until the user picks another", () => {
    // The store's patterns are richer than these three controls, so re-deriving
    // one would quietly move a lens off the pages it was written for.
    editor.mount(CATALOG, [existingLens({ pathPattern: "/posts/*/*" })], "lens-existing");
    expect(one(".pattern").textContent).toBe("example.com/posts/*/*");

    click(labelled("Save Lens"));
    expect(drafts[0]!.pathPattern).toBe("/posts/*/*");

    editor.mount(CATALOG, [existingLens({ pathPattern: "/posts/*/*" })], "lens-existing");
    click(labelled("Whole site"));
    click(labelled("Save Lens"));
    expect(drafts[1]!.pathPattern).toBe("*");
  });
});

describe("saving", () => {
  it("emits a lens the app can persist, then closes", () => {
    editor.mount(CATALOG, []);
    prompt().value = "hide the suggestions rail on watch pages";
    acceptProposal();
    // Applying clears the field; the words are still what names the lens.
    expect(prompt().value).toBe("");

    click(labelled("Save Lens"));

    expect(drafts).toHaveLength(1);
    const lens = drafts[0]!;
    expect(lens.id).toMatch(/\S/);
    expect(lens.name).toBe("Hide the suggestions rail on watch pages");
    expect(lens.origin).toBe("example.com");
    expect(lens.pathPattern).toBe("/watch");
    expect(lens.isEnabled).toBe(true);
    expect(lens.prompt).toBe("hide the suggestions rail on watch pages");
    expect(lens.schemaVersion).toBe(1);
    expect(lens.ops.map((op) => op.kind)).toEqual(["hide", "width"]);
    expect(lens.regions).toEqual(PROPOSAL.regions);
    expect(Number.isNaN(Date.parse(lens.createdAt))).toBe(false);
    expect(lens.createdAt).toBe(lens.updatedAt);

    expect(document.getElementById(HOST_ID)).toBeNull();
  });

  it("will not save a lens with nothing in it", () => {
    editor.mount(CATALOG, []);
    prompt().value = "do something";

    expect(labelled("Save Lens").disabled).toBe(true);
    click(labelled("Save Lens"));
    expect(drafts).toEqual([]);
    expect(document.getElementById(HOST_ID)).not.toBeNull();
  });

  it("stacks a new lens above the ones already on the site", () => {
    // Stacking is `updatedAt`, newest wins — there is no `order` field any more.
    // A lens saved now is by construction the most recently touched one on the
    // site, so it wins wherever it overlaps an older lens, the way a later style
    // rule does. Asserting that is asserting the whole precedence model.
    const older = existingLens();
    editor.mount(CATALOG, [older, existingLens({ id: "lens-2", name: "Wide" })]);
    acceptProposal();
    click(labelled("Save Lens"));

    const saved = drafts[0]!;
    expect(Date.parse(saved.updatedAt)).toBeGreaterThan(Date.parse(older.updatedAt));
  });

  it("replaces the lens it was editing rather than writing a second one", () => {
    // The id is the whole of it: without it the app cannot find the record, so
    // it inserts, and the site ends up with both lenses enabled and every op
    // applied twice.
    const lens = existingLens({ isEnabled: false });
    const other = existingLens({ id: "lens-other", name: "Wide" });
    editor.mount(CATALOG, [other, lens], "lens-existing");
    acceptProposal();
    click(labelled("Save Lens"));

    const draft = drafts[0]!;
    expect(draft.id).toBe("lens-existing");
    expect(draft.name).toBe("Focus");
    expect(draft.isEnabled).toBe(false);
    expect(draft.prompt).toBe("hide the noise");
    expect(draft.createdAt).toBe("2026-01-01T00:00:00.000Z");
    expect(draft.updatedAt).not.toBe(draft.createdAt);
    // Its own ops plus the accepted ones — and nothing belonging to "Wide".
    expect(draft.ops.map((op) => op.id)).toEqual(["old-1", "old-2", "op-1", "op-2"]);
  });

  it("renames an edited lens only when the user retypes the ask", () => {
    editor.mount(CATALOG, [existingLens()], "lens-existing");
    prompt().value = "keep only the article";
    click(labelled("Save Lens"));

    expect(drafts[0]!.name).toBe("Keep only the article");
    expect(drafts[0]!.prompt).toBe("keep only the article");
  });
});

describe("a saved lens carries the box the user pointed at", () => {
  // The full loop, end to end, because each half is inert without the other: a
  // fingerprint written at save time and never read is dead code, and a runner
  // that reads one nobody wrote resolves nothing. Both were true of this feature
  // until now — `fingerprint.ts` was imported by no module and tree-shaken out of
  // both bundles while its own unit tests passed.
  //
  // The failure being prevented is the measured one. On four of five live sites
  // the preferred anchor is a structural path or a build hash, and a redesign
  // leaves those matching a *different* element — so the lens acts on the wrong
  // box and reports `applied`, which no badge can see.

  /** The page on the day the user pointed at the rail. */
  const AUTHORED = `
    <div id="page">
      <main id="content"><p>The article the user was reading that day.</p></main>
      <aside class="rail sidebar" role="complementary" data-testid="sidebarColumn">
        <h2>Suggested</h2>
        <p>Godwits, dunlin and knot arrive together when the tide turns.</p>
        <p>Curlews came back in numbers nobody expected after the restoration.</p>
      </aside>
    </div>
  `;

  /** The same page after a redesign put a promo box in front of the rail. Both of
   * the lens's anchors now match two elements and the impostor is first in
   * document order, so first-match resolution lands squarely on it. */
  const REDESIGNED = `
    <div id="page">
      <aside class="rail" data-promo><p>Subscribe</p></aside>
      <main id="content"><p>The article the user was reading that day.</p></main>
      <aside class="rail sidebar" role="complementary" data-testid="sidebarColumn">
        <h2>Suggested</h2>
        <p>Godwits, dunlin and knot arrive together when the tide turns.</p>
        <p>Curlews came back in numbers nobody expected after the restoration.</p>
      </aside>
    </div>
  `;

  const RAIL_PROPOSAL: LensProposal = {
    regions: [
      {
        id: "rail",
        intent: "the suggestions rail",
        selectors: ["aside.rail", "body>div>aside"],
      },
    ],
    ops: [
      { id: "op-1", kind: "label", region: "rail", note: "mark the rail", text: "Suggestions" },
    ],
    note: "One label on the rail.",
  };

  /** Author the lens against `AUTHORED`, the way a user does: point, apply, save. */
  function authorRailLens(): Lens {
    document.body.innerHTML = AUTHORED;
    editor.mount(CATALOG, []);
    editor.showProposal(RAIL_PROPOSAL);
    click(labelled("Apply"));
    prompt().value = "mark the suggestions rail";
    click(labelled("Save Lens"));

    const saved = drafts[0];
    if (!saved) throw new Error("the editor saved nothing");
    return saved;
  }

  it("finds the rail again after every anchor on the lens has drifted onto another box", () => {
    const saved = authorRailLens();
    expect(saved.regions[0]?.fingerprint?.tag).toBe("aside");

    document.body.innerHTML = REDESIGNED;
    const impostor = document.querySelectorAll("#page > aside")[0] as Element;
    const rail = document.querySelectorAll("#page > aside")[1] as Element;
    // Both anchors really do name the impostor now — otherwise this would be
    // testing nothing at all.
    expect(document.querySelector("aside.rail")).toBe(impostor);
    expect(document.querySelector("body>div>aside")).toBe(impostor);

    const reports = runStructuralOps(document, [saved], {
      journal: new LensJournal(document),
      harvests: new HarvestStore(),
    });

    expect(rail.querySelector("zentic-lens-label")).not.toBeNull();
    expect(impostor.querySelector("zentic-lens-label")).toBeNull();
    const outcome = reports[0]?.results[0];
    expect(outcome?.status).toBe("applied");
    expect(outcome?.usedSelector).toBeUndefined();
    expect(outcome?.message).toBe(
      "the region's selectors no longer match; the element was found by its structure",
    );
  });

  it("takes the print from the element the anchors name uniquely, not the first of several", () => {
    // A selector matching a hundred and sixty boxes "resolves" to whichever is
    // first in document order. Fingerprinting that one would store a signature of
    // a box the user never pointed at — worse than storing none, because the
    // runner would then believe it.
    document.body.innerHTML = `
      <div id="page">
        <aside class="rail"><p>One</p></aside>
        <aside class="rail"><p>Two</p></aside>
      </div>
    `;
    editor.mount(CATALOG, []);
    editor.showProposal(RAIL_PROPOSAL);
    click(labelled("Apply"));
    click(labelled("Save Lens"));

    expect(drafts[0]?.regions[0]?.fingerprint).toBeUndefined();
  });

  it("saves no fingerprint for a region this page does not have", () => {
    // Authoring a lens whose region is absent — an edit made from a page the lens
    // was not written for. Minting a print from an element nobody found is the
    // confident wrong answer the whole mechanism exists to refuse.
    document.body.innerHTML = `<div id="page"><main id="content"><p>Just an article.</p></main></div>`;
    editor.mount(CATALOG, []);
    editor.showProposal(RAIL_PROPOSAL);
    click(labelled("Apply"));
    click(labelled("Save Lens"));

    expect(drafts[0]?.regions[0]?.fingerprint).toBeUndefined();
    expect(drafts[0]?.regions).toEqual(RAIL_PROPOSAL.regions);
  });
});

describe("keyboard", () => {
  it("cancels on Esc without saving anything", () => {
    editor.mount(CATALOG, []);
    acceptProposal();

    press(prompt(), "Escape");

    expect(document.getElementById(HOST_ID)).toBeNull();
    expect(drafts).toEqual([]);
    // The app has to hear it, or its next ⌥⌘L spends itself closing a closed
    // editor.
    expect(closes).toBe(1);
  });

  it("saves on Cmd-Enter", () => {
    editor.mount(CATALOG, []);
    prompt().value = "hide the rail";
    acceptProposal();

    press(regions()[0]!, "Enter", { metaKey: true });
    expect(drafts).toHaveLength(1);
    expect(closes).toBe(1);
  });

  it("moves focus into the overlay, cycles regions with Tab and selects with Enter", () => {
    editor.mount(CATALOG, []);
    expect(shadow.activeElement).toBe(prompt());

    // The prompt does not trap Tab.
    press(prompt(), "Tab");
    expect(shadow.activeElement).not.toBe(prompt());

    regions()[0]!.focus();
    press(regions()[0]!, "Tab");
    expect(shadow.activeElement).toBe(regions()[1]!);

    press(regions()[1]!, "Tab", { shiftKey: true });
    expect(shadow.activeElement).toBe(regions()[0]!);

    press(regions()[0]!, "Enter");
    expect(selectedIDs()).toEqual(["r0"]);

    press(regions()[0]!, "Enter", { shiftKey: true });
    expect(selectedIDs()).toEqual([]);
  });

  it("activates the focused control when a click carries no coordinates", () => {
    // Space on a focused button synthesises a click with `detail: 0` and nothing
    // to hit-test. The seal has to answer that from the focus ring: hit-testing
    // it would put the press through whatever sits at the top-left corner.
    editor.mount(CATALOG, []);
    const region = regions()[1]!;
    region.focus();
    // Whatever the engine would report at the origin — here, a different region.
    (shadow as unknown as { elementFromPoint: () => Element }).elementFromPoint = () =>
      regions()[0]!;

    region.dispatchEvent(new MouseEvent("click", { bubbles: true, composed: true }));

    expect(selectedIDs()).toEqual(["r1"]);
  });

  it("takes a printable key on a region straight to the prompt", () => {
    editor.mount(CATALOG, []);
    regions()[1]!.focus();

    press(regions()[1]!, "h");

    expect(shadow.activeElement).toBe(prompt());
    expect(prompt().value).toBe("h");
  });
});

describe("isolation from the page", () => {
  /**
   * Everything a page-world listener managed to observe.
   *
   * Both phases, on both `document` and `window`, because the phase is the whole
   * of the bug this covers: a seal on the shadow root fires on the way *out*, and
   * a page listener registered in the capture phase has already seen the event on
   * the way *down*. A bubble-only spy passes against code that leaks every
   * keystroke.
   */
  function eavesdrop(types: string[]): { seen: string[]; stop: () => void } {
    const seen: string[] = [];
    const targets: Array<[EventTarget, string]> = [
      [document, "document"],
      [window, "window"],
    ];
    const made: Array<() => void> = [];

    for (const [target, name] of targets) {
      for (const capture of [true, false]) {
        const record = (event: Event) =>
          seen.push(`${name}:${event.type}:${capture ? "capture" : "bubble"}`);
        for (const type of types) {
          target.addEventListener(type, record, capture);
          made.push(() => target.removeEventListener(type, record, capture));
        }
      }
    }

    return {
      seen,
      stop: () => {
        for (const off of made) off();
      },
    };
  }

  it("does not let page script read the prompt or the pointer", () => {
    // A closed shadow root hides the tree, not the events: a composed `keydown`
    // bubbles out retargeted to the host and reaches any page listener with
    // `event.key` intact, and pointer events carry coordinates precise enough to
    // say which box was picked. Content worlds isolate JS scopes, not the DOM
    // event system, so the overlay has to seal these itself — and it has to do it
    // before the capture phase reaches the page, not after.
    editor.mount(CATALOG, []);
    const spy = eavesdrop([
      "keydown",
      "keyup",
      "keypress",
      "beforeinput",
      "input",
      "paste",
      "pointerdown",
      "pointerup",
      "mousedown",
      "mouseup",
      "mousemove",
      "click",
    ]);

    try {
      for (const key of ["h", "i", "d", "e"]) {
        prompt().dispatchEvent(
          new KeyboardEvent("keydown", { key, bubbles: true, composed: true }),
        );
        prompt().dispatchEvent(new KeyboardEvent("keyup", { key, bubbles: true, composed: true }));
      }
      prompt().value = "hide";
      prompt().dispatchEvent(new Event("input", { bubbles: true, composed: true }));
      prompt().dispatchEvent(new Event("beforeinput", { bubbles: true, composed: true }));
      prompt().dispatchEvent(new Event("paste", { bubbles: true, composed: true }));

      const region = regions()[1]!;
      for (const type of ["pointerdown", "mousedown", "mousemove", "mouseup", "pointerup"]) {
        region.dispatchEvent(
          new MouseEvent(type, { bubbles: true, composed: true, clientX: 640, clientY: 320 }),
        );
      }
      click(region);

      expect(spy.seen).toEqual([]);
    } finally {
      spy.stop();
    }

    // The selection still happened — the seal stops propagation, never the
    // default, or it would stop the typing along with the leak.
    expect(selectedIDs()).toEqual(["r1"]);
    expect(prompt().value).toBe("hide");
  });

  it("still lets Escape reach the overlay from outside it", () => {
    // The seal is on the shadow root; the document capture listener that catches
    // Escape when focus is in the page runs before it, and must keep working.
    editor.mount(CATALOG, []);
    document.getElementById("anchor")?.focus();

    press(document.body, "Escape");
    expect(document.getElementById(HOST_ID)).toBeNull();
  });
});

describe("reflow", () => {
  /** A live element for a catalog entry, with a geometry we control: jsdom has
   * no layout, so the box has to be supplied. */
  function place(id: string, box: { x: number; y: number; width: number; height: number }): void {
    let node = document.getElementById(id);
    if (!node) {
      node = document.createElement("div");
      node.id = id;
      document.body.appendChild(node);
    }
    node.getBoundingClientRect = () =>
      ({
        x: box.x,
        y: box.y,
        left: box.x,
        top: box.y,
        right: box.x + box.width,
        bottom: box.y + box.height,
        width: box.width,
        height: box.height,
        toJSON: () => box,
      }) as DOMRect;
  }

  it("re-measures the outlines when the page reflows", () => {
    vi.useFakeTimers();
    try {
      place("r0", { x: 20, y: 40, width: 100, height: 80 });
      place("r1", { x: 20, y: 40, width: 100, height: 80 });
      place("r2", { x: 0, y: 0, width: 0, height: 0 });

      editor.mount(CATALOG, []);
      expect(regions()[0]!.style.left).toBe("20px");

      // A narrower window, a font swap, a lazy image: the catalog's rects are a
      // one-shot snapshot, and an outline over the wrong element is worse than
      // no outline when selection is done by pointing.
      place("r0", { x: 300, y: 500, width: 240, height: 90 });
      place("r2", { x: 0, y: 700, width: 400, height: 30 });
      window.dispatchEvent(new Event("resize"));

      // Debounced: a drag-resize is one re-measure, not sixty.
      expect(regions()[0]!.style.left).toBe("20px");
      vi.advanceTimersByTime(200);

      expect(regions()[0]!.style.left).toBe("300px");
      expect(regions()[0]!.style.top).toBe("500px");
      expect(regions()[0]!.style.width).toBe("240px");
      // The stacking is derived from the geometry, so it is re-derived too: a
      // reflow can turn the tightest box under the pointer into the widest one,
      // and an order fixed at build time would go on handing the pointer to the
      // wrong region.
      expect(Number(regions()[0]!.style.zIndex)).toBeLessThan(
        Number(regions()[1]!.style.zIndex),
      );

      // A box that gains a geometry stops claiming it has none.
      expect(regions()[2]!.hasAttribute("data-empty")).toBe(false);
      expect(regions()[2]!.style.height).toBe("30px");
    } finally {
      vi.useRealTimers();
    }
  });

  it("re-measures when the document reflows without a resize", () => {
    // The common case, and the one `resize` cannot see: a lazy image below the
    // fold decodes, or a webfont swaps, and every outline under it sits hundreds
    // of pixels off its element. The window never fired anything.
    vi.useFakeTimers();
    const view = window as unknown as { ResizeObserver?: unknown };
    const before = view.ResizeObserver;
    const observing: Element[] = [];
    let reflow: (() => void) | undefined;

    // jsdom has no layout and therefore no ResizeObserver. The stub is the engine
    // half of the contract: observe the root box, call back when it changes.
    view.ResizeObserver = class {
      constructor(callback: () => void) {
        reflow = callback;
      }
      observe(target: Element): void {
        observing.push(target);
      }
      disconnect(): void {
        reflow = undefined;
      }
    };

    try {
      place("r0", { x: 20, y: 40, width: 100, height: 80 });
      editor.mount(CATALOG, []);
      expect(observing).toContain(document.documentElement);

      place("r0", { x: 300, y: 500, width: 240, height: 90 });
      reflow?.();

      // Debounced with the resize path, so a reflow storm costs one re-measure.
      expect(regions()[0]!.style.left).toBe("20px");
      vi.advanceTimersByTime(200);
      expect(regions()[0]!.style.left).toBe("300px");

      // And it goes with the overlay: an observer left running would keep a
      // detached layer alive for the life of the page.
      editor.unmount();
      expect(reflow).toBeUndefined();
    } finally {
      view.ResizeObserver = before;
      vi.useRealTimers();
    }
  });

  it("keeps the last known box for an element the page removed", () => {
    vi.useFakeTimers();
    try {
      editor.mount(CATALOG, []);
      window.dispatchEvent(new Event("resize"));
      vi.advanceTimersByTime(200);

      // Nothing in the document matches these selectors, so snapping every
      // outline to the origin would put three clickable boxes on one corner.
      expect(regions()[0]!.style.left).toBe("20px");
      expect(regions()[0]!.style.width).toBe("100px");
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("leaving no trace", () => {
  it("restores the document, its listeners and its focus", () => {
    const before = document.documentElement.outerHTML;
    const anchor = document.getElementById("anchor") as HTMLElement;
    anchor.focus();

    const outstanding = trackListeners();
    editor.mount(CATALOG, []);
    editor.showProposal(PROPOSAL);
    click(labelled("Apply"));
    click(regions()[0]!);

    editor.unmount();
    outstanding.restore();

    expect(document.getElementById(HOST_ID)).toBeNull();
    expect(document.querySelectorAll("[id^='zentic-']")).toHaveLength(0);
    expect(document.documentElement.outerHTML).toBe(before);
    expect(outstanding.open()).toEqual([]);
    expect(document.activeElement).toBe(anchor);
  });

  it("leaves nothing behind when it closes over an unanswered proposal", () => {
    const before = document.documentElement.outerHTML;
    const outstanding = trackListeners();

    editor.mount(CATALOG, []);
    editor.showProposal(PROPOSAL);
    editor.unmount();
    outstanding.restore();

    expect(outstanding.open()).toEqual([]);
    expect(document.documentElement.outerHTML).toBe(before);
    expect(drafts).toEqual([]);
    expect(closes).toBe(1);
  });

  it("closes cleanly from inside a handler the teardown is about to remove", () => {
    const outstanding = trackListeners();
    editor.mount(CATALOG, []);

    // Esc is handled by a listener that the same call stack removes.
    expect(() => press(prompt(), "Escape")).not.toThrow();
    outstanding.restore();
    expect(outstanding.open()).toEqual([]);
    expect(closes).toBe(1);
  });

  it("survives an onClose that closes it again", () => {
    // The callback is the app's, and an app that answers a close by sending
    // `exitLensMode` would otherwise recurse until the stack ran out.
    const reentrant = createLensEditor(document);
    reentrant.onClose(() => reentrant.unmount());

    reentrant.mount(CATALOG, []);
    expect(() => reentrant.unmount()).not.toThrow();
    expect(document.getElementById(HOST_ID)).toBeNull();
  });

  it("tears itself down when the page removes the host", async () => {
    const outstanding = trackListeners();
    editor.mount(CATALOG, []);

    // A page that empties `<body>` takes the overlay with it. The document-level
    // capture listener would otherwise stay installed, swallowing Escape from a
    // page nobody is editing.
    document.getElementById(HOST_ID)!.remove();
    await Promise.resolve();
    await Promise.resolve();

    outstanding.restore();
    expect(outstanding.open()).toEqual([]);
    expect(closes).toBe(1);
  });

  it("mounts again after unmounting, with fresh state", () => {
    editor.mount(CATALOG, []);
    acceptProposal();
    click(regions()[0]!);
    editor.unmount();

    editor.mount(CATALOG, []);

    expect(document.querySelectorAll(`#${HOST_ID}`)).toHaveLength(1);
    expect(regions()).toHaveLength(3);
    expect(draftChips()).toHaveLength(0);
    expect(selectedIDs()).toEqual([]);
    expect(labelled("Save Lens").disabled).toBe(true);
  });

  it("mounting twice without unmounting leaves one overlay and reports no close", () => {
    editor.mount(CATALOG, []);
    editor.mount(CATALOG, [existingLens()], "lens-existing");

    expect(document.querySelectorAll(`#${HOST_ID}`)).toHaveLength(1);
    expect(draftChips()).toHaveLength(2);
    // A remount is not a close: telling the app otherwise leaves it thinking the
    // editor it just opened is shut, and the caret bounces through the page.
    expect(closes).toBe(0);
    expect(shadow.activeElement).toBe(prompt());
  });
});

/**
 * Count listeners added to the document and the window and not removed again.
 *
 * There is no way to read a listener list back out of the DOM, so the only
 * honest check is to watch the calls — including the capture flag, because
 * `removeEventListener` without it does not remove a capture listener, and a
 * tracker that ignored it would call that balanced. Listeners on nodes inside
 * the host go with the host; these two are the ones that could outlive it.
 */
function trackListeners(): { open: () => string[]; restore: () => void } {
  const open: string[] = [];
  const targets: EventTarget[] = [document, window];
  const originals = targets.map((target) => ({
    target,
    add: target.addEventListener,
    remove: target.removeEventListener,
  }));

  const capture = (options: unknown): boolean => {
    if (options === true) return true;
    if (typeof options !== "object" || options === null) return false;
    return (options as AddEventListenerOptions).capture === true;
  };

  for (const entry of originals) {
    const name = entry.target === document ? "document" : "window";
    Object.defineProperty(entry.target, "addEventListener", {
      configurable: true,
      value: (type: string, ...rest: unknown[]) => {
        open.push(`${name}:${type}:${capture(rest[1])}`);
        return (entry.add as Function).call(entry.target, type, ...rest);
      },
    });
    Object.defineProperty(entry.target, "removeEventListener", {
      configurable: true,
      value: (type: string, ...rest: unknown[]) => {
        const index = open.indexOf(`${name}:${type}:${capture(rest[1])}`);
        if (index >= 0) open.splice(index, 1);
        return (entry.remove as Function).call(entry.target, type, ...rest);
      },
    });
  }

  return {
    open: () => open,
    restore: () => {
      // Put the originals back rather than deleting the override: on a jsdom
      // window these are own properties, and deleting them takes the real
      // method with them.
      for (const entry of originals) {
        Object.defineProperty(entry.target, "addEventListener", {
          configurable: true,
          value: entry.add,
        });
        Object.defineProperty(entry.target, "removeEventListener", {
          configurable: true,
          value: entry.remove,
        });
      }
    },
  };
}
