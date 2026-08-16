import { Bridge } from "./bridge.js";
import { dismissConsent } from "./consent.js";
import { atLeast, plan } from "./level.js";
import { ReaderPipeline, type Pipeline, type PipelineContext } from "./pipeline.js";
import { ReaderView } from "./render/view.js";
import { waitForSettle } from "./settle.js";
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

/**
 * Whether this origin has earned an unhidden first paint.
 *
 * Same fail-closed handling as ``isEligible``: an origin we cannot read is not
 * one we have learned anything about, so it takes the normal hidden path.
 */
function isInstantOrigin(config: ReaderConfiguration): boolean {
  try {
    return config.instantOrigins.includes(location.origin);
  } catch {
    return false;
  }
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
  // An origin that has declined to restructure several times running. The reader
  // still runs — that is how the app learns the site has changed — but the page is
  // never hidden for it, so navigation costs nothing at all.
  const instant = isInstantOrigin(config);
  // One decision, made once. Every gate below reads from this rather than
  // re-deriving its own answer from `level` and `eligible`.
  const allowed = plan(config, eligible, instant);

  if (allowed.hide) {
    visibility.hide(config.revealFailsafeMs);
  }

  // Armed here, at `document-start`, rather than when the pipeline runs. The
  // pipeline does not start until `DOMContentLoaded`, and by then the DOM has
  // usually stopped moving — so the quiet period was being served *after* the page
  // was already finished instead of overlapping its load. Starting now means the
  // common case is a settle that has already resolved by the time it is awaited.
  const pendingSettle = allowed.pipeline
    ? waitForSettle(document, {
        quietPeriodMs: config.settleQuietPeriodMs,
        ceilingMs: config.settleCeilingMs,
      })
    : undefined;

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
    pendingSettle,
    mayRender: allowed.render && !instant,
    dismissesCookieWalls: allowed.consent,
  };

  const pipeline: Pipeline = new ReaderPipeline(context);

  const start = async () => {
    try {
      // `settle`, not `reveal`: if the failsafe already showed the page, the
      // pipeline's verdict is still the truth about what is now on screen.
      visibility.settle(await pipeline.run());
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

      case "setLevel": {
        // Recompute what this page is permitted to do, then act on it.
        //
        // The permissions were cached at load time, which is correct for the load
        // and wrong for everything after it: a page that arrived at Calm had
        // `render: false` baked in, so a later `setMode` would run the whole
        // pipeline and then decline to show the result. The level moved, the page
        // did not, and the control looked stuck.
        config.level = command.payload;
        // `mode` moves with it, or `isEligible` keeps answering from the clamp
        // applied at load and the same staleness bites one layer down.
        config.mode = atLeast(command.payload, "reader") ? "restructured" : "original";
        const next = plan(config, isEligible(config), instant);
        context.mayRender = next.render;
        context.dismissesCookieWalls = next.consent;

        if (!next.render) {
          view.hide();
          visibility.reveal("userRequested");
        } else if (view.isRendered) {
          view.show();
        } else {
          await start();
        }
        break;
      }

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

  // A page we will not extract still reports, so the app can tell "declined" from
  // "the bundle never ran".
  //
  // Consent is now gated on the level rather than run unconditionally: below Calm
  // the user asked us to block requests, not to click buttons on their behalf.
  if (!allowed.pipeline) {
    if (allowed.consent) {
      // Nothing was hidden, so autoconsent may pre-hide the CMP container itself.
      void dismissConsent({ budgetMs: config.settleCeilingMs, prehide: true, debug });
    }
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
    if (allowed.hide) visibility.hide(config.revealFailsafeMs);
    // Armed before `start()` for the same reason as the initial load: the router
    // is mutating the DOM right now, and the watch should cover that, not begin
    // after it.
    context.pendingSettle = waitForSettle(document, {
      quietPeriodMs: config.settleQuietPeriodMs,
      ceilingMs: config.settleCeilingMs,
    });
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
