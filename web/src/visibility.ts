import type { RevealPayload, RevealReason } from "./wire.js";

/**
 * Marks a root this bundle hid, so the release only ever removes an inline
 * `visibility` the reader itself set — never one the site put there — and so a
 * fresh controller can release a document the previous cycle concealed.
 */
const HIDDEN_MARK = "data-zentic-hidden";

/** The stylesheet that stops the original document painting the canvas. */
const CANVAS_STYLE_ID = "zentic-canvas-suppress";

/**
 * How often a concealed document re-checks that the reader is still covering it.
 *
 * Every deliberate way out of concealment calls `reveal()` and is therefore
 * instant. This is for the ways that do not: the page's own script removing our
 * host, an SPA assigning to `body.innerHTML`, anything that takes the overlay off
 * screen without telling us. A quarter-second of a stale reading view is a
 * blemish; a window that never comes back is a broken browser.
 */
const COVER_CHECK_MS = 250;

/**
 * Keeps the original document hidden while the reader works, and guarantees it
 * becomes visible again.
 *
 * The problem this solves: extraction needs a DOM, so it cannot run before the
 * page paints. Run it after and the user sees the ad-laden original flash past
 * before the clean version replaces it. So the document is hidden at
 * `document-start` and revealed once we have something to show.
 *
 * That trade is only acceptable with an unconditional escape hatch. A visible
 * flash is a blemish; a window that never paints is a broken browser. Hence the
 * failsafe timer, and hence the ordering in `hide()`.
 *
 * ## Concealment
 *
 * The reader's overlay is translucent, so "reveal the original underneath it" is
 * no longer safe: the site's own text and images bleed through the reading view.
 * So on the one path where the reader is actually on screen — `reveal("rendered")`
 * — the root stays hidden, and the overlay shows through it by setting
 * `visibility: visible` on itself.
 *
 * That is a hidden document with the failsafe already spent, which is exactly the
 * state invariant 1 exists to forbid. Three rules make it safe, and each has a
 * test:
 *
 *  1. Concealment is only ever *entered* while `isCovered()` says the overlay is
 *     mounted, connected and painting. Not "was rendered once" — is covering now.
 *  2. The watchdog is started **before** anything is concealed, the same ordering
 *     as `hide()` arming the failsafe first. If it cannot be started, nothing is
 *     concealed.
 *  3. `release()` is unconditional. It takes no predicate, asks no question, and
 *     is the single exit — every reveal reason but `rendered`, every watchdog
 *     tick that finds the overlay gone, and the tick after the reader is torn
 *     down all land there.
 */
export class VisibilityController {
  private hidden = false;
  private didReveal = false;
  private failsafeTimer: ReturnType<typeof setTimeout> | undefined;
  private coverTimer: ReturnType<typeof setInterval> | undefined;
  private readonly startedAt = performance.now();

  /**
   * @param onReveal Reported to the app, once per cycle.
   * @param isCovered Whether the reader's overlay is on screen and painting over
   *   the viewport. Defaults to "it is not", so a controller built without one
   *   behaves exactly as it did before concealment existed: every reveal shows
   *   the document.
   */
  constructor(
    private readonly onReveal: (payload: RevealPayload) => void,
    private readonly isCovered: () => boolean = () => false,
  ) {}

  get isHidden(): boolean {
    return this.hidden;
  }

  get hasRevealed(): boolean {
    return this.didReveal;
  }

  /**
   * Hide the document and arm the failsafe.
   *
   * The timer is armed *before* the page is hidden, deliberately. If hiding threw
   * — an exotic document type, a detached documentElement — an
   * arm-after-hide ordering would leave the page hidden with nothing scheduled to
   * bring it back. Arming first means the worst case is a redundant reveal.
   */
  hide(failsafeMs: number): void {
    if (this.hidden || this.didReveal) return;

    this.failsafeTimer = setTimeout(() => this.reveal("failsafe"), failsafeMs);

    this.suppressCanvas();

    // Never throws. A caller that fails here would abort the rest of bundle
    // startup — leaving no command handler and no pipeline — so a document we
    // cannot hide is treated as a document we simply don't hide.
    try {
      const root = document.documentElement;
      if (!root) return;

      // Inline style rather than a <style> element: at document-start
      // `document.head` may not exist yet, and appending to a partially-parsed
      // document is fragile.
      //
      // Note for the render layer: `visibility` inherits, so the reader's own
      // container must set `visibility: visible` on itself to show through this.
      root.style.setProperty("visibility", "hidden", "important");
      root.setAttribute(HIDDEN_MARK, "");
      this.hidden = true;
    } catch {
      this.hidden = false;
    }
  }

  /**
   * Reveal the document. Idempotent as an *event* — the first reason wins and the
   * app hears about the cycle once.
   *
   * It is not idempotent as *state*. The document's visibility has to keep
   * following the overlay for as long as the page lives: ⌘\ arrives here as
   * `userRequested` long after the reader revealed as `rendered`, and a render
   * that lands after the failsafe already fired arrives as a second `rendered`.
   * Ignoring those was what left the original bleeding through the reader — or,
   * worse, left a hidden document with nobody minding it.
   */
  reveal(reason: RevealReason): void {
    if (this.didReveal) {
      if (reason === "rendered") this.conceal();
      else this.release();
      return;
    }
    this.didReveal = true;

    if (this.failsafeTimer !== undefined) {
      clearTimeout(this.failsafeTimer);
      this.failsafeTimer = undefined;
    }

    // `rendered` is the one reason that does not put the original back on screen:
    // the reader is covering it, and the reader is translucent. Every other reason
    // — failsafe, passthrough, empty extraction, the user asking — means the
    // overlay is not what they are looking at, so the page must come back.
    if (reason === "rendered") this.conceal();
    else this.release();

    this.onReveal({
      reason,
      elapsedMs: Math.round(performance.now() - this.startedAt),
    });
  }

  /**
   * Put the original document back behind the reader's overlay.
   *
   * Called on the way into `reveal("rendered")`, and again by ⌘\ back to the
   * reader — showing a translucent overlay over a revealed page is what makes the
   * site's own text appear underneath ours.
   *
   * Declines unless the overlay is covering the viewport *right now*, and unless
   * the watchdog is running. A page this refuses to conceal is a page the user can
   * see, which is always the safe answer.
   */
  conceal(): void {
    if (!this.covered() || !this.startWatchdog()) {
      this.release();
      return;
    }

    this.suppressCanvas();
    if (this.hidden) return;

    try {
      const root = document.documentElement;
      if (!root) {
        this.release();
        return;
      }
      root.style.setProperty("visibility", "hidden", "important");
      root.setAttribute(HIDDEN_MARK, "");
      this.hidden = true;
    } catch {
      this.release();
    }
  }

  /**
   * Reset for a same-document navigation, so an SPA route change gets its own
   * hide/reveal cycle and its own elapsed measurement.
   *
   * The new controller inherits the coverage predicate — it is a property of the
   * reader, not of one cycle — and the old one's timers are dropped so neither its
   * failsafe nor its watchdog can act on a cycle it knows nothing about.
   */
  restartedForNavigation(): VisibilityController {
    if (this.failsafeTimer !== undefined) clearTimeout(this.failsafeTimer);
    this.stopWatchdog();
    return new VisibilityController(this.onReveal, this.isCovered);
  }

  // MARK: - Internals

  /**
   * Show the original document. The single exit from concealment, and the one
   * place that undoes a hide.
   *
   * Deliberately unconditional and predicate-free: it does not ask whether *this*
   * controller hid the page, because a controller handed a document its
   * predecessor concealed still has to be able to release it. What it does check
   * is the mark, so an inline `visibility` the site set on its own root is left
   * exactly as the site wrote it.
   */
  private release(): void {
    this.stopWatchdog();
    this.restoreCanvas();
    this.hidden = false;

    try {
      const root = document.documentElement;
      if (!root?.hasAttribute(HIDDEN_MARK)) return;
      root.style.removeProperty("visibility");
      root.removeAttribute(HIDDEN_MARK);
    } catch {
      // Nothing further to try. The next tick of any surviving watchdog, and the
      // next reveal, both come back through here.
    }
  }

  /** The predicate, made safe to call: a throw means "not covered", which reveals. */
  private covered(): boolean {
    try {
      return this.isCovered() === true;
    } catch {
      return false;
    }
  }

  /** @returns whether a watchdog is running. Nothing is concealed unless it is. */
  private startWatchdog(): boolean {
    if (this.coverTimer !== undefined) return true;
    try {
      this.coverTimer = setInterval(() => {
        if (!this.covered()) this.release();
      }, COVER_CHECK_MS);
      return true;
    } catch {
      return false;
    }
  }

  private stopWatchdog(): void {
    if (this.coverTimer === undefined) return;
    clearInterval(this.coverTimer);
    this.coverTimer = undefined;
  }

  /**
   * Stop the original document painting the canvas.
   *
   * `visibility: hidden` hides the root element's *box*. The background of the
   * root — or of `<body>`, when the root's is transparent — is propagated to the
   * canvas and painted by the viewport rather than by that box, so a site's white
   * body background can still fill the whole window behind a translucent reader.
   *
   * A `<style>` rather than an inline style, for two reasons: at document-start
   * `<body>` does not exist yet to carry one, and removing an element restores the
   * site's own inline background exactly, where clobbering a longhand would not.
   * `!important` is what beats a site's inline style. Page script deleting this
   * element costs the user transparency, never the page.
   */
  private suppressCanvas(): void {
    try {
      if (document.getElementById(CANVAS_STYLE_ID)) return;
      const style = document.createElement("style");
      style.id = CANVAS_STYLE_ID;
      style.textContent = "html, body { background: transparent !important; }";
      (document.head ?? document.documentElement)?.appendChild(style);
    } catch {
      // Cosmetic. A site's background showing behind the reader is a worse-looking
      // page, not a broken one, and must never cost us the rest of `hide()`.
    }
  }

  private restoreCanvas(): void {
    try {
      document.getElementById(CANVAS_STYLE_ID)?.remove();
    } catch {
      // As above.
    }
  }
}
