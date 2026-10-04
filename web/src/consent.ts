import AutoConsent, { filterCompactRules, type ConsentState, type RuleBundle } from "@duckduckgo/autoconsent";
// The rules arrive as a string (see the `json-as-text` plugin in build.mjs):
// a 268 KB object literal costs the engine a full compile on every page, a
// string literal costs a scan, and it is only parsed on pages that need it.
import compactRulesText from "@duckduckgo/autoconsent/rules/compact-rules.json";

// Cookie-wall dismissal, via DuckDuckGo's autoconsent.
//
// Runs at document-end (see consent-entry.ts). Known CMP containers are
// pre-hidden from then until the wall is answered, so a dismissed dialog
// rarely gets a frame on screen.
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
  /** Hard stop: give up on a wall after this long. */
  budgetMs: number;
  /** Let autoconsent pre-hide known CMP containers while it works. */
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
  const compact = filterCompactRules(JSON.parse(compactRulesText as unknown as string) as never, {
    url: location.href,
    mainFrame: true,
  });
  const rules: RuleBundle = { autoconsent: [], compact };

  const publish = () => {
    for (const listener of listeners) listener(consent.state);
  };
  const consent = new AutoConsent(
    async (message) => {
      if (options.debug && (message.type === "autoconsentDone" || message.type === "autoconsentError")) {
        console.info("[zentic] autoconsent", message);
      }
      // State moves when the library talks; publish then rather than polling.
      queueMicrotask(publish);
    },
    {
      enabled: true,
      autoAction: "optOut",
      enablePrehide: options.prehide,
      enableCosmeticRules: true,
      enableGeneratedRules: true,
      enableHeuristicDetection: true,
      // Reject-only. Clicking "accept" to make a dialog go away would be
      // consenting on the user's behalf, which is not ours to do.
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

  // AutoConsent#initialize already schedules start() itself. State changes
  // are published as the library sends messages; one slow poll catches the
  // quiet terminal state ("nothing detected"), which sends none.
  return {
    start(): void {
      const poll = setInterval(() => {
        publish();
        if (TERMINAL[consent.state.lifecycle]) clearInterval(poll);
      }, 1000);
      setTimeout(() => clearInterval(poll), options.budgetMs + 100);
    },
    onStateChange(listener): void {
      listeners.push(listener);
    },
  };
}
