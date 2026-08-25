import { NAME } from "./config.js";

/**
 * The mark.
 *
 * A seed on a horizon line, with three roots reaching down. The idea it is trying
 * to carry: this is not an index of the web, it is a small plot of it, cultivated
 * on purpose — and what makes it worth using is the part below the surface, the
 * link graph the ranking runs on.
 *
 * Drawn as inline SVG with `currentColor` throughout, so it inherits the page's
 * text colour and works in light and dark without a second asset or a media query.
 * No raster fallback, no webfont, no external request: the whole point of this
 * project is that nothing phones home, and a logo is a silly thing to break that
 * for.
 */
export function logoSVG(size = 34): string {
  return `<svg class="logo" width="${size}" height="${size}" viewBox="0 0 32 32" fill="none"
  xmlns="http://www.w3.org/2000/svg" role="img" aria-label="${NAME}">
  <!-- the horizon -->
  <path d="M3 16h26" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" opacity="0.35"/>
  <!-- the seed -->
  <circle cx="16" cy="11.5" r="4.5" fill="currentColor"/>
  <!-- roots: one deep, two lateral -->
  <path d="M16 16v10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
  <path d="M16 20c-3 1.2-4.6 3-5.2 5.6" stroke="currentColor" stroke-width="1.4"
    stroke-linecap="round" opacity="0.75"/>
  <path d="M16 22.5c2.6 1 4 2.4 4.6 4.4" stroke="currentColor" stroke-width="1.4"
    stroke-linecap="round" opacity="0.55"/>
</svg>`;
}

/** The same mark for a terminal, for `loam search`. */
export const logoASCII = String.raw`
    ___
   (   )      ${NAME}
 ---\ /---
     |
    /|\
`;
