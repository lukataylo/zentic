import katex from "katex";

import { sanitizeHTML } from "./sanitize.js";

// Math rendering.
//
// ## Why MathML output rather than KaTeX's HTML
//
// KaTeX's default output is a tower of positioned `<span>`s that only lines up
// when `katex.css` and the KaTeX webfonts are present. Those fonts are `url()`
// fetches, and a page read must not make a network request the page did not
// already make (invariant 5's reasoning applies to the renderer, not just to
// themes). Embedding ~1MB of woff2 as data URIs in a script injected into every
// page is not a trade worth making either.
//
// So KaTeX is used as the TeX *parser* and asked for MathML, which WebKit renders
// natively with the system math font. Positioning quality is a little below
// KaTeX-with-its-fonts and this is the part of the renderer jsdom cannot check at
// all — it needs eyes on a device. What it buys is math that needs no stylesheet,
// no download, and no fallback path.
//
// Pages that already ship MathML keep theirs untouched, for the same reason.

/**
 * Render every `<math data-latex>` in a subtree.
 *
 * Defuddle normalises MathJax, KaTeX and raw TeX into `<math display data-latex>`,
 * so this is the single place math is handled regardless of what the page used.
 * An element without `data-latex` already holds MathML and is left alone.
 */
export function renderMath(root: ParentNode, doc: Document): void {
  const nodes = Array.from(root.querySelectorAll("math"));

  for (const node of nodes) {
    const latex = node.getAttribute("data-latex");
    if (!latex) continue;

    const displayMode = node.getAttribute("display") === "block";

    let html: string;
    try {
      html = katex.renderToString(latex, {
        displayMode,
        output: "mathml",
        // A broken formula renders as the source in an error colour. Throwing
        // would abort the whole render for one bad `\newcommand`.
        throwOnError: false,
        strict: false,
        trust: false,
      });
    } catch {
      const fallback = doc.createElement("code");
      fallback.className = "math-error";
      fallback.textContent = latex;
      node.replaceWith(fallback);
      continue;
    }

    // KaTeX's output is ours, not the page's — but it is built from page-supplied
    // TeX, so it goes through the same sanitizer as everything else. `trust:
    // false` above already refuses `\href` and `\includegraphics`; this is the
    // second lock.
    const fragment = sanitizeHTML(html, doc);
    const wrapper = doc.createElement("span");
    wrapper.className = displayMode ? "math-block" : "math-inline";
    wrapper.appendChild(fragment);
    node.replaceWith(wrapper);
  }
}
