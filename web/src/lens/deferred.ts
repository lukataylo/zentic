import type { LensEditor } from "./editor.js";

// Where the two halves of the lens editor meet.
//
// `editor.ts` is 59KB — nearly half the lens code and a third of the whole
// injected script — and none of it can run until the user presses ⌥⌘L. Bundled
// into `main.ts` it was parsed on every navigation in every tab for an overlay
// almost no pageview ever opens. So it ships as a second bundle
// (`zentic-lens-editor.js`) which `ReaderBridge.deliverLensEditor(to:)`
// evaluates into this same `zentic` `WKContentWorld` on the way into lens mode.
//
// Same world, so page script still cannot see or patch the editor. And a page
// that never enters lens mode never fetches, parses or runs a byte of it —
// nothing on the reveal path touches this file.
//
// The `import type` above is erased by esbuild, so naming the interface here
// costs the document-start bundle nothing.

export type LensEditorFactory = (doc: Document) => LensEditor;

/** The property the editor bundle publishes itself under. An isolated world's
 * global: the page holds no reference to this object at all. */
export const LENS_EDITOR_GLOBAL = "__zenticLensEditor";

/**
 * The delivered factory, or `undefined` when the second bundle has not been
 * evaluated in this document.
 *
 * Deliberately not an `import()`: a dynamic import from an injected script has
 * no module URL to resolve against, and it would put a network fetch on the path
 * of a keystroke. The app delivers the bundle, and delivers it *before* the
 * command that needs it, so `undefined` here means a real failure — reported,
 * never shrugged off.
 */
export function deferredLensEditor(): LensEditorFactory | undefined {
  const slot = (globalThis as unknown as Record<string, unknown>)[LENS_EDITOR_GLOBAL];
  return typeof slot === "function" ? (slot as LensEditorFactory) : undefined;
}
