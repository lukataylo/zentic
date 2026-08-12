import { countWords, ELEMENT_NODE } from "../dom.js";
import type { ContentSection, SectionKind } from "../wire.js";
import { blockMarkdown } from "./markdown.js";

// Splits sanitized content into `ContentSection`s.
//
// The split is not cosmetic. `SectionKind` decides what the rewrite layer is
// allowed to touch (invariant 3: code, tables, math and embeds never reach a
// model), so mis-labelling a code block as a paragraph is a correctness bug, not
// a layout one. When a block's kind is ambiguous, the non-rewritable label wins.

const HEADINGS = new Set(["h1", "h2", "h3", "h4", "h5", "h6"]);

/**
 * Inline tags Markdown can round-trip without loss.
 *
 * A prose section containing only these needs no `html` on the wire — Markdown
 * carries everything. Anything else (`<sup>` footnote refs, `<mark>`, `<abbr>`,
 * a nested table) means Markdown is a lossy summary and the renderer needs the
 * real thing.
 */
const MARKDOWN_SAFE_INLINE = new Set([
  "a",
  "strong",
  "b",
  "em",
  "i",
  "code",
  "br",
  "del",
  "s",
  "p",
  "li",
  "ul",
  "ol",
]);

function classify(element: Element): SectionKind | null {
  const tag = element.localName.toLowerCase();

  if (HEADINGS.has(tag)) return "heading";
  if (tag === "pre") return "code";
  if (tag === "table") return "table";
  if (tag === "math") return "math";
  if (tag === "blockquote") return "quote";
  if (tag === "ul" || tag === "ol" || tag === "dl") return "list";
  if (tag === "iframe" || tag === "video" || tag === "audio") return "embed";
  if (tag === "figure") {
    // A <figure> wrapping a code block is a code block. Defuddle emits this
    // shape for captioned listings, and getting it wrong would send source code
    // to a model.
    if (element.querySelector("pre")) return "code";
    if (element.querySelector("iframe, video, audio")) return "embed";
    if (element.querySelector("table")) return "table";
    if (element.querySelector("math")) return "math";
    return "figure";
  }
  if (tag === "img") return "figure";
  if (tag === "p" || tag === "details" || tag === "dd" || tag === "dt") return "paragraph";
  if (tag === "hr") return null;

  return "paragraph";
}

function isFootnoteContainer(element: Element): boolean {
  const id = element.getAttribute("id") ?? "";
  return (
    id === "footnotes" ||
    element.classList.contains("footnotes") ||
    element.getAttribute("role") === "doc-footnotes" ||
    (element.localName === "ol" && element.classList.contains("footnotes-list"))
  );
}

/** True when Markdown alone would lose information from this block. */
function needsHTML(element: Element, kind: SectionKind): boolean {
  if (kind !== "heading" && kind !== "paragraph" && kind !== "list" && kind !== "quote") {
    return true;
  }
  for (const descendant of Array.from(element.querySelectorAll("*"))) {
    if (!MARKDOWN_SAFE_INLINE.has(descendant.localName.toLowerCase())) return true;
  }
  return false;
}

export interface SectionsResult {
  sections: ContentSection[];
  /** Words of prose. Excludes code, tables and math, which are not read at speed. */
  wordCount: number;
}

const TABLE_TAGS = new Set(["table", "tbody", "thead", "tfoot", "tr", "td", "th"]);

/**
 * Flatten tables used for page layout.
 *
 * A single-cell table is not tabular data, it is 1998's `<div>`. Paul Graham's
 * essays, plenty of mailing-list archives and most WYSIWYG output put the whole
 * article in one cell, and leaving it as a table renders an eleven-thousand-word
 * essay as one table cell — and, worse, classifies it as `table`, which makes it
 * non-rewritable.
 *
 * A grid with more than two cells is left alone: that is real data, spans and all.
 */
function unwrapLayoutTables(root: ParentNode, doc: Document): void {
  for (let pass = 0; pass < 4; pass += 1) {
    const tables = Array.from(root.querySelectorAll("table"));
    let changed = false;

    for (const table of tables) {
      const cells = Array.from(table.querySelectorAll("td, th"));
      if (cells.length > 2) continue;

      const replacement = doc.createDocumentFragment();
      for (const cell of cells) {
        while (cell.firstChild) replacement.appendChild(cell.firstChild);
      }
      table.replaceWith(replacement);
      changed = true;
    }

    if (!changed) break;
  }

  // A `<td>` that arrived as the extraction root has no table around it at all.
  for (const orphan of Array.from(root.querySelectorAll("td, th, tr, tbody, thead, tfoot"))) {
    if (orphan.closest("table")) continue;
    const replacement = doc.createDocumentFragment();
    while (orphan.firstChild) replacement.appendChild(orphan.firstChild);
    orphan.replaceWith(replacement);
  }
}

/**
 * Turn `<br><br>` into paragraph breaks.
 *
 * Older HTML — and every WYSIWYG editor ever shipped — separates paragraphs with
 * consecutive line breaks rather than `<p>`. Without this the text is technically
 * all present and practically unreadable: one wall with no visual rhythm, no
 * drop cap target, and one enormous "paragraph" for the rewrite layer to chew on.
 */
function splitDoubleBreaks(root: ParentNode, doc: Document): void {
  const containers = new Set<Element>();
  for (const br of Array.from(root.querySelectorAll("br"))) {
    const parent = br.parentElement;
    if (parent && !TABLE_TAGS.has(parent.localName)) containers.add(parent);
  }

  for (const container of containers) {
    const groups: Node[][] = [[]];
    let breaks = 0;
    let split = false;

    for (const child of Array.from(container.childNodes)) {
      if ((child as Element).localName === "br") {
        breaks += 1;
        if (breaks >= 2) {
          if (groups[groups.length - 1]!.length > 0) {
            groups.push([]);
            split = true;
          }
          continue;
        }
      } else if ((child.textContent ?? "").trim()) {
        breaks = 0;
      }
      groups[groups.length - 1]!.push(child);
    }

    if (!split) continue;

    const replacement = doc.createDocumentFragment();
    for (const group of groups) {
      const paragraph = doc.createElement("p");
      for (const node of group) paragraph.appendChild(node);
      if ((paragraph.textContent ?? "").trim()) replacement.appendChild(paragraph);
    }

    // The container may itself be a <p>, which cannot nest: replace it.
    if (container.localName === "p" || container.localName === "font") {
      container.replaceWith(replacement);
    } else {
      container.textContent = "";
      container.appendChild(replacement);
    }
  }
}

/**
 * Build sections from a sanitized fragment.
 *
 * Two normalisations run first, both aimed at the same failure: HTML that encodes
 * paragraphs without using paragraph elements. Loose text between blocks is then
 * collected into a paragraph rather than dropped — on hand-written HTML from the
 * 1990s that loose text *is* the article.
 */
export function buildSections(fragment: DocumentFragment, doc: Document): SectionsResult {
  unwrapLayoutTables(fragment, doc);
  splitDoubleBreaks(fragment, doc);

  const sections: ContentSection[] = [];
  let wordCount = 0;
  let index = 0;

  const push = (kind: SectionKind, element: Element, markdown: string) => {
    const trimmed = markdown.trim();
    if (!trimmed && kind !== "embed" && kind !== "figure") return;

    const section: ContentSection = {
      id: `s${index}`,
      kind,
      markdown: trimmed,
    };
    if (needsHTML(element, kind)) section.html = element.outerHTML;
    if (kind === "heading") section.level = Number(element.localName[1]) || 1;

    sections.push(section);
    index += 1;

    if (kind !== "code" && kind !== "table" && kind !== "math" && kind !== "embed") {
      wordCount += countWords(element.textContent ?? "");
    }
  };

  let inlineRun: Node[] = [];

  /**
   * Turn a run of loose inline content into paragraphs.
   *
   * Split on consecutive `<br>`s, because a page written in 1997 — or by any
   * WYSIWYG editor since — separates paragraphs with `<br><br>` and no `<p>`
   * anywhere. Without this, Paul Graham's essays extract as a single
   * eleven-thousand-word block: technically complete, unreadable in practice.
   */
  const flushInline = () => {
    if (inlineRun.length === 0) return;
    const run = inlineRun;
    inlineRun = [];

    const groups: Node[][] = [[]];
    let breaks = 0;
    for (const node of run) {
      const isBreak = (node as Element).localName === "br";
      if (isBreak) {
        breaks += 1;
        if (breaks >= 2) {
          if (groups[groups.length - 1]!.length > 0) groups.push([]);
          continue;
        }
      } else {
        breaks = 0;
      }
      groups[groups.length - 1]!.push(node);
    }

    for (const group of groups) {
      if (group.length === 0) continue;
      const paragraph = doc.createElement("p");
      for (const node of group) paragraph.appendChild(node.cloneNode(true));
      if ((paragraph.textContent ?? "").trim()) {
        push("paragraph", paragraph, blockMarkdown(paragraph));
      }
    }
  };

  for (const node of Array.from(fragment.childNodes)) {
    if (node.nodeType !== ELEMENT_NODE) {
      if ((node.textContent ?? "").trim()) inlineRun.push(node);
      continue;
    }

    const element = node as Element;
    const tag = element.localName.toLowerCase();

    // Inline-level elements at the top level belong to the running paragraph.
    if (["a", "strong", "b", "em", "i", "code", "span", "sup", "sub", "small", "mark", "br", "time", "cite", "abbr"].includes(tag)) {
      inlineRun.push(element);
      continue;
    }

    flushInline();

    if (isFootnoteContainer(element)) {
      push("footnotes", element, blockMarkdown(element));
      continue;
    }

    const kind = classify(element);
    if (!kind) continue;
    push(kind, element, blockMarkdown(element));
  }

  flushInline();

  return { sections, wordCount };
}
