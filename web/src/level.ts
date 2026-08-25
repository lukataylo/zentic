import type { PageLevel, ReaderConfiguration } from "./wire.js";

const ORDER: readonly PageLevel[] = ["original", "clean", "calm", "reader", "rewritten"];

/** Whether `level` is at or above `floor`. Unknown values sort lowest — see `plan`. */
export function atLeast(level: PageLevel, floor: PageLevel): boolean {
  const a = ORDER.indexOf(level);
  const b = ORDER.indexOf(floor);
  return a >= 0 && b >= 0 && a >= b;
}

/**
 * What the bundle is allowed to do on this page.
 *
 * A plain function of the configuration rather than three conditionals scattered
 * through `main`, for two reasons. It is the only way any of this is testable —
 * `main.ts` calls `main()` on import, so importing it to test it runs it. And the
 * hide decision must be reachable through exactly one branch: splitting it across
 * `level` and `eligible` in two places is how you get a hidden page with no armed
 * failsafe, which is invariant 1's failure mode.
 */
export interface LevelPlan {
  /** Hide the document at `document-start` and arm the reveal failsafe. */
  hide: boolean;
  /** Dismiss a cookie wall. An action taken in the user's name, so it is gated. */
  consent: boolean;
  /** Run extraction at all. */
  pipeline: boolean;
  /** Put the reader's overlay on screen if extraction succeeds. */
  render: boolean;
}

const NOTHING: LevelPlan = { hide: false, consent: false, pipeline: false, render: false };

/**
 * - `original` — nothing whatsoever. The bundle still reports `ready`, so the app
 *   can tell "declined" from "the bundle never ran".
 * - `clean` — network rules only, and those are WebKit's job. Notably no consent:
 *   a level that promised to block requests must not also press buttons.
 * - `calm` — consent and extraction run, but the page is never hidden and the
 *   overlay never shown. Extraction still reports, which is how the app learns
 *   this origin's archetype for next time.
 * - `reader` and up — the full path, subject to `eligible` and to whether the
 *   origin has earned an unhidden first paint.
 */
export function plan(
  config: ReaderConfiguration,
  eligible: boolean,
  isInstantOrigin: boolean,
): LevelPlan {
  // An unrecognised level fails closed to doing nothing, matching `isEligible`:
  // anything we do not understand means leave the page alone.
  if (ORDER.indexOf(config.level) < 0) return NOTHING;
  if (config.level === "original") return NOTHING;

  if (config.level === "clean") {
    return { hide: false, consent: false, pipeline: false, render: false };
  }

  if (config.level === "calm") {
    return { hide: false, consent: true, pipeline: true, render: false };
  }

  // reader and rewritten
  return {
    hide: eligible && !isInstantOrigin,
    consent: true,
    pipeline: true,
    render: eligible,
  };
}
