import type { OutboundMessage } from "./types";

interface Handler {
  postMessage(message: unknown): void;
}

/** Post to the `zentic` handler Swift registers in our content world. No-op elsewhere (tests). */
export function post(message: OutboundMessage): void {
  try {
    const handler = (window as unknown as { webkit?: { messageHandlers?: { zentic?: Handler } } }).webkit
      ?.messageHandlers?.zentic;
    handler?.postMessage(message);
  } catch {
    // A page cannot reach this handler, and a failed post must never break the page.
  }
}
