import { LENS_EDITOR_GLOBAL } from "./deferred.js";
import { createLensEditor } from "./editor.js";

// Entry point of the on-demand editor bundle. See `deferred.ts` for why the
// editor is not in the document-start script.
//
// It publishes rather than exports because this is evaluated as a script body,
// not imported: `evaluateJavaScript` hands us a realm, not a module graph. The
// assignment is idempotent, so a redelivery — a page that reloaded between two
// presses of ⌥⌘L — costs a parse and nothing else.

(globalThis as unknown as Record<string, unknown>)[LENS_EDITOR_GLOBAL] = createLensEditor;
