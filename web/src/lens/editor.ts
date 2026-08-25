import { buildFingerprint } from "./fingerprint.js";
import { isOurs } from "./regions.js";
import { safeRegionSelector } from "./selectors.js";
import type {
  Lens,
  LensOp,
  LensProposal,
  LensRegion,
  RegionCandidate,
  RegionCatalog,
  RegionRect,
} from "../wire.js";

// The Lens editor: the surface where a user points at a page and says what they
// want gone.
//
// ## Why an overlay and not a panel in the app
//
// A lens is authored *against the page*, and the only place the page exists is
// the page. A sidebar in the app window would have to describe regions in words
// — "the third `<aside>`, 1200px down" — and the user would have to believe it.
// Here they hover a box and see the box light up. The whole trust story of this
// feature is that a selection is *seen* before it is applied.
//
// ## The governing rule: the model proposes a selection, never an effect
//
// A wrong region guess is one click from hiding someone's video player. So a
// prompt never reaches `ops.ts`. It goes to the app, the app answers with a
// `LensProposal`, and this file *highlights* the regions that proposal names, in
// a colour and a line style distinct from the user's own selection, next to
// chips saying in words what would happen. Nothing runs until Apply. There is
// deliberately no path from `onPrompt` to an effect that does not pass through a
// human eye.
//
// ## Authoring and editing are different jobs
//
// The editor is handed every lens the page has, but it adopts at most one of
// them. Adopting them all merges them: Save then mints one *new* lens holding
// every other lens's ops while the originals stay enabled, so every op applies
// twice and no lens can ever be revised. A lens becomes the draft only when
// `mount` names it in `editing`, and the draft then carries that lens's id —
// which is the whole of how the app tells "replace this record" from "write
// another one beside it". Every other lens shows as read-only context under its
// own name, so the user can see what else is acting on the page without it
// being absorbed into what they are writing.
//
// And an `editing` id with no lens behind it is refused rather than serviced.
// The app offers Edit on every lens the site has, including the ones switched off
// and the ones scoped to another path, while the page is only ever handed the set
// that is applied — so "edit a lens we were not given" is an ordinary request,
// and answering it by authoring is the same duplicate by a quieter route: a blank
// overlay, a fresh id, a third lens saved, and the lens the user pressed Edit on
// never touched. The editor cannot be talked into it from here whatever arrives
// on the wire.
//
// ## Why a closed shadow root, and why that alone is not enough
//
// Same reasoning as `render/view.ts`, plus one more: this chrome is *about* the
// page, so it sits on top of a document whose script is still live. Closed means
// page script holding the host cannot walk into the overlay — it cannot read the
// prompt out of the input, cannot enumerate the selection, cannot restyle a
// button into something that lies about what it does.
//
// What closed does *not* do is stop events. A `keydown` in our input is composed
// and bubbles out of the shadow root retargeted to the host, so a page-world
// `document.addEventListener("keydown", …)` reads the prompt one character at a
// time; a `pointerdown` carries coordinates precise enough to say which box was
// picked. The `zentic` content world isolates JS scopes, not the DOM event
// system.
//
// Sealing that on the way *out* is too late, and it is worth being precise about
// why, because a bubble-phase seal on the shadow root looks like it works and
// does not. An event reaches `window` and `document` in the CAPTURE phase first,
// on the way *down* to our input, and only afterwards passes back through the
// root. A page listener registered with `capture: true` has therefore already
// read `event.key` before any listener of ours runs. So the seal is a
// capture-phase listener at `window`, which is the first object in the path, and
// it calls `stopImmediatePropagation` for anything that originated inside our
// root. The root keeps a bubble-phase seal as a second line, for the case where
// the window listener could not be installed at all.
//
// Stopping the event at `window` stops it reaching our own listeners too, so
// anything the overlay needs is replayed inside the root as an uncomposed clone
// — an event that cannot leave a shadow root by construction. `REPLAYED_EVENTS`
// is that set, and it is closed: three types, because three is all the overlay
// listens to.
//
// This is best-effort, and the limit is worth naming: listeners on one node run
// in registration order, so a page that installed its own capture listener on
// `window` before the editor was opened still runs first. Nothing in the DOM can
// beat that. What this does close is every capture listener the page registers on
// `document`, on `<html>`, on `<body>`, on `window` after ⌥⌘L, and every
// bubble-phase listener anywhere.
//
// The host is a single `id="zentic-…"` div, which `regions.ts` already excludes
// from every catalog, so the editor can never offer itself as a region.
//
// ## Never touches the page
//
// The overlay draws over the document; it never writes to it. Applying ops is
// `ops.ts`'s job and happens after the draft has crossed to the app and come
// back as a saved lens. Which also means unmount has nothing to repair: remove
// the host, drop the listeners, hand focus back, and the page is exactly as it
// was found.
//
// ## Textless, like everything else on this path
//
// Nothing here reads `textContent` from the page. Region labels are built from
// tag names, ids and class tokens — the same fields `RegionCatalog` already
// carries — and chips show `LensOp.note`, which is the user's and the model's
// words about the page, never the page's own. Invariant 4.

export interface LensEditor {
  /**
   * Build the overlay. `editing` names the lens to revise, by id; without it
   * this is a new lens and nothing is adopted. An `editing` id that names none
   * of `lenses` is refused — never quietly turned into a new lens, which would
   * write a duplicate and leave the one the user asked to edit untouched.
   *
   * Returns whether the overlay is actually up, because the app announces lens
   * mode on the strength of this call and a mount that failed must not leave it
   * believing an editor is on screen.
   */
  mount(catalog: RegionCatalog, lenses: Lens[], editing?: string): boolean;
  unmount(): void;
  showProposal(proposal: LensProposal): void;
  /** The ask cannot be answered. Recovers the UI and says why. */
  promptFailed(message: string): void;
  onDraft(callback: (lens: Lens) => void): void;
  onPrompt(callback: (text: string, selectedRegionIDs: string[]) => void): void;
  /** Every way out — Esc, Cancel, Save, the page removing the host. */
  onClose(callback: () => void): void;
}

const HOST_ID = "zentic-lens-editor";

/** Mirrors `Lens.currentSchemaVersion` on the Swift side. A draft that claims a
 * version the app does not know is rejected at the door, so this is not a
 * detail the editor gets to be casual about. */
const LENS_SCHEMA_VERSION = 1;

/** A lens name is a label in a popover row, not a sentence. */
const MAX_NAME_LENGTH = 44;

/** How many of a region's candidates a fingerprint is taken against. The same
 * bound `ops.ts` puts on the runner — past it a candidate is never tried, so
 * resolving one here would fingerprint an element no op will ever reach. Named
 * separately rather than imported: `ops.ts` is the document-start bundle, and the
 * editor is the one that must not pull it in. */
const MAX_SELECTORS_TRIED = 8;

/** What an unnamed lens is called. Dull beats nameless in a popover row. */
const DEFAULT_LENS_NAME = "New Lens";

/** Said when the app cannot say why an ask failed. Never blank: the whole point
 * is that the user learns the editor is theirs again. */
const FAILED_PROMPT_MESSAGE = "That ask could not be answered. Nothing was changed.";

/** Other lenses are context, not a catalogue. Twelve chips is already more than
 * anyone reads; a site at the twelve-lens cap could otherwise put 480 in the bar. */
const MAX_CONTEXT_CHIPS = 12;

/**
 * Events sealed before the page can see them.
 *
 * Every one of them is composed, so without this each crosses the boundary
 * retargeted to the host and reaches page script: the key families spell out the
 * prompt, the clipboard families hand over what was pasted into it, and the
 * pointer families give away which region the user pointed at. Propagation only
 * — `preventDefault` here would stop the typing along with the leak, so a sealed
 * event's default action still runs and the user still types, pastes and clicks.
 */
const SEALED_EVENTS = [
  "keydown",
  "keyup",
  "keypress",
  "beforeinput",
  "input",
  "compositionstart",
  "compositionupdate",
  "compositionend",
  "paste",
  "copy",
  "cut",
  "pointerdown",
  "pointerup",
  "pointermove",
  "pointercancel",
  "mousedown",
  "mouseup",
  "mousemove",
  "click",
  "dblclick",
  "contextmenu",
  "touchstart",
  "touchmove",
  "touchend",
] as const;

/**
 * The sealed events the overlay itself listens to, and therefore the only ones
 * that have to be put back after the seal stops them.
 *
 * Closed deliberately, and small because the overlay's own wiring is small: the
 * prompt's `input`, the keyboard model's `keydown`, and `click` on every control.
 * Adding a listener inside the overlay for anything else in `SEALED_EVENTS`
 * without adding it here would leave that listener silently dead.
 */
const REPLAYED_EVENTS = new Set<string>(["keydown", "input", "click"]);

/** Long enough that a drag-resize costs one re-measure rather than sixty, short
 * enough that the outlines are right again before the user aims at one. */
const REMEASURE_DEBOUNCE_MS = 120;

/**
 * Host styles, every one of them `!important`.
 *
 * The host is the only part of the overlay a site's CSS can address, and a rule
 * as ordinary as `div { position: static }` would drop the whole editor into
 * document flow. `pointer-events: none` is the load-bearing one: it makes the
 * scrim inert so the page keeps scrolling and clicking underneath, and the parts
 * that must be interactive — region outlines, the prompt bar — opt back in with
 * `pointer-events: auto` inside the shadow root.
 */
const HOST_STYLE: Array<[string, string]> = [
  ["position", "fixed"],
  ["inset", "0"],
  ["z-index", "2147483647"],
  ["margin", "0"],
  ["padding", "0"],
  ["border", "0"],
  ["display", "block"],
  ["visibility", "visible"],
  ["opacity", "1"],
  ["overflow", "visible"],
  ["pointer-events", "none"],
  ["background", "transparent"],
  ["isolation", "isolate"],
  ["contain", "layout style"],
];

/**
 * The overlay's stylesheet.
 *
 * Custom properties are declared on `.root` rather than `:host` on purpose: a
 * page can set `--accent` on our host element (custom properties inherit and the
 * host is reachable), and a site that did so could recolour a destructive
 * confirm into something reassuring. Declared one level in, they are ours.
 *
 * The palette is neither the page's nor the system's. Browser chrome that
 * borrowed the page's colours would be indistinguishable from the page, which is
 * exactly the wrong property for a surface whose job is to say "this is Zentic
 * asking, and this is what it is about to do".
 */
const EDITOR_CSS = `
:host { all: initial; }

*, *::before, *::after { box-sizing: border-box; }

.root {
  --ink: #f2f5f9;
  --muted: #99a3b2;
  --panel: rgba(22, 24, 30, 0.80);
  --solid: #16181e;
  --line: rgba(255, 255, 255, 0.13);
  --edge: rgba(255, 255, 255, 0.28);
  --accent: #4c8dff;
  --accent-soft: rgba(76, 141, 255, 0.17);
  --propose: #f0b429;
  --propose-soft: rgba(240, 180, 41, 0.15);
  --danger: #ff7a70;

  position: absolute;
  inset: 0;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, system-ui, sans-serif;
  font-size: 13px;
  line-height: 1.45;
  color: var(--ink);
  -webkit-font-smoothing: antialiased;
  user-select: none;
}

/* Dim enough to push the page back a plane, light enough to still read it —
   the user is pointing at content, so the content has to stay legible. */
.scrim { position: absolute; inset: 0; background: rgba(9, 11, 16, 0.30); }

/* MARK: regions */

.layer { position: absolute; inset: 0; }

.region {
  position: absolute;
  margin: 0;
  padding: 0;
  border: 0;
  background: transparent;
  font: inherit;
  color: inherit;
  cursor: pointer;
  pointer-events: auto;
  border-radius: 7px;
  box-shadow: inset 0 0 0 1px var(--edge);
  transition: box-shadow 120ms ease, background-color 120ms ease;
}

/* A region whose box measures zero is still addressable — it is usually
   collapsed, lazily sized, or off-layout — so it gets a stub big enough to
   hover and a dimmed dashed edge that says "no box right now" rather than
   pretending to a geometry it does not have. */
.region[data-empty] {
  min-width: 68px;
  min-height: 22px;
  box-shadow: none;
  outline: 1px dashed var(--line);
  outline-offset: -1px;
  opacity: 0.6;
}

.region:hover, .region[data-hovered] {
  background: var(--accent-soft);
  box-shadow: inset 0 0 0 2px var(--accent);
}

/* Touched by an op already in the draft. Thin and quiet: it answers "what does
   my lens do to this page" at a glance without competing with a selection. */
.region[data-touched] { box-shadow: inset 0 0 0 1px var(--accent); }

.region[data-selected] {
  background: var(--accent-soft);
  box-shadow: inset 0 0 0 2px var(--accent), 0 0 0 1px rgba(0, 0, 0, 0.45);
}

/* The model's guess. Dashed, and a different hue — the difference between
   "I picked this" and "something picked this for me" must survive being read
   by someone who cannot tell blue from amber. */
.region[data-proposed] {
  background: var(--propose-soft);
  box-shadow: none;
  outline: 2px dashed var(--propose);
  outline-offset: -2px;
}

.region .tag {
  position: absolute;
  top: 4px;
  inset-inline-start: 4px;
  display: none;
  align-items: center;
  gap: 6px;
  max-width: calc(100% - 8px);
  padding: 3px 8px;
  border-radius: 6px;
  background: var(--solid);
  box-shadow: 0 2px 12px rgba(0, 0, 0, 0.45);
  font-size: 11px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.region:hover .tag,
.region[data-hovered] .tag,
.region:focus-visible .tag,
.region[data-selected] .tag,
.region[data-proposed] .tag { display: inline-flex; }

.tag .name { font-weight: 600; }
.tag .kind { color: var(--accent); }
.region[data-proposed] .tag .kind { color: var(--propose); }
.tag .dim { color: var(--muted); font-variant-numeric: tabular-nums; }

/* MARK: prompt bar */

.bar {
  position: absolute;
  inset-inline-start: 50%;
  bottom: 18px;
  transform: translateX(-50%);
  width: min(760px, calc(100vw - 36px));
  pointer-events: auto;
  display: flex;
  flex-direction: column;
  gap: 9px;
  padding: 10px 12px 11px;
  border: 1px solid var(--line);
  border-radius: 13px;
  background: var(--panel);
  -webkit-backdrop-filter: blur(22px) saturate(180%);
  backdrop-filter: blur(22px) saturate(180%);
  box-shadow: 0 24px 64px rgba(0, 0, 0, 0.46), inset 0 1px 0 rgba(255, 255, 255, 0.07);
}

.ask { display: flex; align-items: center; gap: 10px; }

.prompt {
  flex: 1 1 auto;
  min-width: 0;
  padding: 5px 2px;
  border: 0;
  outline: 0;
  background: transparent;
  color: var(--ink);
  font: inherit;
  font-size: 14px;
  caret-color: var(--accent);
  user-select: text;
}
.prompt::placeholder { color: var(--muted); }

.count { flex: 0 0 auto; color: var(--muted); font-size: 11px; white-space: nowrap; }

.chips { display: flex; flex-wrap: wrap; gap: 6px; }
.chips:empty { display: none; }

.chip {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  max-width: 100%;
  padding: 3px 4px 3px 9px;
  border: 1px solid var(--line);
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.07);
  font-size: 12px;
}
.chip[data-pending] {
  border-style: dashed;
  border-color: rgba(240, 180, 41, 0.65);
  background: var(--propose-soft);
}
.chip .lens {
  flex: 0 0 auto;
  padding-inline-end: 7px;
  border-inline-end: 1px solid var(--line);
  color: hsl(var(--hue, 214) 62% 70%);
  font-size: 10px;
  font-weight: 600;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  max-width: 11ch;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
/* Someone else's lens. Flat, dimmed, no delete: it is here to be read, and
   anything that looked removable would promise an edit this draft cannot make. */
.chip[data-context] { border-style: dotted; background: transparent; color: var(--muted); }

.context { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; }
.context[hidden] { display: none; }
.context .also,
.context .more {
  color: var(--muted);
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.06em;
}

/* A failure has to be as visible as a proposal, or the user is left guessing
   whether the model is still thinking. */
.notice {
  margin: 0;
  padding: 7px 9px;
  border: 1px solid rgba(255, 122, 112, 0.45);
  border-radius: 9px;
  background: rgba(255, 122, 112, 0.10);
  color: var(--ink);
}
.notice[hidden] { display: none; }

.chip .note { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.chip .x {
  flex: 0 0 auto;
  width: 17px;
  height: 17px;
  padding: 0;
  border: 0;
  border-radius: 50%;
  background: transparent;
  color: var(--muted);
  font: inherit;
  font-size: 13px;
  line-height: 1;
  cursor: pointer;
}
.chip .x:hover { background: rgba(255, 122, 112, 0.18); color: var(--danger); }

.proposal {
  display: flex;
  flex-direction: column;
  gap: 7px;
  padding: 8px 9px;
  border: 1px dashed rgba(240, 180, 41, 0.55);
  border-radius: 10px;
  background: rgba(240, 180, 41, 0.08);
}
.proposal .lead { margin: 0; color: var(--ink); }
.proposal .lead b { color: var(--propose); }
.proposal .acts { display: flex; gap: 7px; }

.foot { display: flex; align-items: flex-end; gap: 12px; padding-top: 9px; border-top: 1px solid var(--line); }
.foot .where { display: flex; flex-direction: column; gap: 4px; min-width: 0; }

.scope {
  display: inline-flex;
  gap: 2px;
  padding: 2px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: rgba(255, 255, 255, 0.06);
}
.scope button {
  padding: 3px 9px;
  border: 0;
  border-radius: 6px;
  background: transparent;
  color: var(--muted);
  font: inherit;
  font-size: 12px;
  cursor: pointer;
}
.scope button[aria-checked="true"] {
  background: rgba(255, 255, 255, 0.14);
  color: var(--ink);
  box-shadow: 0 1px 2px rgba(0, 0, 0, 0.32);
}

.pattern {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 11px;
  color: var(--muted);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.grow { flex: 1 1 auto; }
.acts { display: flex; gap: 7px; }

button.act {
  padding: 5px 13px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: rgba(255, 255, 255, 0.07);
  color: var(--ink);
  font: inherit;
  font-size: 12px;
  cursor: pointer;
}
button.act:hover:not(:disabled) { background: rgba(255, 255, 255, 0.14); }
button.act[data-primary] { border-color: transparent; background: var(--accent); color: #fff; font-weight: 600; }
button.act:disabled { opacity: 0.4; cursor: default; }

:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }

@media (prefers-reduced-motion: reduce) { * { transition: none !important; } }
`;

/** Where a saved lens applies. Exactly the three `matchingLenses` understands. */
type Scope = "page" | "similar" | "site";

const SCOPE_LABELS: Array<{ scope: Scope; label: string }> = [
  { scope: "page", label: "This page" },
  { scope: "similar", label: "Pages like this" },
  { scope: "site", label: "Whole site" },
];

/** One chip. `source` is the lens an op came in with, so a chip can say whose it
 * is; ops the user just accepted have no source until they are saved. */
interface DraftOp {
  op: LensOp;
  source?: { id: string; name: string };
}

/**
 * One answer from the model, kept whole.
 *
 * A group is the unit region ids, buckets and field names are unique *within*,
 * and nothing wider. Two answers that both name a region `r1` mean two different
 * elements, so they are adopted separately — flattening the queue into one list
 * and renaming through one shared map repoints the *first* answer's ops at the
 * second answer's element, which is a hide landing on the wrong box.
 */
interface PendingGroup {
  ops: LensOp[];
  regions: LensRegion[];
}

interface Pending {
  note: string;
  groups: PendingGroup[];
  /** Catalog candidate ids to outline, resolved from the proposals' selectors. */
  highlighted: Set<string>;
}

class LensEditorOverlay implements LensEditor {
  private host: HTMLElement | undefined;
  private root: ShadowRoot | undefined;
  private layer: HTMLElement | undefined;
  private bar: HTMLElement | undefined;
  private input: HTMLInputElement | undefined;
  private countNode: HTMLElement | undefined;
  private chipList: HTMLElement | undefined;
  private contextList: HTMLElement | undefined;
  private noticeNode: HTMLElement | undefined;
  private proposalBox: HTMLElement | undefined;
  private patternNode: HTMLElement | undefined;
  private saveButton: HTMLButtonElement | undefined;
  private askButton: HTMLButtonElement | undefined;
  private readonly scopeButtons = new Map<Scope, HTMLButtonElement>();

  private catalog: RegionCatalog | undefined;
  private lenses: Lens[] = [];
  /** The lens being revised, if any. Its id is what makes Save a replacement. */
  private editing: Lens | undefined;
  /** Every other lens on the page, shown but never adopted. */
  private contextLenses: Lens[] = [];
  private readonly regionNodes = new Map<string, HTMLElement>();
  private readonly selected = new Set<string>();
  private readonly regionPool = new Map<string, LensRegion>();
  /** Harvest bucket names claimed by the draft, and the field names inside them.
   * Lens-local both, so they collide across lenses exactly as region ids do. */
  private readonly buckets = new Set<string>();
  private readonly fields = new Set<string>();
  private draft: DraftOp[] = [];
  private pending: Pending | undefined;
  private scope: Scope = "similar";
  /** The pattern an edited lens arrived with, held until the user picks a scope
   * themselves — saving must not silently re-scope a lens nobody re-scoped. */
  private pinnedPattern: string | undefined;
  private lastPrompt = "";
  private asking = false;
  private notice = "";

  private previousFocus: Element | undefined;
  private teardowns: Array<() => void> = [];
  private remeasureTimer: ReturnType<typeof setTimeout> | undefined;
  private closing = false;
  private draftCallback: ((lens: Lens) => void) | undefined;
  private promptCallback: ((text: string, selectedRegionIDs: string[]) => void) | undefined;
  private closeCallback: (() => void) | undefined;

  constructor(private readonly doc: Document) {}

  onDraft(callback: (lens: Lens) => void): void {
    this.draftCallback = callback;
  }

  onPrompt(callback: (text: string, selectedRegionIDs: string[]) => void): void {
    this.promptCallback = callback;
  }

  onClose(callback: () => void): void {
    this.closeCallback = callback;
  }

  /**
   * Build the overlay over the current page.
   *
   * Never throws. `main.ts` calls this from the command dispatcher, and a
   * hostile page — no `<body>` yet, an `Element.prototype` someone has replaced,
   * a `MutationObserver` that eats unknown nodes — must cost the user the
   * editor, not the rest of the engine. A failed mount tears itself down and
   * hands focus back, so a second ⌥⌘L gets a clean attempt rather than a
   * half-built overlay and a caret nowhere.
   *
   * An `editing` id with no lens behind it is refused outright, before anything
   * is built or torn down. The app offers "Edit…" on every lens the site has,
   * including the ones switched off and the ones scoped to another path, while
   * the editor is handed only the set that is actually applied — so `editing`
   * naming a lens that is not in `lenses` is the ordinary case, not a freak one.
   * Degrading to authoring there is silent duplication: a blank overlay, a fresh
   * id, and Save writes a *third* lens while the one the user pressed Edit on is
   * never touched. Refusing makes that impossible from this side whatever the app
   * sends; the app's job is to hand over the lens it wants edited.
   */
  mount(catalog: RegionCatalog, lenses: Lens[], editing?: string): boolean {
    const subject = editing ? lenses.find((lens) => lens.id === editing) : undefined;
    if (editing && !subject) return false;

    const previous = activeElement(this.doc);
    try {
      // `teardown`, not `unmount`: a remount is not a close. Unmounting here
      // would bounce focus out through the page on its way back in, and would
      // tell the app the editor had gone at the moment it was reopening.
      if (this.host) this.teardown();

      const parent = this.doc.body ?? this.doc.documentElement;
      if (!parent) return false;

      this.catalog = catalog;
      this.lenses = lenses.slice();
      this.selected.clear();
      this.regionNodes.clear();
      this.regionPool.clear();
      this.buckets.clear();
      this.fields.clear();
      this.draft = [];
      this.pending = undefined;
      this.asking = false;
      this.notice = "";
      this.lastPrompt = "";
      this.scope = "similar";
      this.pinnedPattern = undefined;
      this.previousFocus = previous;

      // Authoring and editing part here, and the difference is the whole of
      // whether an existing lens can ever be changed. Adopting every lens on the
      // site made Save mint a *new* lens holding all of their ops, originals
      // still enabled, every op applied twice. So: exactly the named lens becomes
      // the draft — `adopt` still namespaces it, because a proposal merged into
      // it later can collide with it — and the rest are context the user can read
      // and not touch.
      this.editing = subject;
      this.contextLenses = this.lenses.filter((lens) => lens.id !== this.editing?.id);
      if (this.editing) {
        this.adopt(this.editing.ops, this.editing.regions, {
          id: this.editing.id,
          name: this.editing.name,
        });
        this.pinnedPattern = this.editing.pathPattern;
        this.scope = scopeOf(this.editing.pathPattern, catalog.pathPattern, this.currentPath());
      }

      const host = this.doc.createElement("div");
      host.id = HOST_ID;
      for (const [property, value] of HOST_STYLE) {
        host.style.setProperty(property, value, "important");
      }

      // Built detached and inserted once, at the end. A host that reached the
      // document ahead of its shadow root would be an empty full-viewport box for
      // a frame, and anything that threw in between — a page that has replaced
      // `attachShadow`, an `Element.prototype` someone owns — would leave that box
      // in the page for good, with no field to remove it by.
      const root = host.attachShadow({ mode: "closed" });
      const style = this.doc.createElement("style");
      style.textContent = EDITOR_CSS;
      root.appendChild(style);

      this.host = host;
      this.root = root;
      root.appendChild(this.buildChrome());

      this.renderRegions();
      this.renderBar();
      parent.appendChild(host);
      this.syncScroll();
      this.listen();

      // Into the prompt field, because the first thing a lens needs is words.
      // Regions are one Tab away and every one of them is in the focus ring.
      this.input?.focus();
      return true;
    } catch {
      this.teardown();
      // No `onClose`: an editor that never opened never closed, and telling the
      // app otherwise would be a state change it did not cause. Focus, though,
      // has to come back — a failed mount that leaves the caret in a half-built
      // overlay leaves the user with a page they cannot type into.
      restoreFocus(previous);
      return false;
    }
  }

  /**
   * Remove every trace, give focus back, and tell the app.
   *
   * The page was never written to, so there is nothing to restore but the caret.
   * Safe to call unmounted, twice, or from inside a handler the teardown is
   * about to remove.
   */
  unmount(): void {
    this.close();
  }

  /**
   * Every way out lands here: Esc, Cancel, Save, `exitLensMode`, and the page
   * removing the host from under us.
   *
   * `onClose` fires unconditionally, including for a close that closes nothing.
   * Only `exitLensMode` used to report the mode change, so Esc and Save left the
   * app believing an editor was still up — and the next ⌥⌘L spent itself sending
   * `exitLensMode` to something already gone, costing two presses to reopen. A
   * duplicate "closed" is harmless; a missed one is not. Re-entrancy is guarded
   * because the callback is the app's, and an app that answers a close by asking
   * for one would otherwise recurse.
   */
  private close(): void {
    if (this.closing) return;
    this.closing = true;
    try {
      const previous = this.previousFocus;
      this.teardown();
      restoreFocus(previous);
      this.closeCallback?.();
    } finally {
      this.closing = false;
    }
  }

  /**
   * Show what the model came back with — highlighted, not applied.
   *
   * This is the single most important behaviour in the file. The proposal's
   * regions get outlined in the proposal colour, its ops become dashed chips
   * describing themselves in words, and the only way any of it reaches the page
   * is the user pressing Apply. A proposal that arrives after the user has
   * already closed the editor is dropped: applying to an overlay nobody is
   * looking at is precisely the prompt-straight-to-effect this design forbids.
   */
  showProposal(proposal: LensProposal): void {
    if (!this.root) return;

    // A proposal is JSON that arrived from outside this file, so the shape is a
    // claim rather than a fact. Missing arrays cost the user a highlight; a
    // throw here would cost them the command dispatcher.
    const regions = proposal.regions ?? [];
    const note = (proposal.note ?? "").trim();
    const offered = proposal.ops ?? [];

    // An op may only name a region the model was allowed to name: one this
    // proposal declares, one already in the draft (the model is shown the lens's
    // existing regions, so answering in their ids is legitimate), or one from a
    // proposal still queued. Anything else is an op no `Lens.regions` can carry,
    // and it would travel with the good ops into a lens Swift rejects whole.
    const known = new Set<string>([
      ...this.regionPool.keys(),
      ...regions.map((region) => region.id),
      ...this.pendingRegions().map((region) => region.id),
    ]);
    const ops = offered.filter(
      (op) => known.has(op.region) && (op.target === undefined || known.has(op.target)),
    );

    this.asking = false;

    if (ops.length === 0) {
      // The only way the app has to say "that ask produced nothing": there is no
      // failure event on the wire, and a proposal with no usable op is not a
      // proposal. Left alone the editor sits at "asking…" with Ask disabled for
      // the rest of the session, and the only way out loses the draft.
      this.failed(
        offered.length > 0
          ? "That answer named regions this page did not offer, so none of it can be applied."
          : note || FAILED_PROMPT_MESSAGE,
      );
      return;
    }

    const highlighted = new Set<string>();
    for (const region of regions) {
      const candidate = this.candidateFor(region);
      if (candidate) highlighted.add(candidate.id);
    }

    const pending = this.pending;
    if (pending) {
      // A second answer arriving over an unanswered first used to overwrite it,
      // silently dropping ops the user had not decided about and could not ask
      // for again. Queue both instead — as its own group, because its region ids
      // are its own — so Apply and Discard still mean what they say, and the op
      // ids stay unique so one chip's × removes one chip.
      const taken = new Set(this.pendingOps().map((op) => op.id));
      const queued: LensOp[] = [];
      for (const op of ops) {
        const id = taken.has(op.id) ? uniqueKey(op.id, (candidate) => taken.has(candidate)) : op.id;
        taken.add(id);
        queued.push({ ...op, id });
      }
      pending.groups.push({ ops: queued, regions: regions.slice() });
      for (const id of highlighted) pending.highlighted.add(id);
      pending.note = [pending.note, note].filter((text) => text.length > 0).join(" · ");
    } else {
      this.pending = {
        note,
        groups: [{ ops: ops.slice(), regions: regions.slice() }],
        highlighted,
      };
    }

    this.notice = "";
    this.paintRegionStates();
    this.renderBar();
  }

  /**
   * The ask cannot be answered — the model failed, or the page has no engine to
   * build a catalog from, so nothing was ever sent.
   *
   * Recovery, not decoration: `asking` is what disables Ask, and without a way
   * to clear it a single failed model call ends the editing session.
   */
  promptFailed(message: string): void {
    if (!this.root) return;
    this.failed(message.trim() || FAILED_PROMPT_MESSAGE);
  }

  private failed(message: string): void {
    this.asking = false;
    this.notice = message;
    // No focus move: the user may have gone on to point at regions, and a
    // failure is not a reason to take the caret off what they are doing.
    this.renderBar();
  }

  // MARK: - Chrome

  private buildChrome(): HTMLElement {
    const root = this.doc.createElement("div");
    root.className = "root";
    root.setAttribute("role", "dialog");
    root.setAttribute("aria-modal", "true");
    root.setAttribute("aria-label", "Lens editor");

    const scrim = this.doc.createElement("div");
    scrim.className = "scrim";

    const layer = this.doc.createElement("div");
    layer.className = "layer";
    layer.setAttribute("role", "group");
    layer.setAttribute("aria-label", "Page regions");
    this.layer = layer;

    root.append(scrim, layer, this.buildBar());
    return root;
  }

  private buildBar(): HTMLElement {
    const bar = this.doc.createElement("div");
    bar.className = "bar";

    // Other lenses, above the draft and visibly not part of it. The order is the
    // claim: what is already happening to this page, then what you are writing.
    const context = this.doc.createElement("div");
    context.className = "context";
    context.setAttribute("role", "list");
    context.setAttribute("aria-label", "Other lenses on this page");
    context.hidden = true;
    this.contextList = context;

    const chips = this.doc.createElement("div");
    chips.className = "chips";
    chips.setAttribute("role", "list");
    this.chipList = chips;

    const notice = this.doc.createElement("p");
    notice.className = "notice";
    notice.setAttribute("role", "status");
    notice.setAttribute("aria-live", "polite");
    notice.hidden = true;
    this.noticeNode = notice;

    const proposalBox = this.doc.createElement("div");
    proposalBox.className = "proposal";
    proposalBox.hidden = true;
    this.proposalBox = proposalBox;

    const ask = this.doc.createElement("div");
    ask.className = "ask";

    const input = this.doc.createElement("input");
    input.className = "prompt";
    input.type = "text";
    input.autocomplete = "off";
    input.spellcheck = false;
    input.placeholder = "Say what this page should look like…";
    input.setAttribute("aria-label", "Describe the change");
    input.addEventListener("input", () => this.syncAffordances());
    this.input = input;

    const count = this.doc.createElement("span");
    count.className = "count";
    this.countNode = count;

    const askButton = this.button("Ask", "act");
    askButton.addEventListener("click", () => this.submitPrompt());
    this.askButton = askButton;

    ask.append(input, count, askButton);

    const foot = this.doc.createElement("div");
    foot.className = "foot";

    const where = this.doc.createElement("div");
    where.className = "where";

    const scope = this.doc.createElement("div");
    scope.className = "scope";
    scope.setAttribute("role", "radiogroup");
    scope.setAttribute("aria-label", "Where this lens applies");
    for (const entry of SCOPE_LABELS) {
      const option = this.button(entry.label);
      option.setAttribute("role", "radio");
      option.addEventListener("click", () => {
        this.scope = entry.scope;
        // The user has now chosen where this lens applies, so an edited lens's
        // original pattern stops being the answer.
        this.pinnedPattern = undefined;
        this.syncAffordances();
      });
      this.scopeButtons.set(entry.scope, option);
      scope.appendChild(option);
    }

    // The literal pattern, under the control that chooses it. "Pages like this"
    // is a promise about future pages, and the only honest way to make it is to
    // show the pattern that will be matched.
    const pattern = this.doc.createElement("code");
    pattern.className = "pattern";
    this.patternNode = pattern;

    where.append(scope, pattern);

    const grow = this.doc.createElement("div");
    grow.className = "grow";

    const acts = this.doc.createElement("div");
    acts.className = "acts";
    const cancel = this.button("Cancel", "act");
    cancel.addEventListener("click", () => this.unmount());
    const save = this.button("Save Lens", "act");
    save.setAttribute("data-primary", "");
    save.addEventListener("click", () => this.save());
    this.saveButton = save;
    acts.append(cancel, save);

    foot.append(where, grow, acts);
    bar.append(context, chips, notice, proposalBox, ask, foot);
    this.bar = bar;
    return bar;
  }

  private button(label: string, className?: string): HTMLButtonElement {
    const node = this.doc.createElement("button");
    node.type = "button";
    if (className) node.className = className;
    node.textContent = label;
    return node;
  }

  // MARK: - Regions

  /**
   * One outline per candidate, positioned in document coordinates.
   *
   * `RegionCandidate.rect` is document-relative — `regions.ts` adds the scroll
   * offset so a catalog built at the top of the page and one built halfway down
   * describe the same boxes. The layer therefore lives in document space and is
   * translated by the current scroll on every scroll event, which is one style
   * write per frame instead of repositioning every box.
   */
  private renderRegions(): void {
    const layer = this.layer;
    if (!layer) return;

    layer.textContent = "";
    this.regionNodes.clear();

    for (const candidate of this.catalog?.candidates ?? []) {
      const node = this.button("");
      node.className = "region";
      node.dataset.region = candidate.id;

      const label = regionLabel(candidate);
      node.setAttribute("aria-label", `${label}, ${candidate.kindGuess}`);
      node.setAttribute("aria-pressed", "false");
      node.appendChild(this.buildTag(label, candidate));
      this.place(node, candidate.rect);

      node.addEventListener("mouseenter", () => {
        node.dataset.hovered = "";
      });
      node.addEventListener("mouseleave", () => {
        delete node.dataset.hovered;
      });
      node.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        this.toggleRegion(candidate.id, (event as MouseEvent).shiftKey === true);
      });

      layer.appendChild(node);
      this.regionNodes.set(candidate.id, node);
    }

    this.paintRegionStates();
  }

  /**
   * Put one outline where its element is.
   *
   * Also the only writer of `data-empty` and of the size on the hover tag, so a
   * box that gains or loses a geometry between measurements says so instead of
   * keeping the first answer it was given.
   */
  private place(node: HTMLElement, rect: RegionRect): void {
    node.style.left = `${rect.x}px`;
    node.style.top = `${rect.y}px`;
    node.style.width = `${Math.max(0, rect.width)}px`;
    node.style.height = `${Math.max(0, rect.height)}px`;

    const empty = rect.width <= 0 || rect.height <= 0;
    setFlag(node, "empty", empty);

    const dim = node.querySelector<HTMLElement>(".tag .dim");
    if (dim) {
      dim.textContent = empty
        ? "no box"
        : `${Math.round(rect.width)}×${Math.round(rect.height)}`;
    }
  }

  /**
   * Re-measure every outline against the live page.
   *
   * The catalog's rects are one snapshot, and pointing at a box is the entire
   * premise of this surface: a window resize, a font swap or a lazy image that
   * reflows leaves every outline over an element that has moved, and the user
   * hides the wrong one. Geometry only, and only for elements the catalog
   * already described — nothing here reads anything the model was not shown.
   */
  private remeasure(): void {
    const view = this.doc.defaultView;
    if (!view || !this.catalog) return;

    const offsetX = view.scrollX || 0;
    const offsetY = view.scrollY || 0;

    for (const candidate of this.catalog.candidates) {
      const node = this.regionNodes.get(candidate.id);
      if (!node) continue;

      const element = this.resolveCandidate(candidate);
      // Gone from the page while the editor was open. The last known box is a
      // better answer than the origin, which would put a clickable outline over
      // the top-left corner of a document it no longer describes.
      if (!element) continue;

      const box = element.getBoundingClientRect();
      this.place(node, {
        x: Math.round(box.left + offsetX),
        y: Math.round(box.top + offsetY),
        width: Math.round(box.width),
        height: Math.round(box.height),
      });
    }
  }

  /** The live element a catalog entry describes, by its own selectors. */
  private resolveCandidate(candidate: RegionCandidate): Element | undefined {
    for (const selector of [candidate.selector, ...(candidate.alternates ?? [])]) {
      try {
        const hit = this.doc.querySelector(selector);
        if (hit) return hit;
      } catch {
        // A selector this engine cannot parse. The next candidate may be fine.
      }
    }
    return undefined;
  }

  /** The hover label: what this box is called, what we think it is, how big it
   * is. Every field comes from the catalog, so none of it is page text. */
  private buildTag(label: string, candidate: RegionCandidate): HTMLElement {
    const tag = this.doc.createElement("span");
    tag.className = "tag";

    const name = this.doc.createElement("span");
    name.className = "name";
    name.textContent = label;

    const kind = this.doc.createElement("span");
    kind.className = "kind";
    kind.textContent = candidate.kindGuess;

    // Filled by `place`, which owns the geometry and re-owns it after a reflow.
    const dim = this.doc.createElement("span");
    dim.className = "dim";

    tag.append(name, kind, dim);
    return tag;
  }

  /** Selection, proposal and draft state, written onto the existing nodes. A
   * rebuild would drop focus and hover mid-interaction. */
  private paintRegionStates(): void {
    const touched = this.touchedCandidates();

    for (const [id, node] of this.regionNodes) {
      setFlag(node, "selected", this.selected.has(id));
      setFlag(node, "proposed", this.pending?.highlighted.has(id) === true);
      setFlag(node, "touched", touched.has(id));
      node.setAttribute("aria-pressed", this.selected.has(id) ? "true" : "false");
    }
  }

  /** Catalog ids the draft's ops already act on, so the overlay can show what
   * the lens under construction covers. */
  private touchedCandidates(): Set<string> {
    const ids = new Set<string>();
    for (const entry of this.draft) {
      for (const regionID of [entry.op.region, entry.op.target]) {
        const region = regionID ? this.regionPool.get(regionID) : undefined;
        const candidate = region ? this.candidateFor(region) : undefined;
        if (candidate) ids.add(candidate.id);
      }
    }
    return ids;
  }

  private toggleRegion(id: string, additive: boolean): void {
    if (additive) {
      if (!this.selected.delete(id)) this.selected.add(id);
    } else {
      const wasOnlySelection = this.selected.size === 1 && this.selected.has(id);
      this.selected.clear();
      if (!wasOnlySelection) this.selected.add(id);
    }

    this.paintRegionStates();
    this.syncAffordances();
  }

  // MARK: - Bar contents

  private renderBar(): void {
    this.renderContext();
    this.renderChips();
    this.renderNotice();
    this.renderProposal();
    this.syncAffordances();
  }

  private renderChips(): void {
    const list = this.chipList;
    if (!list) return;

    list.textContent = "";
    for (const entry of this.draft) {
      list.appendChild(
        this.buildChip(entry.op, entry.source?.name, () => this.removeDraftOp(entry.op.id)),
      );
    }
  }

  /**
   * The other lenses on this page, as chips that cannot be edited.
   *
   * Read-only is the point. These ops belong to lenses that are already applied;
   * showing them as removable chips is what made Save absorb them into whatever
   * the user was writing. Attributed by name, dotted and dimmed, no delete — the
   * user can see what else is acting on the page and manage it where it lives.
   */
  private renderContext(): void {
    const list = this.contextList;
    if (!list) return;

    list.textContent = "";
    const lenses = this.contextLenses.filter((lens) => (lens.ops ?? []).length > 0);
    if (lenses.length === 0) {
      list.hidden = true;
      return;
    }
    list.hidden = false;

    const label = this.doc.createElement("span");
    label.className = "also";
    label.textContent = "Also on this page";
    list.appendChild(label);

    let shown = 0;
    let hidden = 0;
    for (const lens of lenses) {
      for (const op of lens.ops) {
        if (shown >= MAX_CONTEXT_CHIPS) {
          hidden += 1;
          continue;
        }
        const chip = this.buildChip(op, lens.name, undefined);
        chip.dataset.context = "";
        chip.setAttribute("aria-disabled", "true");
        list.appendChild(chip);
        shown += 1;
      }
    }

    if (hidden > 0) {
      const more = this.doc.createElement("span");
      more.className = "more";
      more.textContent = `+${hidden} more`;
      list.appendChild(more);
    }
  }

  private renderNotice(): void {
    const node = this.noticeNode;
    if (!node) return;
    node.textContent = this.notice;
    node.hidden = this.notice.length === 0;
  }

  /**
   * A chip is the op in the user's own words.
   *
   * `LensOp.note` exists for exactly this: nobody should have to read
   * `{"kind":"filter","predicate":…}` to know what they are about to save. The
   * chip carries the note, the lens it came from, and its own delete — removing
   * one rebuilds the list and touches nothing else, because the ops are held in
   * an array keyed by op id rather than by position in the DOM.
   *
   * No `remove` means the chip is somebody else's op, shown for context: an ×
   * there would offer an edit this draft is not allowed to make.
   */
  private buildChip(
    op: LensOp,
    lensName: string | undefined,
    remove: (() => void) | undefined,
  ): HTMLElement {
    const chip = this.doc.createElement("span");
    chip.className = "chip";
    chip.setAttribute("role", "listitem");
    chip.dataset.op = op.id;

    if (lensName) {
      const badge = this.doc.createElement("span");
      badge.className = "lens";
      badge.style.setProperty("--hue", String(hueFor(lensName)));
      badge.textContent = lensName;
      badge.title = lensName;
      chip.appendChild(badge);
    }

    const note = this.doc.createElement("span");
    note.className = "note";
    note.textContent = op.note || op.kind;
    chip.appendChild(note);

    if (remove) {
      const close = this.button("×", "x");
      close.setAttribute("aria-label", `Remove: ${op.note || op.kind}`);
      close.addEventListener("click", remove);
      chip.appendChild(close);
    }

    return chip;
  }

  private renderProposal(): void {
    const box = this.proposalBox;
    if (!box) return;

    box.textContent = "";
    const pending = this.pending;
    const queued = this.pendingOps();
    if (!pending || queued.length === 0) {
      box.hidden = true;
      return;
    }

    box.hidden = false;

    const lead = this.doc.createElement("p");
    lead.className = "lead";
    const marker = this.doc.createElement("b");
    marker.textContent = `${queued.length} proposed · `;
    lead.append(marker, this.doc.createTextNode(pending.note || "Check the highlighted regions."));
    box.appendChild(lead);

    const chips = this.doc.createElement("div");
    chips.className = "chips";
    chips.setAttribute("role", "list");
    for (const op of queued) {
      const chip = this.buildChip(op, undefined, () => this.dropPendingOp(op.id));
      chip.dataset.pending = "";
      chips.appendChild(chip);
    }
    box.appendChild(chips);

    const acts = this.doc.createElement("div");
    acts.className = "acts";
    const apply = this.button("Apply", "act");
    apply.setAttribute("data-primary", "");
    apply.addEventListener("click", () => this.applyPending());
    const discard = this.button("Discard", "act");
    discard.addEventListener("click", () => this.discardPending());
    acts.append(apply, discard);
    box.appendChild(acts);
  }

  /** Everything that changes with selection, draft size or scope. Cheap enough
   * to run on every keystroke, so no state can drift out of sync. */
  private syncAffordances(): void {
    const selectedCount = this.selected.size;
    if (this.countNode) {
      this.countNode.textContent = this.asking
        ? "asking…"
        : selectedCount > 0
          ? `${selectedCount} selected`
          : "";
    }

    const hasPromptText = (this.input?.value ?? "").trim().length > 0;
    if (this.askButton) this.askButton.disabled = !hasPromptText || this.asking;
    if (this.saveButton) this.saveButton.disabled = this.draft.length === 0;

    for (const [scope, node] of this.scopeButtons) {
      node.setAttribute("aria-checked", scope === this.scope ? "true" : "false");
    }

    if (this.patternNode) this.patternNode.textContent = this.patternLabel();
    if (this.bar) setFlag(this.bar, "asking", this.asking);
  }

  // MARK: - Actions

  private submitPrompt(): void {
    const text = (this.input?.value ?? "").trim();
    if (text.length === 0 || this.asking) return;

    this.rememberPrompt();
    this.asking = true;
    // Last ask's failure is not this one's. Cleared before the call, because the
    // call may answer synchronously with another.
    this.notice = "";
    this.renderNotice();
    // Nothing local happens here — the app answers with a proposal, and the
    // proposal is a highlight. This is the only outbound call the editor makes.
    this.promptCallback?.(text, Array.from(this.selected));
    this.syncAffordances();
  }

  /** Every queued op, in the order the answers arrived. */
  private pendingOps(): LensOp[] {
    return (this.pending?.groups ?? []).flatMap((group) => group.ops);
  }

  private pendingRegions(): LensRegion[] {
    return (this.pending?.groups ?? []).flatMap((group) => group.regions);
  }

  private applyPending(): void {
    const pending = this.pending;
    if (!pending) return;

    // One `adopt` per answer, never one across the queue. Region ids, harvest
    // buckets and harvested field names are all local to the answer that used
    // them, and a single rename map spanning two answers rewrites the first
    // answer's ops with the second's renames — both hides landing on the second
    // answer's element while the first's is left unreferenced and dropped.
    for (const group of pending.groups) {
      this.adopt(group.ops, group.regions, undefined);
    }
    this.pending = undefined;
    // The prompt has been answered; clearing the field makes room for the next
    // instruction rather than leaving stale words in it. The words are kept
    // first, because they are what names the lens — a user who accepted a
    // proposal and pressed Save should not get a lens called "New Lens".
    this.rememberPrompt();
    if (this.input) this.input.value = "";

    this.paintRegionStates();
    this.renderBar();
    this.input?.focus();
  }

  /** Keep whatever is in the field as the lens's working title, so clearing it
   * later never loses the only human-written thing on this path. */
  private rememberPrompt(): void {
    const text = (this.input?.value ?? "").trim();
    if (text.length > 0) this.lastPrompt = text;
  }

  private discardPending(): void {
    this.pending = undefined;
    this.paintRegionStates();
    this.renderBar();
    this.input?.focus();
  }

  private dropPendingOp(opID: string): void {
    const pending = this.pending;
    if (!pending) return;

    // Within its own group, and the group goes when its last op does: an empty
    // group would keep declaring regions no op names any more.
    pending.groups = pending.groups
      .map((group) => ({ ...group, ops: group.ops.filter((op) => op.id !== opID) }))
      .filter((group) => group.ops.length > 0);
    if (pending.groups.length === 0) this.pending = undefined;

    this.paintRegionStates();
    this.renderBar();
  }

  private removeDraftOp(opID: string): void {
    const index = this.draft.findIndex((entry) => entry.op.id === opID);
    if (index < 0) return;

    this.draft.splice(index, 1);
    this.paintRegionStates();
    this.renderBar();

    // Focus would otherwise land back on `<body>` — outside the overlay — the
    // moment a keyboard user deletes a chip.
    const chips = Array.from(this.chipList?.querySelectorAll<HTMLElement>(".chip .x") ?? []);
    (chips[Math.min(index, chips.length - 1)] ?? this.input)?.focus();
  }

  /**
   * Assemble the draft and hand it to the app.
   *
   * The id decides everything downstream. Editing carries the lens's own id, and
   * that is the only signal the app has to *replace* the record rather than
   * write a second lens beside the first — both enabled, every op applied twice.
   * Authoring mints a fresh one. Everything else an edit must not silently
   * change travels with it: the name when the user did not retype the prompt,
   * the enabled flag, the stacking order, `createdAt`, and the path pattern the
   * lens arrived with unless the user picked a different scope.
   *
   * Only the regions the surviving ops actually reference travel, so deleting a
   * chip really does shrink the lens rather than leaving an orphan selector
   * behind to report drift about. Each one is fingerprinted on the way out —
   * see `fingerprinted`, which is the whole of how a lens survives the page
   * being redesigned under it.
   */
  private save(): void {
    if (this.draft.length === 0) return;

    const ops = this.draft.map((entry) => entry.op);
    const referenced = new Set<string>();
    for (const op of ops) {
      referenced.add(op.region);
      if (op.target) referenced.add(op.target);
    }

    const regions: LensRegion[] = [];
    for (const [id, region] of this.regionPool) {
      if (referenced.has(id)) regions.push(this.fingerprinted(region));
    }

    const typed = (this.input?.value ?? "").trim() || this.lastPrompt;
    const editing = this.editing;
    const now = new Date().toISOString();
    const lens: Lens = {
      id: editing?.id ?? freshID(),
      name: typed.length > 0 ? lensName(typed) : (editing?.name ?? DEFAULT_LENS_NAME),
      origin: this.catalog?.origin ?? editing?.origin ?? "",
      pathPattern: this.patternFor(this.scope),
      isEnabled: editing?.isEnabled ?? true,
      prompt: typed || editing?.prompt || "",
      regions,
      ops,
      createdAt: editing?.createdAt ?? now,
      // Also the stacking key: the most recently touched lens wins where two
      // overlap, the way a later style rule does. Saving an edit therefore
      // re-stacks it, which is what the user just asked for by editing it.
      updatedAt: now,
      schemaVersion: LENS_SCHEMA_VERSION,
    };

    this.draftCallback?.(lens);
    this.unmount();
  }

  /**
   * Attach a structural fingerprint of the element the user actually pointed at.
   *
   * Here rather than in `regions.ts`, for two reasons. The field lives on
   * `LensRegion` and not on `RegionCandidate`, so taking it during segmentation
   * would widen the catalog — the one artefact that leaves the device — for a
   * value only a saved lens ever reads. And a catalog describes a hundred and
   * twenty boxes of which the user chose one or two: this is the element they
   * pointed at, in the state the page was in at the moment they said yes to it.
   *
   * A region whose selectors name nothing here keeps whatever it arrived with —
   * nothing at all on a newly authored region, and its existing print when a lens
   * is edited from a page that no longer carries that region. Minting one from an
   * element nobody found is exactly the confident wrong answer the fingerprint
   * exists to refuse, and dropping a good one because this page is not the page it
   * was written for would throw away the only evidence the lens has left.
   */
  private fingerprinted(region: LensRegion): LensRegion {
    const element = this.regionElement(region);
    if (!element) return region;
    try {
      return { ...region, fingerprint: buildFingerprint(element) };
    } catch {
      // A hostile page can replace anything the fingerprint reads. Saving a lens
      // without one is a lens that behaves exactly as lenses did before.
      return region;
    }
  }

  /**
   * The one element a region's selectors name right now.
   *
   * Uniqueness is the gate, not first-match. A selector matching a hundred and
   * sixty boxes "resolves" to whichever is first in document order, and
   * fingerprinting that one would store a signature of a box the user never
   * pointed at — which is worse than storing none, because the runner would then
   * believe it. Same shape gate as `ops.ts`, so a selector the runner will refuse
   * is not one a fingerprint gets taken against, and the same cap on how many are
   * tried.
   */
  private regionElement(region: LensRegion): Element | undefined {
    for (const candidate of region.selectors.slice(0, MAX_SELECTORS_TRIED)) {
      const selector = safeRegionSelector(candidate);
      if (!selector) continue;
      let found: NodeListOf<Element>;
      try {
        found = this.doc.querySelectorAll(selector);
      } catch {
        continue;
      }
      const element = found[0];
      if (found.length === 1 && element && !isOurs(element)) return element;
    }
    return undefined;
  }

  /**
   * Take ONE group of ops and their regions into the draft.
   *
   * One group means one lens or one answer from the model — never two of either.
   * The rename map below spans a single call, so a call carrying two groups
   * rewrites both of them through the first collision it finds, and the group
   * that was already correct is repointed at the other group's element.
   *
   * Region ids are only unique *within* a lens, so two lenses on one site can
   * both call something "related" while meaning different selectors. Merging
   * them blindly would repoint an op at another lens's element — a hide landing
   * on the wrong box, which is the failure this whole feature is built to avoid.
   * Colliding ids are renamed and the group's ops rewritten to follow. Op ids get
   * the same treatment because chips are keyed by them.
   *
   * Harvest buckets and harvested field names are lens-local in exactly the same
   * way, and were not namespaced. Two groups that each `harvest{into:"items"}`
   * and each `insert{bucket:"items"}` merge into a lens whose cross-reference
   * check keeps one harvest and both inserts — so one group's insert renders the
   * *other* group's rows into the page. Wrong content, injected, and no report
   * says so. Only names a group *declares* are claimed and rewritten: a `bucket`
   * or a `sort.field` naming something this group never harvested is pointing at
   * a bucket the draft already holds, on purpose.
   */
  private adopt(
    ops: LensOp[],
    regions: LensRegion[],
    source: { id: string; name: string } | undefined,
  ): void {
    const renamed = new Map<string, string>();

    for (const region of regions) {
      const existing = this.regionPool.get(region.id);
      if (!existing) {
        this.regionPool.set(region.id, region);
        continue;
      }
      if (sameRegion(existing, region)) continue;

      const id = uniqueKey(region.id, (candidate) => this.regionPool.has(candidate));
      this.regionPool.set(id, { ...region, id });
      renamed.set(region.id, id);
    }

    // Claim first, rewrite second: an `insert` may sit before the `harvest` that
    // fills its bucket, so the references cannot be resolved in one pass.
    const claimedInto = new Map<number, string>();
    const claimedFields = new Map<number, string[]>();
    const bucketRefs = new Map<string, string>();
    const fieldRefs = new Map<string, string>();

    ops.forEach((op, index) => {
      const harvest = op.harvest;
      if (!harvest) return;

      const into = claim(this.buckets, harvest.into);
      claimedInto.set(index, into);
      if (!bucketRefs.has(harvest.into)) bucketRefs.set(harvest.into, into);

      const names = (harvest.fields ?? []).map((field) => {
        const name = claim(this.fields, field.name);
        if (!fieldRefs.has(field.name)) fieldRefs.set(field.name, name);
        return name;
      });
      claimedFields.set(index, names);
    });

    const taken = new Set(this.draft.map((entry) => entry.op.id));
    ops.forEach((op, index) => {
      const region = renamed.get(op.region) ?? op.region;
      const target = op.target ? (renamed.get(op.target) ?? op.target) : undefined;
      const id = taken.has(op.id) ? uniqueKey(op.id, (candidate) => taken.has(candidate)) : op.id;
      taken.add(id);

      const next: LensOp = { ...op, id, region, ...(target ? { target } : {}) };

      const harvest = op.harvest;
      if (harvest) {
        const names = claimedFields.get(index) ?? [];
        next.harvest = {
          ...harvest,
          into: claimedInto.get(index) ?? harvest.into,
          fields: (harvest.fields ?? []).map((field, position) => {
            const name = names[position];
            return name && name !== field.name ? { ...field, name } : field;
          }),
        };
      }
      if (op.bucket) next.bucket = bucketRefs.get(op.bucket) ?? op.bucket;
      if (op.sort?.field) {
        next.sort = { ...op.sort, field: fieldRefs.get(op.sort.field) ?? op.sort.field };
      }

      this.draft.push({ op: next, ...(source ? { source } : {}) });
    });
  }

  // MARK: - Scope

  private patternFor(scope: Scope): string {
    // An edited lens keeps its own pattern until the user chooses another. Its
    // stored pattern need not be any of the three this control can express —
    // `/posts/*/*` is legal in the store — and re-deriving one would quietly
    // move a lens off the pages it was written for.
    if (this.pinnedPattern !== undefined) return this.pinnedPattern;
    if (scope === "site") return "*";
    if (scope === "similar") return this.catalog?.pathPattern ?? "/";
    return this.currentPath();
  }

  private patternLabel(): string {
    const origin = this.catalog?.origin ?? "this site";
    const pattern = this.patternFor(this.scope);
    return pattern === "*" ? `${origin}/*` : `${origin}${pattern}`;
  }

  private currentPath(): string {
    try {
      const path = this.doc.defaultView?.location?.pathname;
      if (path) return path;
    } catch {
      // A cross-origin or detached view. The generalised pattern is still true.
    }
    return this.catalog?.pathPattern ?? "/";
  }

  // MARK: - Events

  private listen(): void {
    const root = this.root;
    const host = this.host;
    const view = this.doc.defaultView;
    if (!root || !host) return;

    // The seal goes on first, at the first object in the event path, in the
    // capture phase — before `document`, before `<body>`, before the host, and
    // therefore before any page listener except one that was already on `window`
    // in capture when the editor opened. A bubble-phase seal on the shadow root
    // cannot do this job: by the time an event bubbles back out, every
    // capture-phase listener the page owns has read it.
    const outermost: EventTarget = view ?? this.doc;
    const seal = (event: Event) => this.sealEvent(event);
    for (const type of SEALED_EVENTS) {
      outermost.addEventListener(type, seal, true);
      this.teardowns.push(() => outermost.removeEventListener(type, seal, true));
    }

    // Second line, on the way out, for whatever the capture seal declined: a
    // click it could not hit-test, and a document with no view, where the
    // outermost thing to seal is `document` and a page listener on `window` is
    // still upstream of it. `stopPropagation`, never `stopImmediatePropagation`:
    // our own listeners on this same node still run.
    const escape = (event: Event) => event.stopPropagation();
    for (const type of SEALED_EVENTS) {
      root.addEventListener(type, escape);
      this.teardowns.push(() => root.removeEventListener(type, escape));
    }

    const onKey = (event: Event) => this.handleKey(event as KeyboardEvent, true);
    root.addEventListener("keydown", onKey);
    this.teardowns.push(() => root.removeEventListener("keydown", onKey));

    // A safety net, in capture, for the case where focus is *not* in the overlay
    // — a page that steals focus back, or a click that landed on the page
    // through the inert scrim. It only handles Escape, and only when the overlay
    // does not hold focus, so it can never double-handle a key the shadow
    // listener already saw.
    const onDocKey = (event: Event) => {
      if (this.root?.activeElement) return;
      this.handleKey(event as KeyboardEvent, false);
    };
    this.doc.addEventListener("keydown", onDocKey, true);
    this.teardowns.push(() => this.doc.removeEventListener("keydown", onDocKey, true));

    if (view) {
      const onScroll = () => this.syncScroll();
      // A resize moves the boxes as well as the scroll offset, and the rects are
      // a snapshot: translating the layer alone leaves every outline over the
      // wrong element. Translate now — it is one style write and the common case
      // — and re-measure once the resize settles.
      const onResize = () => {
        this.syncScroll();
        this.scheduleRemeasure();
      };
      view.addEventListener("scroll", onScroll, { passive: true });
      view.addEventListener("resize", onResize, { passive: true });
      this.teardowns.push(() => {
        view.removeEventListener("scroll", onScroll);
        view.removeEventListener("resize", onResize);
        if (this.remeasureTimer !== undefined) clearTimeout(this.remeasureTimer);
        this.remeasureTimer = undefined;
      });
    }

    // `resize` is the rare reflow. The common one is the page reflowing under a
    // window that never changed size — a lazy image below the fold decoding, a
    // webfont swapping, a router filling in a route — and every outline under it
    // then sits hundreds of pixels off its element while pointing at one is the
    // whole premise of this surface. Watching the root box catches all three,
    // because each of them changes how tall the document is, and it shares the
    // resize path's debounce so a decode storm still costs one re-measure.
    const Resize = view?.ResizeObserver ?? globalThis.ResizeObserver;
    const roots = [this.doc.documentElement, this.doc.body].filter(
      (node, index, all): node is HTMLElement => node != null && all.indexOf(node) === index,
    );
    if (Resize && roots.length > 0) {
      const watcher = new Resize(() => this.scheduleRemeasure());
      for (const node of roots) watcher.observe(node);
      this.teardowns.push(() => watcher.disconnect());
    }

    // The page owns the tree the host lives in and may empty it. If it does, the
    // overlay is off the screen but its document-level capture listener is not,
    // and it would go on swallowing Escape from a page nobody is editing. Watch
    // for it and close properly, so the app hears about it too.
    const Observer = view?.MutationObserver ?? globalThis.MutationObserver;
    if (Observer) {
      const watcher = new Observer(() => {
        if (host.isConnected) return;
        this.close();
      });
      const parent = host.parentNode;
      if (parent) watcher.observe(parent, { childList: true });
      const documentElement = this.doc.documentElement;
      if (documentElement && documentElement !== parent) {
        watcher.observe(documentElement, { childList: true });
      }
      // Before `host.remove()` in `teardown`, so our own removal never queues a
      // record: `disconnect` drops anything already queued.
      this.teardowns.push(() => watcher.disconnect());
    }
  }

  /**
   * Stop one event from reaching the page, and put it back inside the overlay.
   *
   * Called from the capture-phase listener at `window`, so this runs before any
   * page listener on `document` or below — which is the only position from which
   * a keystroke can be kept out of the page at all.
   *
   * The order matters: seal first, replay second, mirror the clone's
   * `preventDefault` onto the original last. Sealing first means a throw in the
   * replay costs the user a click, never the page a copy of their prompt.
   */
  private sealEvent(event: Event): void {
    if (!this.root || !this.fromOverlay(event)) return;

    const replayed = REPLAYED_EVENTS.has(event.type);
    const target = replayed ? this.replayTarget(event) : undefined;
    // An engine that cannot say which control the pointer hit leaves a choice
    // between a leaked click and a dead one, and a dead one is a dead editor —
    // so that click goes through, and the bubble seal on the root is what is left
    // of the defence. Only the pointer can land here: `keydown` and `input`
    // resolve through the focus ring and the prompt, which are always there.
    if (replayed && !target) return;

    event.stopImmediatePropagation();
    if (!target) return;

    try {
      // Uncomposed, so it cannot leave the shadow root and cannot come back
      // round to this listener.
      const clone = cloneForReplay(event, this.doc.defaultView);
      if (!clone) return;
      const allowed = target.dispatchEvent(clone);
      // `dispatchEvent` answering false is the only way back to the original:
      // `preventDefault` on a clone means nothing to the browser, and without
      // this Tab would walk focus out of the overlay and a printable key pressed
      // on a region would be typed twice.
      if (!allowed && event.cancelable) event.preventDefault();
    } catch {
      // A realm that will not construct the clone. The seal still held.
    }
  }

  /** Whether an event started inside the overlay. A closed root retargets to the
   * host and truncates `composedPath` for anyone outside it, so the host *is* the
   * answer from out here; the containment check covers an engine that does not
   * truncate, and our own uncomposed clones. */
  private fromOverlay(event: Event): boolean {
    const root = this.root;
    if (!root || !this.host) return false;

    const origin = composedOrigin(event);
    if (origin === this.host || origin === root) return true;
    return isNode(origin) && root.contains(origin);
  }

  /**
   * Which node inside the overlay a sealed event was really aimed at.
   *
   * `event.target` is no help: from `window` it has been retargeted to the host,
   * and that is the whole point of a closed root. So each replayed family is
   * resolved by what actually determines it — the focus ring for the keyboard,
   * the prompt for its own `input`, and a hit test scoped to our tree for a
   * click, which is what `elementFromPoint` on a shadow root is for.
   */
  private replayTarget(event: Event): Node | undefined {
    const root = this.root;
    if (!root) return undefined;

    const origin = composedOrigin(event);
    if (origin !== this.host && isNode(origin) && root.contains(origin)) return origin;

    if (event.type === "input") return this.input;
    // Never undefined: a key event that started in the overlay had a focused
    // element in it, and the root itself carries the keyboard listener anyway.
    if (event.type === "keydown") return root.activeElement ?? root;

    const point = event as MouseEvent;
    // A click the keyboard synthesised — Space on a focused button — carries
    // `detail: 0` and no coordinates, so hit-testing it would activate whatever
    // happens to sit at the origin. The control that was pressed is the one that
    // has focus, which is the answer the browser used to make the click.
    if (point.detail === 0) return root.activeElement ?? undefined;

    const hitTest = (root as unknown as Partial<DocumentOrShadowRoot>).elementFromPoint;
    if (typeof hitTest === "function" && Number.isFinite(point.clientX)) {
      try {
        const hit = hitTest.call(root, point.clientX, point.clientY);
        if (hit && root.contains(hit)) return hit;
      } catch {
        // An engine with no hit testing. Handled by the caller, which would
        // rather leak a click's coordinates than swallow the click.
      }
    }
    return undefined;
  }

  /** One re-measure per resize gesture rather than one per frame. */
  private scheduleRemeasure(): void {
    if (this.remeasureTimer !== undefined) clearTimeout(this.remeasureTimer);
    this.remeasureTimer = setTimeout(() => {
      this.remeasureTimer = undefined;
      if (!this.root) return;
      this.remeasure();
    }, REMEASURE_DEBOUNCE_MS);
  }

  /** The region layer lives in document space; the host is fixed. One transform
   * keeps every outline over its element as the page scrolls underneath. */
  private syncScroll(): void {
    const view = this.doc.defaultView;
    if (!this.layer || !view) return;
    this.layer.style.transform = `translate(${-(view.scrollX || 0)}px, ${-(view.scrollY || 0)}px)`;
  }

  /**
   * Keyboard model.
   *
   * Esc cancels, ⌘⏎ saves, Tab walks one ring — the bar's controls then every
   * region — and Enter on a region selects it. The ring is closed on purpose:
   * this is a modal surface, and Tab escaping into the page would leave the user
   * typing into a site while an overlay they cannot see still holds a draft.
   *
   * The prompt field does not trap Tab (Tab leaves it like any other control),
   * and because tabbing back from a region would otherwise be a long walk, any
   * printable key pressed on a region jumps to the prompt and takes the
   * character with it.
   */
  private handleKey(event: KeyboardEvent, inside: boolean): void {
    if (!this.root) return;

    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      this.unmount();
      return;
    }

    if (!inside) return;

    const focused = this.root.activeElement as HTMLElement | null;

    if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
      event.preventDefault();
      this.save();
      return;
    }

    if (event.key === "Tab") {
      event.preventDefault();
      this.moveFocus(event.shiftKey ? -1 : 1);
      return;
    }

    if (event.key === "Enter") {
      if (focused === this.input) {
        event.preventDefault();
        this.submitPrompt();
        return;
      }
      const regionID = focused?.dataset?.region;
      if (regionID) {
        event.preventDefault();
        this.toggleRegion(regionID, event.shiftKey);
      }
      return;
    }

    if (
      focused?.dataset?.region &&
      event.key.length === 1 &&
      !event.metaKey &&
      !event.ctrlKey &&
      !event.altKey
    ) {
      event.preventDefault();
      const input = this.input;
      if (!input) return;
      input.value += event.key;
      input.focus();
      this.syncAffordances();
    }
  }

  private moveFocus(delta: number): void {
    const ring = this.focusRing();
    if (ring.length === 0) return;

    const current = this.root?.activeElement as HTMLElement | null;
    const index = current ? ring.indexOf(current) : -1;
    const next = index < 0 ? ring[0] : ring[(index + delta + ring.length) % ring.length];
    next?.focus();
  }

  /**
   * The tab ring, recomputed on every press.
   *
   * Rebuilt rather than cached because chips, and the whole proposal box, come
   * and go while the editor is open — a cached ring would send focus to a button
   * that no longer exists. Bar first, then every region: the controls are the
   * common case, and the regions are the long tail a keyboard user walks.
   */
  private focusRing(): HTMLElement[] {
    const controls = Array.from(
      this.bar?.querySelectorAll<HTMLElement>("button, input") ?? [],
    ).filter((node) => !(node as HTMLButtonElement).disabled && !isHidden(node));

    return [...controls, ...this.regionNodes.values()];
  }

  private candidateFor(region: LensRegion): RegionCandidate | undefined {
    const candidates = this.catalog?.candidates ?? [];
    for (const selector of region.selectors ?? []) {
      const hit = candidates.find(
        (candidate) => candidate.selector === selector || candidate.alternates.includes(selector),
      );
      if (hit) return hit;
    }
    // A model that answers in catalog ids rather than selectors is still
    // answering about regions we offered it.
    return candidates.find((candidate) => candidate.id === region.id);
  }

  /** Everything closing does except hand focus back and tell the app, so a
   * re-mount does not bounce the caret through the page on its way to the new
   * overlay, or report a close that is really an open. */
  private teardown(): void {
    for (const off of this.teardowns) {
      try {
        off();
      } catch {
        // A listener whose target is already gone. Keep tearing down.
      }
    }
    this.teardowns = [];

    this.host?.remove();
    this.host = undefined;
    this.root = undefined;
    this.layer = undefined;
    this.bar = undefined;
    this.input = undefined;
    this.countNode = undefined;
    this.chipList = undefined;
    this.contextList = undefined;
    this.noticeNode = undefined;
    this.proposalBox = undefined;
    this.patternNode = undefined;
    this.saveButton = undefined;
    this.askButton = undefined;
    this.scopeButtons.clear();

    this.regionNodes.clear();
    this.selected.clear();
    this.regionPool.clear();
    this.buckets.clear();
    this.fields.clear();
    this.draft = [];
    this.pending = undefined;
    this.catalog = undefined;
    this.lenses = [];
    this.editing = undefined;
    this.contextLenses = [];
    this.pinnedPattern = undefined;
    this.asking = false;
    this.notice = "";
    this.previousFocus = undefined;
  }
}

export function createLensEditor(doc: Document): LensEditor {
  return new LensEditorOverlay(doc);
}

// MARK: - Helpers

/**
 * What to call a region on screen.
 *
 * Identifiers only — an id, a class token, a role, a tag name. The page's own
 * words are not available here and must not become available: a label reading
 * "Suggested for you" would be page text in our chrome, one copy away from a
 * draft and from the app. Invariant 4.
 */
function regionLabel(candidate: RegionCandidate): string {
  if (candidate.elementID) return `#${candidate.elementID}`;
  const first = candidate.classes[0];
  if (first) return `${candidate.tag}.${first}`;
  if (candidate.role) return `${candidate.tag}[${candidate.role}]`;
  return candidate.tag;
}

/** The deepest node an event was dispatched on that the caller is allowed to
 * see. Guarded because `composedPath` is not on every engine's `Event`, and a
 * page that replaced it is exactly the sort of page this file assumes. */
function composedOrigin(event: Event): EventTarget | null {
  try {
    if (typeof event.composedPath === "function") {
      const path = event.composedPath();
      if (path.length > 0) return path[0] ?? null;
    }
  } catch {
    // A `composedPath` that threw. `target` is the same answer, coarser.
  }
  return event.target;
}

function isNode(target: EventTarget | null): target is Node {
  return target !== null && typeof (target as Node).nodeType === "number";
}

/**
 * Rebuild a sealed event for dispatch inside the shadow root.
 *
 * `composed: false` is load-bearing twice over: it keeps the replay from leaving
 * the root — which is the leak we just stopped — and it keeps the replay from
 * reaching the capture seal that made it, which would recurse.
 *
 * The switch covers `REPLAYED_EVENTS` exactly. Constructors come from the
 * document's own realm where there is one, because an event built from another
 * realm's constructor fails `instanceof` in handlers that check.
 */
function cloneForReplay(
  event: Event,
  view: (Window & typeof globalThis) | null,
): Event | undefined {
  const base = { bubbles: true, cancelable: event.cancelable, composed: false };

  if (event.type === "keydown") {
    const key = event as KeyboardEvent;
    const Keyboard = view?.KeyboardEvent ?? KeyboardEvent;
    return new Keyboard(key.type, {
      ...base,
      key: key.key,
      code: key.code,
      location: key.location,
      repeat: key.repeat,
      isComposing: key.isComposing,
      ctrlKey: key.ctrlKey,
      shiftKey: key.shiftKey,
      altKey: key.altKey,
      metaKey: key.metaKey,
    });
  }

  if (event.type === "click") {
    const mouse = event as MouseEvent;
    const Mouse = view?.MouseEvent ?? MouseEvent;
    return new Mouse(mouse.type, {
      ...base,
      clientX: mouse.clientX,
      clientY: mouse.clientY,
      screenX: mouse.screenX,
      screenY: mouse.screenY,
      button: mouse.button,
      buttons: mouse.buttons,
      detail: mouse.detail,
      ctrlKey: mouse.ctrlKey,
      shiftKey: mouse.shiftKey,
      altKey: mouse.altKey,
      metaKey: mouse.metaKey,
    });
  }

  const Plain = view?.Event ?? Event;
  return new Plain(event.type, base);
}

function setFlag(node: HTMLElement, name: string, on: boolean): void {
  if (on) node.setAttribute(`data-${name}`, "");
  else node.removeAttribute(`data-${name}`);
}

function sameRegion(a: LensRegion, b: LensRegion): boolean {
  const left = a.selectors ?? [];
  const right = b.selectors ?? [];
  return left.length === right.length && left.every((selector, index) => selector === right[index]);
}

/** Take a lens-local name into the draft's shared namespace, renaming it if the
 * draft is already using that name for something else. */
function claim(pool: Set<string>, name: string): string {
  const id = pool.has(name) ? uniqueKey(name, (candidate) => pool.has(candidate)) : name;
  pool.add(id);
  return id;
}

/** Which scope control an existing lens's pattern belongs under. The pattern
 * itself is preserved either way — this only decides which radio reads true. */
function scopeOf(pattern: string, similar: string, page: string): Scope {
  if (pattern === "*") return "site";
  if (pattern === page && pattern !== similar) return "page";
  return "similar";
}

function uniqueKey(base: string, taken: (candidate: string) => boolean): string {
  for (let suffix = 2; suffix < 1000; suffix += 1) {
    const candidate = `${base}-${suffix}`;
    if (!taken(candidate)) return candidate;
  }
  return `${base}-${freshID()}`;
}

/** A lens id must be unique across a store the editor cannot see, so it is a
 * UUID where one is available and a time-plus-entropy string where it is not. */
function freshID(): string {
  try {
    const uuid = globalThis.crypto?.randomUUID?.();
    if (uuid) return uuid;
  } catch {
    // No crypto in this realm.
  }
  return `lens-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

/**
 * Name the lens after what the user asked for.
 *
 * Their own words, so it is recognisable in a popover row a month later, and
 * theirs is the only text on this path that is safe to keep. Called only when
 * there are words: a revised lens keeps the name it already had, because a user
 * who deleted one chip did not ask for their lens to be renamed.
 */
function lensName(prompt: string): string {
  const words = prompt.split(/\s+/).filter((word) => word.length > 0);
  if (words.length === 0) return DEFAULT_LENS_NAME;

  let name = "";
  for (const word of words) {
    const next = name ? `${name} ${word}` : word;
    if (next.length > MAX_NAME_LENGTH) break;
    name = next;
  }
  if (name.length === 0) name = words[0]!.slice(0, MAX_NAME_LENGTH);
  return name.charAt(0).toUpperCase() + name.slice(1);
}

/** A stable hue per lens name, so a chip's attribution colour does not shuffle
 * between sessions. */
function hueFor(value: string): number {
  let hash = 0;
  for (let index = 0; index < value.length; index += 1) {
    hash = (hash * 31 + value.charCodeAt(index)) % 360;
  }
  return hash;
}

function isHidden(node: HTMLElement): boolean {
  return node.hidden || node.closest("[hidden]") !== null;
}

function activeElement(doc: Document): Element | undefined {
  try {
    return doc.activeElement ?? undefined;
  } catch {
    return undefined;
  }
}

/** Hand the caret back to whatever had it before ⌥⌘L. That element may have
 * been removed by the page while the overlay was up, and `focus` is not on every
 * EventTarget. */
function restoreFocus(previous: Element | undefined): void {
  try {
    const target = previous as HTMLElement | undefined;
    if (target?.isConnected && typeof target.focus === "function") target.focus();
  } catch {
    // A page that throws from a focus handler does not get to keep the overlay.
  }
}
