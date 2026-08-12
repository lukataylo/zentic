import AutoConsent, { filterCompactRules, type ConsentState, type RuleBundle } from "@duckduckgo/autoconsent";
import compactRules from "@duckduckgo/autoconsent/rules/compact-rules.json";

// Cookie-wall dismissal, via DuckDuckGo's autoconsent.
//
// Runs as early as possible — before the settle wait, not after — for one
// reason: a consent dialog that has already painted is a dialog the user saw. On
// an eligible page the document is hidden anyway, so this is belt-and-braces
// there; on a page we decline to restructure it is the only thing standing
// between the reader and the wall.
//
// ## Why not the extension wiring
//
// Autoconsent is built for a browser extension: a content script that asks a
// background page for rules and for main-world `eval`. We have neither. Rules
// are bundled instead (compact form, filtered by URL before decoding), and
// `isMainWorld` is set so snippet evaluation happens inline.
//
// That last part is a real, accepted limitation. We run in the `zentic`
// `WKContentWorld`, so page globals — `window.__tcfapi` and friends — are not
// visible to us. Rules that detect a CMP by probing those globals will report
// "not found" instead of the truth. They fail *closed*: a missed CMP means the
// wall stays, never that we click the wrong button. The selector-driven rules,
// which are the large majority, work unchanged because the DOM is shared.
// Fixing the rest needs a Swift-side eval bridge into the page world.

export type ConsentOutcome = "dismissed" | "none" | "timeout" | "unavailable";

export interface ConsentOptions {
  /** Hard stop. Sits inside the reveal failsafe, like every other stage. */
  budgetMs: number;
  /**
   * Whether to let autoconsent pre-hide known CMP containers.
   *
   * Off when the reader has already hidden the whole document: a second hiding
   * mechanism with its own 2s expiry can only fight ours.
   */
  prehide: boolean;
  debug: boolean;
}

/** Injectable so tests can drive the lifecycle without the vendored rules. */
export interface ConsentDriver {
  start(): void;
  onStateChange(listener: (state: ConsentState) => void): void;
}

const TERMINAL: Partial<Record<ConsentState["lifecycle"], ConsentOutcome>> = {
  optOutSucceeded: "dismissed",
  optInSucceeded: "dismissed",
  optOutFailed: "none",
  optInFailed: "none",
  nothingDetected: "none",
  done: "dismissed",
};

/**
 * Dismiss any cookie wall on the current page.
 *
 * Resolves when autoconsent reaches a terminal state or the budget expires,
 * whichever comes first, and never rejects — a failure to dismiss a cookie
 * banner must not stop the page being read.
 */
export function dismissConsent(
  options: ConsentOptions,
  makeDriver: (options: ConsentOptions) => ConsentDriver | undefined = defaultDriver,
): Promise<ConsentOutcome> {
  return new Promise<ConsentOutcome>((resolve) => {
    let done = false;
    const finish = (outcome: ConsentOutcome) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve(outcome);
    };

    const timer = setTimeout(() => finish("timeout"), options.budgetMs);

    let driver: ConsentDriver | undefined;
    try {
      driver = makeDriver(options);
    } catch (error) {
      if (options.debug) console.warn("[zentic] autoconsent failed to initialise", error);
    }

    if (!driver) {
      finish("unavailable");
      return;
    }

    driver.onStateChange((state) => {
      const outcome = TERMINAL[state.lifecycle];
      if (outcome) finish(outcome);
    });

    driver.start();
  });
}

function defaultDriver(options: ConsentOptions): ConsentDriver | undefined {
  if (typeof window === "undefined" || !document.documentElement) return undefined;

  const listeners: ((state: ConsentState) => void)[] = [];

  // Filtering before decoding matters: the bundled ruleset is ~780 CMPs and
  // decoding all of them costs more than the whole rest of the pipeline. This
  // keeps the generic rules plus the ones whose URL pattern matches.
  const compact = filterCompactRules(compactRules as never, {
    url: location.href,
    mainFrame: true,
  });
  const rules: RuleBundle = { autoconsent: [], compact };

  const consent = new AutoConsent(
    async (message) => {
      if (message.type === "autoconsentDone" || message.type === "autoconsentError") {
        if (options.debug) console.info("[zentic] autoconsent", message);
      }
    },
    {
      enabled: true,
      autoAction: "optOut",
      enablePrehide: options.prehide,
      enableCosmeticRules: true,
      enableGeneratedRules: true,
      enableHeuristicDetection: true,
      // Reject-only. Clicking "accept" to make a dialog go away would be
      // consenting on the reader's behalf, which is not ours to do.
      heuristicMode: "reject",
      // The default is 20 retries at ~half a second each, which is an order of
      // magnitude past our entire budget.
      detectRetries: 4,
      isMainWorld: true,
      prehideTimeout: options.budgetMs,
      logs: {
        lifecycle: options.debug,
        rulesteps: false,
        detectionsteps: false,
        evals: false,
        errors: options.debug,
        messages: false,
        waits: false,
      },
    },
    rules,
  );

  // AutoConsent#initialize already schedules start() itself, so the driver's
  // start() only has to publish state transitions. Polling rather than patching:
  // the library exposes no state-change hook, and monkey-patching a vendored
  // class is how a dependency bump turns into a silent regression.
  return {
    start(): void {
      const poll = setInterval(() => {
        const state = consent.state;
        for (const listener of listeners) listener(state);
        if (TERMINAL[state.lifecycle]) clearInterval(poll);
      }, 50);
      setTimeout(() => clearInterval(poll), options.budgetMs + 100);
    },
    onStateChange(listener): void {
      listeners.push(listener);
    },
  };
}
