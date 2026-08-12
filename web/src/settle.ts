/**
 * Waits for the DOM to stop moving.
 *
 * Extraction needs the post-JavaScript DOM: on an SPA, `DOMContentLoaded` fires
 * against an empty shell, and extracting there produces a reading view of a
 * loading spinner. So we wait for a quiet period with no mutations.
 *
 * Two budgets, and they are not the same kind of thing. `quietPeriodMs` is a
 * *heuristic* — how long without mutations means "done". `ceilingMs` is a
 * **deadline**: some pages never stop mutating (carousels, ad refresh, live
 * tickers) and waiting for quiet on those means waiting forever. Both sit inside
 * `Budget.revealFailsafe`, so even a bug here cannot leave the page hidden.
 */
export interface SettleOptions {
  quietPeriodMs: number;
  ceilingMs: number;
}

export interface SettleResult {
  /** True when a genuine quiet period was observed rather than the ceiling hit. */
  quiet: boolean;
  mutations: number;
  elapsedMs: number;
}

export function waitForSettle(doc: Document, options: SettleOptions): Promise<SettleResult> {
  const started = performance.now();

  return new Promise<SettleResult>((resolve) => {
    let mutations = 0;
    let quietTimer: ReturnType<typeof setTimeout> | undefined;
    let ceilingTimer: ReturnType<typeof setTimeout> | undefined;
    let settled = false;

    const observer =
      typeof MutationObserver === "undefined"
        ? undefined
        : new MutationObserver((records) => {
            mutations += records.length;
            restartQuietTimer();
          });

    const finish = (quiet: boolean) => {
      if (settled) return;
      settled = true;
      if (quietTimer !== undefined) clearTimeout(quietTimer);
      if (ceilingTimer !== undefined) clearTimeout(ceilingTimer);
      observer?.disconnect();
      resolve({ quiet, mutations, elapsedMs: Math.round(performance.now() - started) });
    };

    function restartQuietTimer(): void {
      if (quietTimer !== undefined) clearTimeout(quietTimer);
      quietTimer = setTimeout(() => finish(true), options.quietPeriodMs);
    }

    ceilingTimer = setTimeout(() => finish(false), options.ceilingMs);

    if (!observer || !doc.documentElement) {
      // No observer means no way to tell quiet from busy, so wait out the quiet
      // period once and extract whatever is there.
      restartQuietTimer();
      return;
    }

    // Attributes are excluded deliberately: class churn from hover states and
    // scroll listeners never stops on a real page, and it says nothing about
    // whether the content has arrived.
    observer.observe(doc.documentElement, {
      childList: true,
      subtree: true,
      characterData: true,
    });

    restartQuietTimer();
  });
}
