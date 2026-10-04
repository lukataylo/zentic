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
  | { type: "meta"; icon: string | null };

/** Marks every element Zentic itself inserted, so we never disable our own sheets. */
export const OWN = "data-zentic";
