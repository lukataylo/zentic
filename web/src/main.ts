import { Bridge } from "./bridge.js";
import { dismissConsent } from "./consent.js";
import { deferredLensEditor } from "./lens/deferred.js";
import type { LensEditor } from "./lens/editor.js";
import { LensEngine, engineOptions } from "./lens/index.js";
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

  const view = new ReaderView(document);

  // The reader's overlay is translucent, so the original document cannot be
  // revealed underneath it — it would bleed through the reading view. The
  // controller therefore keeps it hidden while the overlay is covering the
  // viewport, and this is how it asks. Live, not a snapshot: `isCovering` is what
  // turns "the page removed our host" into "show the user their page".
  let visibility = new VisibilityController(onReveal, () => view.isCovering);

  /** Post one whole-lens report per lens. Also the engine's own channel for a
   * report it revised after the pass that produced it — a region that lazy-renders
   * below the fold would otherwise leave the badge amber for the life of the page.
   *
   * An empty array is not posted. It can only mean no lens matched this page, and
   * the app has nothing to do with that: `lensReports` is already keyed by lens id
   * and already reset per navigation, so an empty report changes no number on the
   * chrome. It is a bridge crossing on every load of every unlensed page — which
   * is nearly all of them. The engine's own revised-report channel has always
   * suppressed the empty case; this is the same rule on the pass path. */
  const postReports = (reports: ReturnType<LensEngine["runPass"]>) => {
    if (reports.length === 0) return;
    bridge.post({ v: WIRE_VERSION, type: "lensReport", payload: reports });
  };

  // Before anything else, and before the eligibility check: a lens applies to
  // apps and passthrough origins too — that is the point of it — and its
  // stylesheet has to be in the cascade before the page's own markup parses, or
  // the user sees the box they asked to lose. Nothing here hides the document or
  // touches the reveal path; invariant 1 stays the reader's alone.
  //
  // Construction is inside the guard with everything else it does. A throw here
  // — a malformed lens in the bootstrap, a DOM this build has never seen — used
  // to take `main()` down with it, and with it the reader, the consent dismissal
  // and the reveal. The engine is optional; the page is not.
  //
  // On a page with no lenses the engine is still built — ⌥⌘L needs its region
  // catalog, and authoring a first lens is the *primary* path for the feature —
  // but it is not started. `setLenses([])` and a pass over an empty set resolve
  // nothing and query nothing, yet each still appends a `<style>` element to
  // `documentElement`: a style recalc, and a node the page's own script can see,
  // both bought on every load of every page that has no lens on it, which is
  // nearly all of them. So the engine is only driven once there is something for
  // it to drive.
  let lenses: LensEngine | undefined;
  let hasLenses = (config.lenses ?? []).length > 0;
  try {
    lenses = new LensEngine(document, engineOptions(config), {
      // A lens acts on the site's own DOM. While the reader is showing its own
      // render of the page, that DOM is hidden, so nothing a lens does is on
      // screen and no report may claim otherwise.
      isReaderRendered: () => view.isRendered,
      onReport: postReports,
    });
    if (hasLenses) lenses.setLenses(config.lenses ?? []);
  } catch (error) {
    lenses = undefined;
    bridge.postFailure("lens.engine", error);
  }

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

  /** One structural pass plus its report. Never throws: a lens failure must not
   * be able to stop the reader, or the consent dismissal, from running. */
  const runLensPass = () => {
    if (!lenses || !hasLenses) return;
    try {
      postReports(lenses.runPass());
    } catch (error) {
      bridge.postFailure("lens.pass", error);
    }
  };

  /** Run a lens command without letting it become an unhandled rejection.
   *
   * The command handler is `async`, so a throw out of one of these cases became a
   * rejected promise nobody awaits: the app is told nothing, the console shows an
   * unhandled rejection, and the user sees a button that did not work. */
  const guarded = (stage: string, run: (engine: LensEngine) => void) => {
    if (!lenses) return;
    try {
      run(lenses);
    } catch (error) {
      bridge.postFailure(stage, error);
    }
  };

  // On a same-document navigation the URL changes before the route's DOM exists,
  // so an immediate pass would report every op as drift. The stylesheet is
  // re-injected at once (it is what prevents the flash) and the structural pass
  // waits for the same quiet period the reader waits for.
  const runLensPassAfterSettle = async () => {
    if (!lenses || !hasLenses) return;
    try {
      // The old route's observers go first: for the whole settle window they
      // would otherwise be watching regions the router is tearing down.
      lenses.stopWatching();
      lenses.injectStylesheet();
      await waitForSettle(document, {
        quietPeriodMs: config.settleQuietPeriodMs,
        ceilingMs: config.settleCeilingMs,
      });
    } catch (error) {
      bridge.postFailure("lens.settle", error);
    }
    runLensPass();
  };

  let editor: LensEditor | undefined;

  /** The overlay is built once and reused: its callbacks are registered here, so
   * entering lens mode twice cannot double every draft the user saves.
   *
   * `undefined` when the editor bundle has not been delivered into this document.
   * It is not in the document-start script — see `lens/deferred.ts` — and the app
   * evaluates it before it sends the command that needs it, so this is a real
   * failure and every caller reports it rather than doing nothing visible. */
  const lensEditor = (): LensEditor | undefined => {
    if (editor) return editor;
    const create = deferredLensEditor();
    if (!create) return undefined;
    const overlay = create(document);
    editor = overlay;
    overlay.onDraft((lens) => bridge.post({ v: WIRE_VERSION, type: "lensDraft", payload: lens }));
    overlay.onPrompt((text, selectedRegionIDs) => {
      // No engine means no catalog, and a prompt without one would ask the model
      // to author ops against a page it was never shown. Whatever the reason, the
      // editor has to hear that the ask is not coming back: it disables Ask while
      // one is outstanding, so a silent drop ends the session at "asking…".
      if (!lenses) {
        overlay.promptFailed("Lenses are not running on this page, so there is nothing to ask.");
        return;
      }
      try {
        bridge.post({
          v: WIRE_VERSION,
          type: "lensPrompt",
          payload: { text, selectedRegionIDs, catalog: lenses.catalog() },
        });
      } catch (error) {
        bridge.postFailure("lens.prompt", error);
        overlay.promptFailed("That ask could not be sent.");
      }
    });
    // Esc, Cancel, Save and the page removing the host all end here, so the app's
    // idea of whether the editor is up cannot drift from the page's — which is
    // what made the next ⌥⌘L take two presses.
    overlay.onClose(() =>
      bridge.post({ v: WIRE_VERSION, type: "lensModeChanged", payload: false }),
    );
    return overlay;
  };

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
      // The pass that ran at DOM ready acted on the site's own DOM. If the reader
      // has since rendered over it, that report describes a page nobody can see —
      // so it is replaced by one that says so. Only when the reader actually
      // rendered: a declined page is still the page, and re-running the pass on it
      // would be work with no effect.
      if (view.isRendered) runLensPass();
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
          // The site's own DOM is what the user is now looking at, so this is the
          // moment the lens's structural ops become visible — and the moment its
          // report starts describing something real. The stylesheet was never
          // removed, so the CSS half of the lens is already in place: no flash.
          runLensPass();
        } else if (view.isRendered) {
          view.show();
          // Showing the overlay used to be all of "back to the reader": it was
          // opaque, so the revealed original behind it did not matter. It is
          // translucent now, so the site's own page has to go back behind it —
          // otherwise the user reads our article through theirs. `conceal()`
          // declines unless the overlay really is covering, so this cannot be the
          // thing that blanks the window.
          visibility.conceal();
          // Undo the structural ops and stop reporting them: they are true of a
          // page that is no longer on screen.
          runLensPass();
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

      case "applyDocument":
        // The model laid out the page; we still own what is in the placeholders.
        if (context.lastResult) {
          view.renderDocument(command.payload.html, context.lastResult, context.theme);
        } else {
          bridge.postFailure("applyDocument", new Error("no extraction to lay out"));
        }
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

      case "applyLenses":
        // Replace, clear, re-run: the engine owns the reset, so enabling a lens
        // and editing one land on exactly the same path.
        guarded("lens.apply", (engine) => {
          // "Empty, and always was" is the one case with nothing to do — a page
          // that has never had a lens on it, being told again. Every other shape
          // goes through the engine, including an empty set arriving where there
          // was one: that is an undo, and `setLenses` is what performs it.
          if (!hasLenses && command.payload.length === 0) return;
          hasLenses = command.payload.length > 0;
          engine.setLenses(command.payload);
          runLensPass();
        });
        break;

      case "requestRegions":
        guarded("lens.regions", (engine) =>
          bridge.post({ v: WIRE_VERSION, type: "lensRegions", payload: engine.catalog() }),
        );
        break;

      case "enterLensMode":
        guarded("lens.enterMode", (engine) => {
          // `editing` names the one lens to load as a draft. Without it this is a
          // new lens and the editor adopts nothing: handing it the applied set to
          // absorb made Save write a lens holding every other lens's ops, all of
          // them still enabled and every op applied twice.
          //
          // The applied set is *enabled and path-matching*, and the app offers
          // Edit on every lens the site has. So `editing` naming a lens that is
          // not in it is a request this page cannot serve — the editor refuses it
          // rather than opening blank and authoring a duplicate, and the failure
          // says which id, because the app is the only side that can fix it.
          const editing = command.payload?.editing;
          const overlay = lensEditor();
          if (!overlay) {
            // The app delivers the editor bundle on the way in, so this is either
            // a delivery that failed or a document that replaced itself between
            // the two. Say so: the user is standing over a keystroke waiting, and
            // silence here is indistinguishable from a broken shortcut.
            bridge.postFailure(
              "lens.enterMode",
              new Error("the editor was not delivered to this page"),
            );
            return;
          }
          const mounted = overlay.mount(engine.catalog(), engine.appliedLenses, editing);
          // Only claim the mode when the overlay is actually up. Announcing it for
          // a mount that failed leaves the app closing an editor that was never
          // there, and the user pressing ⌥⌘L twice to get one.
          if (mounted) {
            bridge.post({ v: WIRE_VERSION, type: "lensModeChanged", payload: true });
          } else if (editing) {
            bridge.postFailure(
              "lens.enterMode",
              new Error(`lens ${editing} is not applied to this page, so it cannot be edited here`),
            );
          } else {
            bridge.postFailure("lens.enterMode", new Error("the editor could not be built"));
          }
        });
        break;

      case "exitLensMode":
        // The editor's own `onClose` reports the change, for this route out and
        // every other. With no editor there is nothing to close, but say so
        // anyway: a lens mode the app believes is open and the page has never
        // heard of costs the user a keystroke every time.
        if (editor) editor.unmount();
        else bridge.post({ v: WIRE_VERSION, type: "lensModeChanged", payload: false });
        break;

      case "proposeOps":
        // Highlight first, apply on confirm. A prompt must never go straight to
        // an effect the user has not seen described.
        //
        // No editor means no overlay to highlight in — the page reloaded out from
        // under an outstanding ask. Reported, because the model's answer is being
        // dropped and the app is the only side that can tell the user so.
        guarded("lens.proposeOps", () => {
          const overlay = lensEditor();
          if (!overlay) {
            bridge.postFailure(
              "lens.proposeOps",
              new Error("no editor is open on this page to show a proposal in"),
            );
            return;
          }
          overlay.showProposal(command.payload);
        });
        break;
    }
  });

  // Installed on both paths, unconditionally. The reader half only matters when
  // the page is eligible, but a lens on a single-page app sees *every*
  // navigation as a same-document one, so this is the only signal it gets.
  watchForSameDocumentNavigation(() => {
    if (debug) console.info(`[zentic] same-document navigation to ${location.pathname}`);

    void runLensPassAfterSettle();
    if (!eligible) return;

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

  // A page we will not extract still reports, so the app can tell "declined" from
  // "the bundle never ran". It is also the primary path for lenses, which is why
  // this return comes after the engine and the navigation watcher have been wired
  // rather than before them.
  //
  // Consent is gated on the level rather than run unconditionally: below Calm the
  // user asked us to block requests, not to click buttons on their behalf.
  if (!allowed.pipeline) {
    if (allowed.consent) {
      // Nothing was hidden, so autoconsent may pre-hide the CMP container itself.
      void dismissConsent({ budgetMs: config.settleCeilingMs, prehide: true, debug });
    }
    visibility.reveal("passthrough");
    // The only path a lens gets on a page the reader never runs on, and the
    // primary one for the feature. Nothing is waiting on it here.
    whenReady(runLensPass);
    return;
  }

  // One listener, in this order, and the order is the whole point.
  //
  // The document is hidden and the failsafe is already ticking, so every
  // millisecond before extraction starts is spent out of the user's reveal
  // budget. The lens pass is fully synchronous and can spend its whole
  // `lensOpPassCeiling`; running it first pushed the reader's settle wait that
  // much later and made the failsafe that much likelier to fire. Kicking `start`
  // off first costs nothing — it awaits `waitForSettle` immediately — so the
  // settle window and the op pass now overlap instead of queueing.
  //
  // The pass still lands before extraction reads the DOM, which is what mattered
  // about the old ordering: a lens that hides the junk improves the extraction it
  // runs ahead of, and never the reverse.
  whenReady(() => {
    void start();
    runLensPass();
  });
}

function whenReady(run: () => void): void {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", run, { once: true });
  } else {
    run();
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
