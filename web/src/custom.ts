import { sanitizeCSS } from "./sanitize";
import { OWN, type ApplyResult, type CustomVersion } from "./types";
import { validate } from "./validate";

// A custom version: the model's CSS plus a list of things to hide, layered on
// a base (clean or minimal). Our <style id="zentic-custom"> is always appended
// after the minimal sheet so it wins on equal specificity.

const CUSTOM_ID = "zentic-custom";
const HIDE_ATTR = "hide";

let current: CustomVersion | null = null;
let result: ApplyResult = { hidden: [], rejected: [] };
let readyListener: (() => void) | null = null;

export function applyCustom(version: CustomVersion): ApplyResult {
  current = version;
  render();
  if (document.readyState === "loading" && !readyListener) {
    // At document-start there is no body to measure against; validate again
    // once there is, and drop anything that turns out to swallow the page.
    readyListener = () => {
      readyListener = null;
      if (current) render();
    };
    document.addEventListener("DOMContentLoaded", readyListener, { once: true });
  }
  return result;
}

export function clearCustom(): void {
  current = null;
  result = { hidden: [], rejected: [] };
  document.getElementById(CUSTOM_ID)?.remove();
  document.querySelector(`style[${OWN}="${HIDE_ATTR}"]`)?.remove();
}

function render(): void {
  if (!current) return;
  const parent = document.head ?? document.documentElement;

  const reports = validate(current.hide ?? []);
  const good = reports.filter((r) => r.ok);
  result = {
    hidden: good.map((r) => ({ selector: r.selector, count: r.count })),
    rejected: reports.filter((r) => !r.ok).map((r) => r.selector),
  };

  let style = document.getElementById(CUSTOM_ID) as HTMLStyleElement | null;
  if (!style) {
    style = document.createElement("style");
    style.id = CUSTOM_ID;
    style.setAttribute(OWN, "custom");
  }
  style.textContent = sanitizeCSS(current.css ?? "");

  let hide = document.querySelector<HTMLStyleElement>(`style[${OWN}="${HIDE_ATTR}"]`);
  if (!hide) {
    hide = document.createElement("style");
    hide.setAttribute(OWN, HIDE_ATTR);
  }
  // One rule per selector, so one the engine rejects cannot void the rest.
  hide.textContent = good.map((r) => `${r.selector}{display:none!important}`).join("\n");

  // Always last: after the minimal sheet, after anything the site appends.
  parent.appendChild(style);
  parent.appendChild(hide);
}
