export type Mode = "original" | "clean" | "minimal" | "custom";

export interface CustomVersion {
  base: "clean" | "minimal";
  css: string;
  hide: string[];
}

export interface ZenticConfig {
  mode: Mode;
  /** Non-null only when `mode === "custom"`. */
  custom: CustomVersion | null;
}

export interface SelectorReport {
  selector: string;
  count: number;
  ok: boolean;
  reason?: string;
}

export interface ApplyResult {
  hidden: { selector: string; count: number }[];
  rejected: string[];
}

export type OutboundMessage =
  | { type: "scroll"; y: number; direction: "up" | "down" }
  | { type: "meta"; icon: string | null }
  | {
      type: "login-field";
      role: "username" | "password";
      rect: { x: number; y: number; width: number; height: number };
    }
  | { type: "login-dismiss" }
  | { type: "login-key"; key: "up" | "down" | "enter" | "escape" }
  | { type: "login-submit"; username: string; password: string };

/** Marks every element Zentic itself inserted, so we never disable our own sheets. */
export const OWN = "data-zentic";
