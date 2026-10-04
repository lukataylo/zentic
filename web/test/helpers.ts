import { readFileSync } from "node:fs";
import { join } from "node:path";
import { __resetMinimalForTests } from "../src/minimal";
import { __resetModesForTests } from "../src/modes";
import { clearCustom } from "../src/custom";

export function reset(html: string): void {
  __resetMinimalForTests();
  __resetModesForTests();
  clearCustom();
  // Parsed, not written: document.write would execute the corpus pages' scripts.
  const parsed = new DOMParser().parseFromString(html, "text/html");
  document.replaceChild(document.importNode(parsed.documentElement, true), document.documentElement);
}

export function corpus(name: string): string {
  return readFileSync(join(__dirname, "corpus", "pages", name), "utf8");
}

export function setReadyState(state: DocumentReadyState): void {
  Object.defineProperty(document, "readyState", { configurable: true, get: () => state });
}

export function restoreReadyState(): void {
  delete (document as unknown as Record<string, unknown>).readyState;
}
