import { applyCustom, clearCustom } from "./custom";
import { disableMinimal, enableMinimal, minimalActive } from "./minimal";
import { OWN, type ApplyResult, type Mode, type ZenticConfig } from "./types";

// The one switch. Every mode is reachable from every other without a reload;
// Swift reloads on its own only when content blocking has to change.

let currentMode: Mode = "original";

export function apply(config: ZenticConfig | null | undefined): ApplyResult {
  const mode = normaliseMode(config?.mode);
  const custom = mode === "custom" ? config?.custom ?? null : null;
  currentMode = custom || mode !== "custom" ? mode : "clean";

  const minimal = currentMode === "minimal" || (currentMode === "custom" && custom?.base === "minimal");
  // Off before Minimal reads what the site hides, so a previous version's
  // hides are never mistaken for the site's own. Same task, so no flicker —
  // and only then, because re-adding a stylesheet restyles the page.
  if (minimal && !minimalActive()) clearCustom();
  if (minimal) enableMinimal();
  else disableMinimal();

  setCleanFixes(currentMode !== "original");

  if (currentMode === "custom" && custom) {
    return applyCustom({ base: custom.base === "minimal" ? "minimal" : "clean", css: custom.css ?? "", hide: custom.hide ?? [] });
  }
  clearCustom();
  return { hidden: [], rejected: [] };
}

export function mode(): Mode {
  return currentMode;
}

function normaliseMode(value: unknown): Mode {
  return value === "clean" || value === "minimal" || value === "custom" ? value : "original";
}

let cleanEnabled = false;
function setCleanFixes(on: boolean): void {
  cleanEnabled = on;
  if (!on) document.querySelector(`style[${OWN}="unlock"]`)?.remove();
}

/**
 * A dismissed consent wall often leaves the page scroll-locked behind it.
 * Called by the consent bundle (`consent-entry.ts`) through `window.zentic`.
 */
export function unlockScroll(): void {
  if (!cleanEnabled || !document.body) return;
  const html = getComputedStyle(document.documentElement).overflowY;
  const body = getComputedStyle(document.body).overflowY;
  if (html !== "hidden" && body !== "hidden") return;
  if (document.querySelector(`style[${OWN}="unlock"]`)) return;
  const style = document.createElement("style");
  style.setAttribute(OWN, "unlock");
  style.textContent = "html,body{overflow-y:auto!important}";
  (document.head ?? document.documentElement).appendChild(style);
}

/** Test hook. */
export function __resetModesForTests(): void {
  currentMode = "original";
  cleanEnabled = false;
}
