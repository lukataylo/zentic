import type { FontKey } from "../wire.js";

/**
 * `FontKey` → CSS `font-family` stack.
 *
 * Mirrors `FontKey.cssStack` in Sources/ZenticKit/Reader/ReaderTheme.swift. The
 * duplication is deliberate: Swift owns the enum because a model fills it in with
 * guided generation, but the stack has to exist here because only the bundle
 * writes CSS. `theme.test.ts` asserts every key in the TS union has an entry, so
 * adding a case on the Swift side without one here fails a test.
 *
 * Every stack is local — no webfont can be named, so a theme cannot cause a
 * network request. That is the same reason the set is closed at all.
 */
const STACKS: Record<FontKey, string> = {
  systemSans: "system-ui, -apple-system, sans-serif",
  helveticaNeue: '"Helvetica Neue", Helvetica, sans-serif',
  avenirNext: '"Avenir Next", Avenir, sans-serif',
  optima: "Optima, sans-serif",
  futura: "Futura, sans-serif",
  gillSans: '"Gill Sans", "Gill Sans MT", sans-serif',
  verdana: "Verdana, Geneva, sans-serif",
  arial: "Arial, Helvetica, sans-serif",
  systemSerif: 'ui-serif, "New York", Georgia, serif',
  georgia: "Georgia, serif",
  palatino: 'Palatino, "Palatino Linotype", serif',
  timesNewRoman: '"Times New Roman", Times, serif',
  charter: "Charter, Georgia, serif",
  americanTypewriter: '"American Typewriter", Georgia, serif',
  systemMono: 'ui-monospace, "SF Mono", Menlo, monospace',
  menlo: "Menlo, monospace",
  monaco: "Monaco, monospace",
  courierNew: '"Courier New", Courier, monospace',
  impact: 'Impact, "Haettenschweiler", sans-serif',
  comicSans: '"Comic Sans MS", "Chalkboard SE", cursive',
  markerFelt: '"Marker Felt", cursive',
  chalkboard: '"Chalkboard SE", "Comic Sans MS", cursive',
  copperplate: 'Copperplate, "Copperplate Gothic Light", fantasy',
  papyrus: "Papyrus, fantasy",
};

/**
 * Resolve a font key, falling back rather than trusting the input.
 *
 * The key arrives as a JSON string, so it is only a `FontKey` by convention. A
 * value outside the table must never reach the stylesheet: `"x; background:
 * url(http://tracker)"` would otherwise be interpolated straight into CSS.
 */
export function fontStack(key: FontKey | string | undefined, fallback: FontKey): string {
  return STACKS[key as FontKey] ?? STACKS[fallback];
}

export const FONT_KEYS = Object.keys(STACKS) as FontKey[];
