import { describe, expect, it } from "vitest";

import { compileTheme, pageBackground } from "../src/render/theme.js";
import type { ReaderTheme, ThemeTokens } from "../src/wire.js";

// The reader's page ground is a *material*, not a colour: every theme keeps its
// own background hex and the reader supplies the opacity, so making the browser
// translucent did not mean repainting six built-in themes.
//
// The rest of this file is the usual paranoia about what reaches CSS. `theme.ts`
// guarantees that every value it emits is either a number it clamped, a lookup in
// a fixed table, or a hex string it re-parsed — which is what stops `url(` from
// ever appearing in a stylesheet compiled from model output.

/** Read one custom property out of a compiled stylesheet. */
function token(css: string, name: string, block: "light" | "dark" = "light"): string {
  const source = block === "light" ? css.split("@media")[0]! : css.split("@media")[1] ?? "";
  const match = new RegExp(`${name}:\\s*([^;]+);`).exec(source);
  return match?.[1]?.trim() ?? "";
}

function alphaOf(hex: string): number {
  return hex.length === 9 ? Number.parseInt(hex.slice(7, 9), 16) / 255 : 1;
}

function themeWith(light: Partial<ThemeTokens["light"]>): ReaderTheme {
  return {
    id: "test",
    name: "Test",
    source: "generated",
    createdAt: new Date().toISOString(),
    tokens: { light } as unknown as ThemeTokens,
  } as unknown as ReaderTheme;
}

describe("the page ground", () => {
  it("is translucent by default, in both appearances", () => {
    expect(alphaOf(pageBackground(undefined, false))).toBeLessThan(1);
    expect(alphaOf(pageBackground(undefined, true))).toBeLessThan(1);

    expect(alphaOf(token(compileTheme(undefined), "--z-bg"))).toBeLessThan(1);
    expect(alphaOf(token(compileTheme(undefined), "--z-bg", "dark"))).toBeLessThan(1);
  });

  it("keeps body text well clear of WCAG AAA over the worst backdrop", () => {
    // Nothing else underneath: no window material, no space tint — just the
    // reader over whatever is behind the window. Light mode's ground can only be
    // darkened by a backdrop, dark mode's can only be lightened, so each is
    // measured against the extreme that hurts it.
    expect(contrastOverBackdrop(pageBackground(undefined, false), "#1a1a1a", 0)).toBeGreaterThan(7);
    expect(contrastOverBackdrop(pageBackground(undefined, true), "#f2f2f2", 255)).toBeGreaterThan(7);
  });

  it("takes the theme's colour and supplies only the opacity", () => {
    // A generated theme says what colour the page is. It does not, today, have a
    // way to say how solid — Swift's `Palette` is `#rrggbb` and `validated()`
    // normalises to that — so the reader fills that in.
    const css = compileTheme(themeWith({ background: "#fbfaf7" }));

    expect(token(css, "--z-bg").slice(0, 7)).toBe("#fbfaf7");
    expect(alphaOf(token(css, "--z-bg"))).toBeLessThan(1);
  });

  it("lets a theme that states its own opacity win", () => {
    // Eight digits is how a theme opts out. `#rrggbbaa` survives this compiler
    // untouched, which is the escape hatch for a design that needs a solid page.
    const css = compileTheme(themeWith({ background: "#112233ff" }));

    expect(token(css, "--z-bg")).toBe("#112233");
    expect(alphaOf(token(css, "--z-bg"))).toBe(1);

    const translucent = compileTheme(themeWith({ background: "#11223380" }));
    expect(token(translucent, "--z-bg")).toBe("#11223380");
  });

  it("makes the plates inside the page glass too, but only over glass", () => {
    // An opaque blockquote on a translucent page reads as a patch where the glass
    // ran out. On an opaque page there is no glass to be denser than, so the
    // theme's surface colour is used flat, exactly as it always was.
    expect(token(compileTheme(undefined), "--z-surface-mix")).toBe("55%");
    expect(token(compileTheme(themeWith({ background: "#ffffffff" })), "--z-surface-mix")).toBe(
      "100%",
    );
  });

  it("still refuses anything that is not a hex colour", () => {
    // The alpha forms widened what `color()` accepts. They must not have widened
    // it to anything that can carry a network request.
    const css = compileTheme(
      themeWith({
        background: "#fff; background-image: url(https://tracker.example/p.gif)",
        surface: "url(https://tracker.example/p.gif)",
        text: "#12345",
        accent: "javascript:alert(1)",
      } as Partial<ThemeTokens["light"]>),
    );

    expect(css).not.toContain("url(");
    expect(css).not.toContain("javascript:");
    expect(css).not.toContain("tracker.example");
    // Each hostile value fell back rather than being partially accepted.
    expect(token(css, "--z-bg").slice(0, 7)).toBe("#ffffff");
    expect(token(css, "--z-text")).toBe("#1a1a1a");
  });

  it("keeps the bevel faces sane when a surface carries alpha", () => {
    // The bevel derives its highlight and shadow from the surface colour by
    // arithmetic. An alpha suffix is not part of that arithmetic, and reading it
    // as one produced `#NaNNaNNaN`.
    const css = compileTheme({
      id: "t",
      name: "T",
      source: "generated",
      createdAt: new Date().toISOString(),
      tokens: {
        light: { surface: "#80808080" },
        shape: { elevation: "bevel" },
      },
    } as unknown as ReaderTheme);

    expect(token(css, "--z-elevation")).not.toContain("NaN");
    expect(token(css, "--z-elevation")).toContain("inset");
  });
});

// MARK: - Helpers

/** WCAG 2.1 contrast of `text` over `ground` composited on a grey backdrop. */
function contrastOverBackdrop(ground: string, text: string, backdrop: number): number {
  const alpha = alphaOf(ground);
  const rgb = (hex: string): [number, number, number] => {
    const raw = Number.parseInt(hex.slice(1, 7), 16);
    return [(raw >> 16) & 0xff, (raw >> 8) & 0xff, raw & 0xff];
  };
  const composited = rgb(ground).map((c) => c * alpha + backdrop * (1 - alpha)) as [
    number,
    number,
    number,
  ];
  const luminance = ([r, g, b]: [number, number, number]) => {
    const channel = (value: number) => {
      const v = value / 255;
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
  };
  const a = luminance(composited);
  const b = luminance(rgb(text));
  return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
}
