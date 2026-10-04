import { dismissConsent } from "./consent";

// The cookie-wall bundle. A separate script from the core, injected at
// document-end rather than document-start: walls are detected in the DOM, so
// nothing is gained by running before the page has parsed, and the library
// plus its rules are ~90% of Zentic's in-page code — kept off the path to
// first paint. Swift installs it only alongside content blocking, so Original
// pages never load it; the mode check below covers a live switch.

export const CONSENT_BUDGET_MS = 8000;

declare global {
  interface Window {
    __zenticConsent?: boolean;
  }
}

const zentic = window.zentic as { mode?: () => string; unlockScroll?: () => void } | undefined;
if (!window.__zenticConsent && zentic?.mode && zentic.mode() !== "original") {
  window.__zenticConsent = true;
  void dismissConsent({ budgetMs: CONSENT_BUDGET_MS, prehide: true, debug: false }).then((outcome) => {
    if (outcome === "dismissed") zentic.unlockScroll?.();
  });
}
