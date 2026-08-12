import { ELEMENT_NODE } from "../dom.js";
import type { ContentSection, ExtractionResult, ReaderTheme } from "../wire.js";
import { markdownToFragment } from "../extract/markdown.js";
import { BASE_CSS } from "./css.js";
import { renderMath } from "./math.js";
import { sanitizeHTML } from "./sanitize.js";
import { compileTheme, pageBackground } from "./theme.js";

// The reader's view: a closed shadow root over the original document.
//
// ## Why a shadow root, in place
//
// Same document, so links, history, cookies and the browser's own find-in-page
// all behave normally — no custom URL scheme, no about:blank. Closed, so the
// site's CSS cannot leak in and ours cannot leak out; there is no specificity
// fight and no `!important` arms race. And site script mutating the (hidden)
// original is harmless, because its `MutationObserver`s cannot see inside.
//
// ## Why a fixed overlay
//
// The original document is hidden but **never destroyed** — ⌘\ has to be instant
// and must not reload. That means its layout is still there, contributing its full
// scroll height, so rendering in normal flow would leave the reader scrolling
// past a hidden page. A fixed, full-viewport overlay with its own scroller sizes
// itself to *our* content instead.
//
// The cost, and it is a real one: the browser's scroll-restoration and
// scroll-anchoring work on the document scroller, not ours, so returning to a
// page through history lands at the top. Fixing that properly means storing our
// scroll offset per history entry, which is M4 work.
//
// Because the overlay is opaque and covers the viewport, revealing the original
// document underneath it is safe. That is deliberate: it means a bug in this file
// shows the user the real page rather than a blank window.

const HOST_ID = "zentic-reader-root";

/** Beats every plausible site z-index without relying on stacking luck. */
const HOST_STYLE = [
  "position: fixed",
  "inset: 0",
  "z-index: 2147483647",
  "margin: 0",
  "padding: 0",
  "border: 0",
  "display: block",
  "overflow-x: hidden",
  "overflow-y: auto",
  "overscroll-behavior: contain",
  "-webkit-overflow-scrolling: touch",
  "isolation: isolate",
];

export class ReaderView {
  private host: HTMLElement | undefined;
  private root: ShadowRoot | undefined;
  private themeSheet: HTMLStyleElement | undefined;
  private viewport: HTMLElement | undefined;
  private theme: ReaderTheme | undefined;
  private appearance: MediaQueryList | undefined;
  private sectionNodes = new Map<string, Element>();

  constructor(private readonly doc: Document) {}

  get isRendered(): boolean {
    return this.root !== undefined && this.host?.isConnected === true;
  }

  /**
   * Create the host and shadow root.
   *
   * `visibility: visible !important` is not optional: the anti-flash hide sets
   * `visibility: hidden` on `<html>`, and visibility inherits, so without this
   * the reader would render into a subtree that cannot paint.
   */
  mount(theme: ReaderTheme | undefined): ShadowRoot {
    if (this.root && this.host?.isConnected) {
      if (theme) this.applyTheme(theme);
      return this.root;
    }

    this.theme = theme;
    const host = this.doc.createElement("div");
    host.id = HOST_ID;
    host.setAttribute("role", "document");
    this.applyHostStyle(host);

    // Prefer <body>: a div appended to <html> renders, but sites that rewrite
    // documentElement.innerHTML are rarer than ones that touch body, and being
    // inside body keeps us in the normal containing block.
    (this.doc.body ?? this.doc.documentElement).appendChild(host);

    // Closed, so page script holding a reference to the host still cannot reach
    // the content — `host.shadowRoot` is null from the outside.
    const root = host.attachShadow({ mode: "closed" });

    const base = this.doc.createElement("style");
    base.textContent = BASE_CSS;
    const themeSheet = this.doc.createElement("style");
    themeSheet.textContent = compileTheme(theme);

    // Theme last, so a token override always wins over the structural sheet.
    root.append(themeSheet, base);

    this.host = host;
    this.root = root;
    this.themeSheet = themeSheet;
    this.watchAppearance();

    return root;
  }

  /** Render an extraction result. Replaces any previous content. */
  render(result: ExtractionResult, theme: ReaderTheme | undefined): void {
    const root = this.mount(theme ?? this.theme);
    this.sectionNodes.clear();

    this.viewport?.remove();
    const viewport = this.doc.createElement("div");
    viewport.className = "viewport";

    const layout = this.doc.createElement("div");
    layout.className = "layout";
    layout.setAttribute("data-archetype", result.archetype);
    if (result.lang) {
      layout.setAttribute("lang", result.lang);
      // RTL is driven by the content's own language, not by the reader's UI
      // locale — an Arabic article in an English browser is still RTL.
      if (isRTL(result.lang)) layout.setAttribute("dir", "rtl");
    }

    const article = this.doc.createElement("article");
    article.appendChild(this.masthead(result));

    const body = this.doc.createElement("div");
    body.className = "body";
    for (const section of result.sections) {
      const node = this.renderSection(section, result);
      if (node) {
        body.appendChild(node);
        this.sectionNodes.set(section.id, node);
      }
    }
    this.markLeadParagraph(body);
    article.appendChild(body);

    layout.appendChild(article);
    if (result.archetype === "docs") {
      const toc = this.tableOfContents(result);
      if (toc) layout.appendChild(toc);
    }

    viewport.appendChild(layout);
    root.appendChild(viewport);
    this.viewport = viewport;

    renderMath(viewport, this.doc);
    this.applyIntrinsicImageSizes(viewport);
    this.wireInPageLinks(viewport);
    this.show();
  }

  /**
   * Render a model-authored layout of the page instead of our own.
   *
   * Goes in the same shadow root, over the same hidden original document, so ⌘\
   * still restores the site's own page and nothing here can reach the rest of
   * the DOM. `innerHTML` does not execute `<script>`, and the Swift side has
   * already stripped anything that could reach the network.
   *
   * Placeholders are the interesting part: code, tables, math and embeds were
   * never sent to the model, so it emits `<zentic-section>` where they belong
   * and we fill them in from the extraction. A model cannot mangle a code block
   * it has not seen.
   */
  renderDocument(
    html: string,
    result: ExtractionResult,
    theme: ReaderTheme | undefined,
  ): void {
    const root = this.mount(theme ?? this.theme);
    this.sectionNodes.clear();
    this.viewport?.remove();

    const viewport = this.doc.createElement("div");
    viewport.className = "viewport generated";
    if (result.lang) {
      viewport.setAttribute("lang", result.lang);
      if (isRTL(result.lang)) viewport.setAttribute("dir", "rtl");
    }
    viewport.innerHTML = html;

    const sections = new Map(result.sections.map((section) => [section.id, section]));
    for (const slot of Array.from(viewport.querySelectorAll("zentic-section"))) {
      const section = sections.get(slot.getAttribute("section") ?? "");
      const node = section ? this.renderSection(section, result) : undefined;
      if (node) {
        slot.replaceWith(node);
        this.sectionNodes.set(section!.id, node);
      } else {
        slot.remove();
      }
    }

    root.appendChild(viewport);
    this.viewport = viewport;

    renderMath(viewport, this.doc);
    this.applyIntrinsicImageSizes(viewport);
    this.wireInPageLinks(viewport);
    this.show();
  }

  /** Restyle without re-extracting: replace one stylesheet, keep the DOM. */
  applyTheme(theme: ReaderTheme): void {
    this.theme = theme;
    if (this.themeSheet) this.themeSheet.textContent = compileTheme(theme);
    if (this.host) this.applyHostStyle(this.host);
  }

  show(): void {
    if (this.host) this.host.style.setProperty("display", "block", "important");
  }

  hide(): void {
    if (this.host) this.host.style.setProperty("display", "none", "important");
  }

  /** Drop rendered content but keep the host, for an SPA navigation. */
  clear(): void {
    this.viewport?.remove();
    this.viewport = undefined;
    this.sectionNodes.clear();
  }

  /**
   * Replace one section's prose with a rewrite (M5 streams these).
   *
   * Only prose ever arrives here: `SectionKind.isRewritable` keeps code, tables,
   * math and embeds away from the model in the first place.
   */
  applyRewrite(sectionID: string, markdown: string): boolean {
    const node = this.sectionNodes.get(sectionID);
    if (!node) return false;

    const replacement = markdownToFragment(markdown, this.doc);
    const wrapper = this.doc.createElement("div");
    wrapper.className = "rewritten";
    wrapper.appendChild(replacement);
    node.replaceWith(wrapper);
    this.sectionNodes.set(sectionID, wrapper);
    return true;
  }

  destroy(): void {
    this.host?.remove();
    this.host = undefined;
    this.root = undefined;
    this.themeSheet = undefined;
    this.viewport = undefined;
    this.sectionNodes.clear();
  }

  // MARK: - Internals

  private applyHostStyle(host: HTMLElement): void {
    const dark = this.appearance?.matches ?? prefersDark(this.doc);
    for (const declaration of HOST_STYLE) {
      const [property, value] = declaration.split(":").map((part) => part.trim());
      if (property && value) host.style.setProperty(property, value);
    }
    // These two must beat anything the site can say about our element.
    host.style.setProperty("visibility", "visible", "important");
    host.style.setProperty("display", "block", "important");
    // Opaque before the shadow stylesheet applies, so the original document
    // never shows through for a frame.
    host.style.setProperty("background", pageBackground(this.theme?.tokens, dark));
  }

  private watchAppearance(): void {
    const view = this.doc.defaultView;
    if (!view?.matchMedia || this.appearance) return;

    this.appearance = view.matchMedia("(prefers-color-scheme: dark)");
    this.appearance.addEventListener?.("change", () => {
      if (this.host) this.applyHostStyle(this.host);
    });
  }

  private masthead(result: ExtractionResult): Element {
    const header = this.doc.createElement("header");
    header.className = "masthead";

    const title = this.doc.createElement("h1");
    title.textContent = result.title;
    header.appendChild(title);

    const facts: string[] = [];
    if (result.byline) facts.push(result.byline);
    if (result.siteName) facts.push(result.siteName);
    if (result.publishedAt) {
      const date = new Date(result.publishedAt);
      if (!Number.isNaN(date.getTime())) {
        facts.push(date.toLocaleDateString(result.lang || undefined, { dateStyle: "long" }));
      }
    }
    if (result.wordCount > 0) {
      facts.push(`${Math.max(1, Math.round(result.wordCount / 225))} min read`);
    }

    if (facts.length > 0) {
      const byline = this.doc.createElement("p");
      byline.className = "byline";
      for (const fact of facts) {
        const span = this.doc.createElement("span");
        span.textContent = fact;
        byline.appendChild(span);
      }
      header.appendChild(byline);
    }

    return header;
  }

  /**
   * Build one section's DOM.
   *
   * `html` is preferred over `markdown` and is re-sanitized on the way in. The
   * second pass is not redundant: an `ExtractionResult` can arrive from Swift
   * (replayed, or carrying a rewrite) and the renderer must not have a trusted
   * input path at all.
   */
  private renderSection(section: ContentSection, result: ExtractionResult): Element | null {
    const content = section.html
      ? sanitizeHTML(section.html, this.doc, { baseUrl: result.url, allowEmbeds: true })
      : markdownToFragment(section.markdown, this.doc);

    switch (section.kind) {
      case "code":
        return this.wrapCode(content);
      case "table":
        return wrap(this.doc, content, "div", "table-scroll");
      case "embed":
        return this.wrapEmbed(content);
      case "footnotes": {
        const footnotes = wrap(this.doc, content, "section", "footnotes");
        footnotes.setAttribute("role", "doc-endnotes");
        return footnotes;
      }
      case "heading": {
        const heading = firstElement(content) ?? this.doc.createElement("h2");
        if (!heading.id) heading.id = `${section.id}-h`;
        return heading;
      }
      default: {
        const only = firstElement(content);
        // A single block element needs no wrapper: fewer nodes, and the
        // stylesheet's `.body > p` rules apply directly.
        if (only && content.childNodes.length === 1) return only;
        return wrap(this.doc, content, "div", `section-${section.kind}`);
      }
    }
  }

  private wrapCode(content: DocumentFragment): Element {
    const figure = this.doc.createElement("figure");
    figure.className = "code";

    const existing = content.querySelector("pre");
    const pre = existing ?? this.doc.createElement("pre");
    if (!existing) {
      const code = this.doc.createElement("code");
      code.appendChild(content);
      pre.appendChild(code);
    }

    const language = pre.querySelector("code")?.getAttribute("data-lang");
    if (language) {
      const caption = this.doc.createElement("figcaption");
      caption.textContent = language;
      figure.appendChild(caption);
    }
    figure.appendChild(pre);
    return figure;
  }

  private wrapEmbed(content: DocumentFragment): Element {
    const container = this.doc.createElement("div");
    container.className = "embed";

    const frame = content.querySelector("iframe");
    const width = Number.parseInt(frame?.getAttribute("width") ?? "", 10);
    const height = Number.parseInt(frame?.getAttribute("height") ?? "", 10);
    // Reserve the real aspect ratio when the embed declares one, so the frame
    // loading does not push the rest of the article down.
    if (width > 0 && height > 0) {
      container.style.setProperty("--z-embed-ratio", `${width} / ${height}`);
    }

    container.appendChild(content);
    return container;
  }

  /** Mark the first paragraph so the drop-cap ornament has something to target. */
  private markLeadParagraph(body: Element): void {
    for (const child of Array.from(body.children)) {
      if (child.localName === "p" && (child.textContent ?? "").trim().length > 80) {
        child.setAttribute("data-lead", "");
        return;
      }
      if (child.localName !== "p" && child.localName !== "header") return;
    }
  }

  private tableOfContents(result: ExtractionResult): Element | null {
    const headings = result.sections.filter(
      (section) => section.kind === "heading" && (section.level ?? 1) >= 2 && (section.level ?? 1) <= 4,
    );
    if (headings.length < 3) return null;

    const aside = this.doc.createElement("aside");
    aside.className = "toc";
    aside.setAttribute("aria-label", "On this page");
    const list = this.doc.createElement("ol");

    for (const heading of headings) {
      const node = this.sectionNodes.get(heading.id);
      if (!node?.id) continue;

      const item = this.doc.createElement("li");
      item.setAttribute("data-level", String(heading.level ?? 2));
      const link = this.doc.createElement("a");
      link.setAttribute("href", `#${node.id}`);
      link.textContent = (node.textContent ?? "").trim();
      item.appendChild(link);
      list.appendChild(item);
    }

    if (list.children.length === 0) return null;
    aside.appendChild(list);
    return aside;
  }

  /**
   * Give every image intrinsic dimensions.
   *
   * Without them the article reflows as each image arrives, which on a long page
   * means the paragraph the reader is on keeps moving. Attributes come first;
   * failing that we ask the *original* document, where the image may already be
   * decoded and its natural size known — a measurement the reader gets for free
   * precisely because the original DOM was kept.
   */
  private applyIntrinsicImageSizes(root: ParentNode): void {
    const natural = new Map<string, { width: number; height: number }>();
    for (const image of Array.from(this.doc.images ?? [])) {
      if (image.naturalWidth > 0 && image.naturalHeight > 0) {
        natural.set(image.currentSrc || image.src, {
          width: image.naturalWidth,
          height: image.naturalHeight,
        });
      }
    }

    for (const image of Array.from(root.querySelectorAll("img"))) {
      let width = Number.parseInt(image.getAttribute("width") ?? "", 10);
      let height = Number.parseInt(image.getAttribute("height") ?? "", 10);

      if (!(width > 0 && height > 0)) {
        const measured = natural.get(image.getAttribute("src") ?? "");
        if (measured) {
          width = measured.width;
          height = measured.height;
          image.setAttribute("width", String(width));
          image.setAttribute("height", String(height));
        }
      }

      if (width > 0 && height > 0) {
        image.style.setProperty("aspect-ratio", `${width} / ${height}`);
        image.style.setProperty("height", "auto");
      }
    }
  }

  /**
   * Make in-page links work.
   *
   * A fragment cannot cross a shadow boundary: the browser looks for
   * `#footnote-3` in the document, finds nothing, and either does nothing or
   * jumps to the top. Footnote references and their back-references are the whole
   * point of getting footnotes right, so they are resolved by hand.
   */
  private wireInPageLinks(root: ParentNode): void {
    const shadow = this.root;
    if (!shadow) return;

    for (const anchor of Array.from(root.querySelectorAll('a[href^="#"]'))) {
      anchor.addEventListener("click", (event) => {
        const id = anchor.getAttribute("href")?.slice(1);
        if (!id) return;

        let target: Element | null = null;
        try {
          target = shadow.getElementById?.(id) ?? shadow.querySelector(`#${CSS.escape(id)}`);
        } catch {
          target = null;
        }
        if (!target) return;

        event.preventDefault();
        target.scrollIntoView({ block: "start", behavior: "smooth" });
        // `:target` never matches inside a shadow root, so the highlight that
        // tells the reader which footnote they landed on is applied by hand.
        for (const previous of Array.from(shadow.querySelectorAll("[data-zentic-target]"))) {
          previous.removeAttribute("data-zentic-target");
        }
        target.setAttribute("data-zentic-target", "");
      });
    }
  }
}

// MARK: - Helpers

function wrap(doc: Document, content: DocumentFragment, tag: string, className: string): Element {
  const element = doc.createElement(tag);
  element.className = className;
  element.appendChild(content);
  return element;
}

function firstElement(fragment: DocumentFragment): Element | null {
  for (const node of Array.from(fragment.childNodes)) {
    if (node.nodeType === ELEMENT_NODE) return node as Element;
  }
  return null;
}

function prefersDark(doc: Document): boolean {
  try {
    return doc.defaultView?.matchMedia?.("(prefers-color-scheme: dark)").matches ?? false;
  } catch {
    return false;
  }
}

/** Scripts written right-to-left, by BCP-47 primary subtag. */
const RTL_LANGUAGES = new Set([
  "ar",
  "he",
  "fa",
  "ur",
  "ps",
  "sd",
  "ug",
  "yi",
  "dv",
  "ku",
  "ckb",
  "arc",
  "nqo",
]);

export function isRTL(lang: string): boolean {
  const primary = lang.toLowerCase().split(/[-_]/)[0] ?? "";
  return RTL_LANGUAGES.has(primary);
}
