import { startPasswords } from "./passwords";

// The sign-in bundle. Separate from the core so the core's document-start
// budget is untouched, and injected at document-end: it only adds listeners.
// Swift prefixes `window.__zenticPasswordSave = true` except in private
// windows, where sign-ins are never reported.

declare global {
  interface Window {
    __zenticPasswordSave?: boolean;
    zenticPasswords?: unknown;
  }
}

if (!window.zenticPasswords) {
  window.zenticPasswords = Object.freeze(startPasswords(window.__zenticPasswordSave === true));
}
