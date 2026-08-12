import type { Palette, ReaderTheme, ThemeTokens } from "../wire.js";
import { fontStack } from "./fonts.js";

// Compiles `ThemeTokens` into CSS custom properties for the shadow root.
//
// ## Why this file is paranoid
//
// Swift's `ThemeTokens.validated()` already clamps ranges and repairs contrast,
// but this compiler cannot rely on that. Tokens reach us as JSON over a bridge,
// they can come from a user-edited store or (in M5) from a model, and the type
// annotations vanish at runtime. So every value written into CSS is either
//
//   - a number we clamped ourselves and formatted, or
//   - the result of a lookup in a fixed table, or
//   - a `#rrggbb` string we re-parsed.
//
// A raw token string is never interpolated. That is what makes invariant 5
// enforceable *here* rather than only upstream: `url(` cannot appear in the
// output because there is no path from an input string to the output that isn't
// one of those three. `theme.test.ts` attacks this with hostile tokens.

/** Clamp, and treat a non-finite value as the low end rather than propagating NaN. */
function clamp(value: unknown, min: number, max: number, fallback: number): number {
  const number = typeof value === "number" && Number.isFinite(value) ? value : fallback;
  return Math.min(Math.max(number, min), max);
}

/** Fixed-precision so no value ever reaches CSS as `1e-7` or `0.30000000000000004`. */
function num(value: number, decimals = 3): string {
  return Number(value.toFixed(decimals)).toString();
}

const HEX = /^#?([0-9a-f]{3}|[0-9a-f]{6})$/i;

/** Canonical `#rrggbb`, or the fallback. The only route a colour takes into CSS. */
function color(value: unknown, fallback: string): string {
  if (typeof value !== "string") return fallback;
  const match = HEX.exec(value.trim());
  if (!match) return fallback;
  const hex = match[1]!.toLowerCase();
  return hex.length === 3
    ? `#${hex[0]}${hex[0]}${hex[1]}${hex[1]}${hex[2]}${hex[2]}`
    : `#${hex}`;
}

function channels(hex: string): [number, number, number] {
  const raw = Number.parseInt(hex.slice(1), 16);
  return [(raw >> 16) & 0xff, (raw >> 8) & 0xff, raw & 0xff];
}

function toHex([r, g, b]: [number, number, number]): string {
  const clamped = [r, g, b].map((c) => Math.min(255, Math.max(0, Math.round(c))));
  return `#${clamped.map((c) => c.toString(16).padStart(2, "0")).join("")}`;
}

/** Mix towards white (`amount > 0`) or black (`amount < 0`). Used for bevel faces. */
function shade(hex: string, amount: number): string {
  const [r, g, b] = channels(hex);
  const target = amount > 0 ? 255 : 0;
  const t = Math.abs(amount);
  return toHex([r + (target - r) * t, g + (target - g) * t, b + (target - b) * t]);
}

// MARK: - Enum tables
//
// Each maps a token to CSS. A missing key falls back, so an unknown enum case
// from a newer Swift build degrades to something sane instead of emitting the
// unrecognised string.

const RULE_STYLE: Record<string, { style: string; width: number }> = {
  none: { style: "none", width: 0 },
  hairline: { style: "solid", width: 1 },
  solid: { style: "solid", width: 2 },
  double: { style: "double", width: 3 },
  dashed: { style: "dashed", width: 1 },
  // groove and ridge need >=2px to read as 3D at all — at 1px the two tones
  // collapse into one line and the ornament silently disappears.
  groove: { style: "groove", width: 3 },
  ridge: { style: "ridge", width: 3 },
};

const LIST_STYLE: Record<string, string> = {
  disc: "disc",
  circle: "circle",
  square: "square",
  dash: "none",
  arrow: "none",
  none: "none",
};

/** `content` for `::marker`. `normal` restores the browser's own bullet. */
const MARKER_CONTENT: Record<string, string> = {
  disc: "normal",
  circle: "normal",
  square: "normal",
  dash: '"– "',
  arrow: '"→ "',
  none: '""',
};

const LINK: Record<string, { line: string; style: string; thickness: string; highlight: string }> = {
  none: { line: "none", style: "solid", thickness: "auto", highlight: "transparent" },
  underline: { line: "underline", style: "solid", thickness: "1px", highlight: "transparent" },
  thickUnderline: { line: "underline", style: "solid", thickness: "3px", highlight: "transparent" },
  dotted: { line: "underline", style: "dotted", thickness: "1px", highlight: "transparent" },
  highlight: {
    line: "none",
    style: "solid",
    thickness: "auto",
    highlight: "color-mix(in srgb, var(--z-accent) 22%, transparent)",
  },
};

const HEADING_CASE: Record<string, { transform: string; variant: string }> = {
  asIs: { transform: "none", variant: "normal" },
  upper: { transform: "uppercase", variant: "normal" },
  // Real small caps needs lowercase input: `font-variant-caps` only affects
  // lowercase letters, so an all-caps heading would show no effect at all.
  smallCaps: { transform: "lowercase", variant: "small-caps" },
};

/**
 * `box-shadow` per elevation.
 *
 * `bevel` is the load-bearing case and the reason this is a function rather than
 * a table: the retro theme needs a *hard* 3D edge, so every length is exact and
 * the blur radius is 0. Any blur reads as a modern drop shadow and the 1997 look
 * collapses. Faces are derived from the surface colour so the bevel works in
 * both appearances.
 */
function elevation(kind: string, surface: string): string {
  switch (kind) {
    case "none":
      return "none";
    case "raised":
      return "0 4px 14px rgba(0, 0, 0, 0.14)";
    case "bevel":
      return [
        `inset 2px 2px 0 0 ${shade(surface, 0.55)}`,
        `inset -2px -2px 0 0 ${shade(surface, -0.45)}`,
        `2px 2px 0 0 ${shade(surface, -0.7)}`,
      ].join(", ");
    case "subtle":
    default:
      return "0 1px 2px rgba(0, 0, 0, 0.06)";
  }
}

// MARK: - Palette

const LIGHT_FALLBACK: Palette = {
  background: "#ffffff",
  surface: "#f5f5f5",
  text: "#1a1a1a",
  textMuted: "#5f5f5f",
  accent: "#0a58ca",
  visited: "#6b4fbb",
  border: "#dcdcdc",
  codeBackground: "#f2f2f2",
};

const DARK_FALLBACK: Palette = {
  background: "#141414",
  surface: "#1f1f1f",
  text: "#f2f2f2",
  textMuted: "#a0a0a0",
  accent: "#7aa2f7",
  visited: "#b9a0f0",
  border: "#2e2e2e",
  codeBackground: "#1b1b1b",
};

function paletteVars(palette: Partial<Palette> | undefined, fallback: Palette): string[] {
  const resolved: Palette = {
    background: color(palette?.background, fallback.background),
    surface: color(palette?.surface, fallback.surface),
    text: color(palette?.text, fallback.text),
    textMuted: color(palette?.textMuted, fallback.textMuted),
    accent: color(palette?.accent, fallback.accent),
    visited: color(palette?.visited, fallback.visited),
    border: color(palette?.border, fallback.border),
    codeBackground: color(palette?.codeBackground, fallback.codeBackground),
  };

  return [
    `--z-bg: ${resolved.background}`,
    `--z-surface: ${resolved.surface}`,
    `--z-text: ${resolved.text}`,
    `--z-text-muted: ${resolved.textMuted}`,
    `--z-accent: ${resolved.accent}`,
    `--z-visited: ${resolved.visited}`,
    `--z-border: ${resolved.border}`,
    `--z-code-bg: ${resolved.codeBackground}`,
    // Selection and hairlines want the border colour at partial strength;
    // color-mix keeps that a token operation rather than a second colour input.
    `--z-selection: color-mix(in srgb, var(--z-accent) 25%, transparent)`,
  ];
}

// MARK: - Compile

/** The colour of the page behind everything, for the host element's inline style. */
export function pageBackground(tokens: ThemeTokens | undefined, dark: boolean): string {
  return dark
    ? color(tokens?.dark?.background, DARK_FALLBACK.background)
    : color(tokens?.light?.background, LIGHT_FALLBACK.background);
}

/**
 * Compile a theme to a stylesheet for the shadow root.
 *
 * Light is the base and dark is a `prefers-color-scheme` override, so appearance
 * changes need no JavaScript and no re-render — the same reason `applyTheme` only
 * has to replace this one stylesheet.
 */
export function compileTheme(theme: ReaderTheme | undefined): string {
  const tokens = theme?.tokens;
  const type = tokens?.typography;
  const shape = tokens?.shape;
  const ornament = tokens?.ornament;

  const baseSize = clamp(type?.baseSize, 13, 24, 17);
  const scale = clamp(type?.scaleRatio, 1.05, 1.6, 1.25);
  const lineHeight = clamp(type?.lineHeight, 1.1, 2.0, 1.6);
  const measure = clamp(type?.measure, 45, 100, 70);
  const letterSpacing = clamp(type?.letterSpacing, -0.03, 0.15, 0);
  const density = clamp(tokens?.density, 0.6, 1.6, 1);
  const radius = clamp(shape?.radius, 0, 24, 8);
  const borderWidth = clamp(shape?.borderWidth, 0, 4, 1);

  const rule = RULE_STYLE[String(ornament?.rule)] ?? RULE_STYLE["hairline"]!;
  const listMarker = String(ornament?.listMarker);
  const link = LINK[String(ornament?.linkDecoration)] ?? LINK["underline"]!;
  const headingCase = HEADING_CASE[String(ornament?.headingCase)] ?? HEADING_CASE["asIs"]!;
  const dropCap = ornament?.dropCap === true;
  const justify = ornament?.justify === true;

  // Heading sizes are precomputed rather than expressed as CSS calc chains: CSS
  // has no exponentiation, and nesting four multiplications per level makes the
  // resulting stylesheet unreadable in Web Inspector.
  const step = (level: number) => num(baseSize * Math.pow(scale, level), 2);
  const space = (steps: number) => num(baseSize * 0.5 * density * steps, 2);

  const shared = [
    `--z-font-body: ${fontStack(type?.body, "systemSans")}`,
    `--z-font-heading: ${fontStack(type?.heading, "systemSans")}`,
    `--z-font-mono: ${fontStack(type?.mono, "systemMono")}`,
    `--z-size-base: ${num(baseSize, 2)}px`,
    `--z-size-h1: ${step(3)}px`,
    `--z-size-h2: ${step(2)}px`,
    `--z-size-h3: ${step(1.4)}px`,
    `--z-size-h4: ${step(0.8)}px`,
    `--z-size-h5: ${step(0.4)}px`,
    `--z-size-h6: ${step(0)}px`,
    `--z-size-small: ${num(baseSize / scale, 2)}px`,
    `--z-line-height: ${num(lineHeight)}`,
    `--z-measure: ${num(measure, 1)}ch`,
    `--z-letter-spacing: ${num(letterSpacing, 4)}em`,
    `--z-space-1: ${space(1)}px`,
    `--z-space-2: ${space(2)}px`,
    `--z-space-3: ${space(3)}px`,
    `--z-space-4: ${space(5)}px`,
    `--z-space-5: ${space(8)}px`,
    `--z-radius: ${num(radius, 2)}px`,
    `--z-border-width: ${num(borderWidth, 2)}px`,
    `--z-rule-style: ${rule.style}`,
    `--z-rule-width: ${rule.width}px`,
    `--z-list-style: ${LIST_STYLE[listMarker] ?? "disc"}`,
    `--z-marker-content: ${MARKER_CONTENT[listMarker] ?? "normal"}`,
    `--z-link-line: ${link.line}`,
    `--z-link-style: ${link.style}`,
    `--z-link-thickness: ${link.thickness}`,
    `--z-link-highlight: ${link.highlight}`,
    `--z-heading-transform: ${headingCase.transform}`,
    `--z-heading-variant: ${headingCase.variant}`,
    `--z-dropcap-float: ${dropCap ? "left" : "none"}`,
    `--z-dropcap-size: ${dropCap ? num(baseSize * 3.2, 2) : num(baseSize, 2)}px`,
    `--z-dropcap-line: ${dropCap ? "0.85" : String(num(lineHeight))}`,
    `--z-dropcap-margin: ${dropCap ? `0 ${num(baseSize * 0.35, 2)}px 0 0` : "0"}`,
    `--z-text-align: ${justify ? "justify" : "start"}`,
    `--z-hyphens: ${justify ? "auto" : "manual"}`,
  ];

  const lightSurface = color(tokens?.light?.surface, LIGHT_FALLBACK.surface);
  const darkSurface = color(tokens?.dark?.surface, DARK_FALLBACK.surface);
  const elevationKind = String(shape?.elevation);

  const light = [
    ...paletteVars(tokens?.light, LIGHT_FALLBACK),
    `--z-elevation: ${elevation(elevationKind, lightSurface)}`,
    "color-scheme: light",
  ];
  const dark = [
    ...paletteVars(tokens?.dark, DARK_FALLBACK),
    `--z-elevation: ${elevation(elevationKind, darkSurface)}`,
    "color-scheme: dark",
  ];

  const block = (declarations: string[]) => declarations.map((d) => `  ${d};`).join("\n");

  return [
    `:host {\n${block([...shared, ...light])}\n}`,
    `@media (prefers-color-scheme: dark) {\n  :host {\n${block(dark)
      .split("\n")
      .map((line) => `  ${line}`)
      .join("\n")}\n  }\n}`,
  ].join("\n\n");
}
