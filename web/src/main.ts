import { apply, mode, unlockScroll } from "./modes";
import { startMetaReporting } from "./meta";
import { startScrollReporting } from "./scroll";
import { snapshot } from "./snapshot";
import { health } from "./health";
import { recheck } from "./recheck";
import type { ZenticConfig } from "./types";

declare const __ZENTIC_VERSION__: string;

declare global {
  interface Window {
    __zenticConfig?: ZenticConfig;
    zentic?: unknown;
  }
}

// Injected at document-start, main frame only, in the `zentic` content world.
// Swift sets `window.__zenticConfig` in a script just before this one.
if (!window.zentic) {
  window.zentic = Object.freeze({
    version: __ZENTIC_VERSION__,
    apply,
    snapshot,
    health,
    recheck,
    mode,
    unlockScroll,
  });
  try {
    apply(window.__zenticConfig ?? { mode: "original", custom: null });
  } catch (error) {
    console.warn("[zentic] apply failed", error);
  }
  startScrollReporting();
  startMetaReporting();
}
