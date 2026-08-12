import type { Bridge } from "./bridge.js";
import { dismissConsent } from "./consent.js";
import { extract } from "./extract/index.js";
import { buildSkeleton } from "./skeleton.js";
import { waitForSettle } from "./settle.js";
import type { VisibilityController } from "./visibility.js";
import type { ReaderView } from "./render/view.js";
import {
  WIRE_VERSION,
  type ExtractionResult,
  type ReaderConfiguration,
  type ReaderTheme,
  type RevealReason,
  type SiteRecipe,
} from "./wire.js";

/**
 * One pass of the restructure pipeline over the current document.
 *
 * Stage order is the product. Reordering any two of these reintroduces a visible
 * defect the previous order existed to prevent:
 *
 *  1. **Hide + arm the failsafe** — done by the caller at `document-start`, before
 *     anything here runs. Everything below happens under that deadline.
 *  2. **Consent** — started before the settle wait, so the dialog is dismissed
 *     while we are still waiting rather than after we have already extracted it
 *     as content.
 *  3. **Settle** — extraction needs the post-JavaScript DOM.
 *  4. **Extract** — app check first, so a mail client is never even parsed.
 *  5. **Render, then reveal** — never reveal first; that is the flash.
 *  6. **Skeleton, after reveal** — recipe inference must never be on the hot path.
 *
 * Every exit from `run()` is a `RevealReason`. There is no path that returns
 * without one, because the caller uses the return value to reveal the page.
 */
export interface Pipeline {
  run(): Promise<RevealReason>;
}

export interface PipelineContext {
  doc: Document;
  config: ReaderConfiguration;
  bridge: Bridge;
  visibility: VisibilityController;
  view: ReaderView;
  /** Current theme; `applyTheme` replaces it without re-extracting. */
  theme: ReaderTheme;
  recipe: SiteRecipe | undefined;
  /** Last successful extraction, so a rewrite can be discarded back to it. */
  lastResult: ExtractionResult | undefined;
}

export class ReaderPipeline implements Pipeline {
  /** Set once per document: a cookie wall is dismissed on first load, not per route. */
  private consentStarted = false;

  constructor(private readonly context: PipelineContext) {}

  async run(): Promise<RevealReason> {
    const { config, doc, bridge, view } = this.context;
    const debug = config.debugLogging;

    if (!this.consentStarted) {
      this.consentStarted = true;
      // Not awaited. A consent dialog that outlives our budget is still worth
      // dismissing, and waiting for one would spend the reader's whole reveal
      // budget on a banner.
      void dismissConsent({
        budgetMs: config.settleCeilingMs,
        prehide: !this.context.visibility.isHidden,
        debug,
      }).then((outcome) => {
        if (debug) console.info(`[zentic] consent: ${outcome}`);
      });
    }

    const settle = await waitForSettle(doc, {
      quietPeriodMs: config.settleQuietPeriodMs,
      ceilingMs: config.settleCeilingMs,
    });
    if (debug) {
      console.info(
        `[zentic] settle: ${settle.quiet ? "quiet" : "ceiling"} after ${settle.elapsedMs}ms, ${settle.mutations} mutations`,
      );
    }

    const outcome = extract(doc, {
      url: location.href,
      recipe: this.context.recipe,
      minWordCount: config.minWordCount,
      debug,
    });
    if (debug) {
      console.info("[zentic] extract", outcome.timings, {
        archetype: outcome.result.archetype,
        words: outcome.result.wordCount,
        confidence: outcome.result.confidence,
        app: outcome.app.reasons,
      });
    }

    // An app is never restructured and never reported as content. Sending an
    // `extracted` event for someone's mail client would invite something
    // downstream to render it, which is exactly the failure this guards.
    if (outcome.result.archetype === "app") {
      return "passthrough";
    }

    bridge.post({ v: WIRE_VERSION, type: "extracted", payload: outcome.result });
    this.context.lastResult = outcome.result;
    this.scheduleSkeleton(outcome.result.confidence);

    if (outcome.empty) return "extractionEmpty";
    if (outcome.result.confidence < config.minConfidence) {
      if (debug) {
        console.info(
          `[zentic] confidence ${outcome.result.confidence.toFixed(2)} < ${config.minConfidence}; passing through`,
        );
      }
      return "passthrough";
    }

    try {
      view.render(outcome.result, this.context.theme);
    } catch (error) {
      // A render failure must not look like a budget overrun, and it must not
      // leave a half-built overlay on screen. Tear it down and show the original.
      bridge.postFailure("render", error);
      view.destroy();
      return "passthrough";
    }

    return "rendered";
  }

  /**
   * Ask the app to infer a recipe, once the page is already on screen.
   *
   * Only when generic extraction was shaky — a confident extraction needs no
   * recipe, and a `needsRecipe` per pageview would be noise. Deferred with a
   * timer so building the skeleton cannot delay the reveal.
   */
  private scheduleSkeleton(confidence: number): void {
    const { config, bridge, doc } = this.context;
    if (this.context.recipe || confidence >= 0.8) return;

    setTimeout(() => {
      try {
        bridge.post({
          v: WIRE_VERSION,
          type: "needsRecipe",
          payload: buildSkeleton(doc, {
            url: location.href,
            nodeLimit: config.skeletonNodeLimit,
          }),
        });
      } catch (error) {
        bridge.postFailure("skeleton", error);
      }
    }, 0);
  }
}
