import type { RevealPayload, RevealReason } from "./wire.js";

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
 */
export class VisibilityController {
  private hidden = false;
  private didReveal = false;
  private reportedReason: RevealReason | undefined;
  private failsafeTimer: ReturnType<typeof setTimeout> | undefined;
  private readonly startedAt = performance.now();

  constructor(private readonly onReveal: (payload: RevealPayload) => void) {}

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
      this.hidden = true;
    } catch {
      this.hidden = false;
    }
  }

  /**
   * Report what the pipeline actually did.
   *
   * `reveal` is first-wins, which is correct for un-hiding a document — it must
   * happen once — but wrong as a *description* of the page. On a slow site the
   * failsafe fires first and the pipeline renders a moment later; the reader
   * overlay is then on screen, but the only thing the app was ever told is
   * "failsafe". It concludes the page was not restructured and disables the
   * control that switches back to the original — on a page that is very much
   * restructured. So an outcome that contradicts what was already reported is
   * sent once more, and the last word describes what the user is looking at.
   */
  settle(reason: RevealReason): void {
    if (!this.didReveal) {
      this.reveal(reason);
      return;
    }
    if (reason === this.reportedReason) return;
    this.reportedReason = reason;
    this.onReveal({ reason, elapsedMs: Math.round(performance.now() - this.startedAt) });
  }

  /** Reveal the document. Idempotent — the first reason wins, later calls are ignored. */
  reveal(reason: RevealReason): void {
    if (this.didReveal) return;
    this.didReveal = true;
    this.reportedReason = reason;

    if (this.failsafeTimer !== undefined) {
      clearTimeout(this.failsafeTimer);
      this.failsafeTimer = undefined;
    }

    if (this.hidden) {
      document.documentElement?.style.removeProperty("visibility");
      this.hidden = false;
    }

    this.onReveal({
      reason,
      elapsedMs: Math.round(performance.now() - this.startedAt),
    });
  }

  /**
   * Reset for a same-document navigation, so an SPA route change gets its own
   * hide/reveal cycle and its own elapsed measurement.
   */
  restartedForNavigation(): VisibilityController {
    if (this.failsafeTimer !== undefined) clearTimeout(this.failsafeTimer);
    return new VisibilityController(this.onReveal);
  }
}
