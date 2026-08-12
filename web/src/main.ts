import { Bridge } from "./bridge.js";
import { dismissConsent } from "./consent.js";
import { ReaderPipeline, type Pipeline, type PipelineContext } from "./pipeline.js";
import { ReaderView } from "./render/view.js";
import { buildSkeleton } from "./skeleton.js";
import { VisibilityController } from "./visibility.js";
import { WIRE_VERSION, type ReaderConfiguration, type RevealPayload } from "./wire.js";

declare const __ZENTIC_VERSION__: string;

const HANDLER_NAME = "zentic";

export type { Pipeline };

function readConfiguration(): ReaderConfiguration | null {
  const raw = (globalThis as { __zenticConfig?: ReaderConfiguration | null }).__zenticConfig;
  return raw ?? null;
}

/**
 * Whether the reader should hide this document at all.
 *
 * Fails closed: anything unrecognised means leave the page alone. Declining to
 * restructure costs the user a cluttered page they were expecting anyway;
 * wrongly restructuring an app they depend on costs their trust.
 */
function isEligible(config: ReaderConfiguration): boolean {
  if (config.mode !== "restructured") return false;
  if (config.recipe?.quirks.includes("neverRestructure")) return false;
  if (config.recipe?.archetype === "app") return false;

  try {
    if (config.passthroughOrigins.includes(location.origin)) return false;
  } catch {
    // An opaque origin (sandboxed frame, `about:` document) is never eligible.
    return false;
  }

  // Only real web content. Extension pages, PDFs and error pages are left alone.
  return location.protocol === "https:" || location.protocol === "http:";
}

function main(): void {
  const config = readConfiguration();
  const debug = config?.debugLogging ?? false;
  const bridge = new Bridge(HANDLER_NAME, debug);

  if (!config) {
    // The bootstrap script failed to encode. Do nothing at all rather than guess
    // with defaults — a wrong failsafe budget is worse than no reader.
    bridge.postFailure("bootstrap", new Error("__zenticConfig missing"));
    return;
  }

  const onReveal = (payload: RevealPayload) => {
    bridge.post({ v: WIRE_VERSION, type: "revealed", payload });
    if (debug) console.info(`[zentic] revealed: ${payload.reason} in ${payload.elapsedMs}ms`);
  };

  let visibility = new VisibilityController(onReveal);
  const view = new ReaderView(document);

  const eligible = isEligible(config);
  if (eligible) {
    visibility.hide(config.revealFailsafeMs);
  }

  bridge.postReady(__ZENTIC_VERSION__, location.href);

  const context: PipelineContext = {
    doc: document,
    config,
    bridge,
    visibility,
    view,
    theme: config.theme,
    recipe: config.recipe,
    lastResult: undefined,
  };

  const pipeline: Pipeline = new ReaderPipeline(context);

  const start = async () => {
    try {
      visibility.reveal(await pipeline.run());
    } catch (error) {
      // Any pipeline failure must still reveal the page. The failsafe timer would
      // catch this eventually, but revealing now saves the user the full wait.
      bridge.postFailure("pipeline", error);
      visibility.reveal("failsafe");
    }
  };

  bridge.onCommand(async (command) => {
    switch (command.type) {
      case "setMode":
        if (command.payload === "original") {
          // Instant: the source DOM was only hidden, never replaced, so there is
          // nothing to rebuild and no reload.
          view.hide();
          visibility.reveal("userRequested");
        } else if (view.isRendered) {
          // The overlay is opaque and covers the viewport, so showing it again is
          // all that "back to the reader" requires — the original underneath does
          // not need re-hiding, and re-hiding it would risk a blank window for no
          // benefit.
          view.show();
        } else {
          await start();
        }
        break;

      case "applyTheme":
        // Presentation only: no re-extraction, no model call, no reload.
        context.theme = command.payload;
        view.applyTheme(command.payload);
        break;

      case "applyRecipe":
        context.recipe = command.payload;
        view.clear();
        await start();
        break;

      case "requestSkeleton":
        bridge.post({
          v: WIRE_VERSION,
          type: "needsRecipe",
          payload: buildSkeleton(document, {
            url: location.href,
            nodeLimit: config.skeletonNodeLimit,
          }),
        });
        break;

      case "applyRewrite":
        if (!view.applyRewrite(command.payload.sectionID, command.payload.markdown)) {
          bridge.postFailure(
            "applyRewrite",
            new Error(`unknown section ${command.payload.sectionID}`),
          );
        }
        break;

      case "discardRewrite":
        if (context.lastResult) view.render(context.lastResult, context.theme);
        break;
    }
  });

  // An ineligible page still reports, so the app can tell "declined" from
  // "the bundle never ran" — and still gets its cookie wall dismissed, which is
  // the strip layer's job regardless of whether we restructure.
  if (!eligible) {
    // Nothing was hidden, so autoconsent may pre-hide the CMP container itself.
    void dismissConsent({ budgetMs: config.settleCeilingMs, prehide: true, debug });
    visibility.reveal("passthrough");
    return;
  }

  watchForSameDocumentNavigation(() => {
    if (debug) console.info(`[zentic] same-document navigation to ${location.pathname}`);

    // A fresh controller per navigation: its own hide, its own failsafe, and its
    // own elapsed measurement, so an SPA route change is diagnosable separately
    // from the initial load.
    visibility = visibility.restartedForNavigation();
    context.visibility = visibility;
    view.clear();
    visibility.hide(config.revealFailsafeMs);
    void start();
  });

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    void start();
  }
}

/**
 * Detect same-document (SPA) navigation.
 *
 * Three mechanisms, because none is sufficient alone:
 *
 *  - **`popstate` / `hashchange`** cover back/forward and anchor changes. DOM
 *    events reach isolated content worlds, so these are reliable here.
 *  - **Patching `history.pushState`** is the textbook approach and is included,
 *    but on its own it would not work: we run in the `zentic` `WKContentWorld`,
 *    which has its own `History` wrapper. Patching it intercepts *our* calls, not
 *    the page's. It stays because it costs nothing and covers same-world callers.
 *  - **Polling `location.href`** is the one that actually catches a React router
 *    calling `pushState` in the page world. 300ms is imperceptible next to the
 *    render it triggers, and reading `location.href` is free.
 *
 * The callback fires only when the URL genuinely changed, debounced, because
 * routers commonly push twice for one navigation.
 */
function watchForSameDocumentNavigation(onNavigate: () => void): void {
  let lastUrl = location.href;
  let timer: ReturnType<typeof setTimeout> | undefined;

  const check = () => {
    if (location.href === lastUrl) return;
    lastUrl = location.href;
    if (timer !== undefined) clearTimeout(timer);
    timer = setTimeout(onNavigate, 50);
  };

  addEventListener("popstate", check);
  addEventListener("hashchange", check);

  for (const method of ["pushState", "replaceState"] as const) {
    const original = history[method];
    history[method] = function patched(this: History, ...args: Parameters<History["pushState"]>) {
      const result = original.apply(this, args);
      check();
      return result;
    };
  }

  setInterval(check, 300);
}

main();
