import { WIRE_VERSION, type ReaderCommand, type ReaderEvent } from "./wire.js";

interface WebKitMessageHandler {
  postMessage(body: unknown): void;
}

declare global {
  // eslint-disable-next-line no-var
  var webkit:
    | { messageHandlers?: Record<string, WebKitMessageHandler | undefined> }
    | undefined;
}

export type CommandHandler = (command: ReaderCommand) => void | Promise<void>;

/**
 * The page half of the channel to ZenticKit.
 *
 * Runs in an isolated `WKContentWorld`, so `webkit.messageHandlers` here is the
 * real one — page script cannot reach into this world to replace it or forge
 * events. See the `ReaderBridge` docs on the Swift side.
 */
export class Bridge {
  private handler: CommandHandler | undefined;

  constructor(
    private readonly handlerName: string,
    private readonly debug: boolean,
  ) {
    // Swift invokes `globalThis.__zentic.receive(command)` with a JSON string.
    Object.defineProperty(globalThis, "__zentic", {
      value: { receive: (json: string) => this.receive(json) },
      writable: false,
      configurable: true,
      enumerable: false,
    });
  }

  onCommand(handler: CommandHandler): void {
    this.handler = handler;
  }

  post(event: ReaderEvent): void {
    const channel = globalThis.webkit?.messageHandlers?.[this.handlerName];
    if (!channel) {
      // Expected when running under vitest or in a plain browser during
      // development. Not an error worth surfacing.
      if (this.debug) console.warn("[zentic] no message handler; dropped", event.type);
      return;
    }

    try {
      channel.postMessage(JSON.stringify(event));
    } catch (error) {
      if (this.debug) console.error("[zentic] postMessage failed", error);
    }
  }

  /** Convenience constructors so call sites never assemble an envelope by hand. */
  postReady(bundleVersion: string, url: string): void {
    this.post({ v: WIRE_VERSION, type: "ready", payload: { bundleVersion, url } });
  }

  postFailure(stage: string, error: unknown): void {
    this.post({
      v: WIRE_VERSION,
      type: "failed",
      payload: { stage, message: error instanceof Error ? error.message : String(error) },
    });
  }

  private async receive(json: string): Promise<void> {
    let command: ReaderCommand;
    try {
      command = JSON.parse(json) as ReaderCommand;
    } catch (error) {
      this.postFailure("command.parse", error);
      return;
    }

    if (command.v !== WIRE_VERSION) {
      this.postFailure(
        "command.version",
        new Error(`wire version ${command.v}, expected ${WIRE_VERSION}`),
      );
      return;
    }

    try {
      await this.handler?.(command);
    } catch (error) {
      this.postFailure(`command.${command.type}`, error);
    }
  }
}
