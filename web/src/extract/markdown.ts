import { ELEMENT_NODE, TEXT_NODE } from "../dom.js";

// HTML ⇄ Markdown for section bodies.
//
// Markdown is the canonical representation on the wire (`ContentSection.markdown`)
// because it is the only form the rewrite layer can send to a model and get
// something usable back. It is *not* the rendering source of truth: anything
// Markdown cannot express — cell spans, MathML, an iframe embed — also travels as
// sanitized `html`, and the renderer prefers that.
//
// Written by hand rather than pulled in as a dependency because the inverse
// direction has to be safe: `markdownToFragment` builds DOM nodes, never a string
// of HTML, so no Markdown-to-HTML step can ever be the hole a sanitizer was
// supposed to close.

const BLOCK_TAGS = new Set([
  "p",
  "div",
  "h1",
  "h2",
  "h3",
  "h4",
  "h5",
  "h6",
  "ul",
  "ol",
  "li",
  "blockquote",
  "pre",
  "table",
  "figure",
  "figcaption",
  "dl",
  "dt",
  "dd",
  "hr",
  "section",
  "article",
  "details",
  "summary",
]);

/** Characters that would change meaning if a model round-tripped the text. */
function escapeInline(text: string): string {
  return text.replace(/([\\`*_[\]])/g, "\\$1");
}

function inlineMarkdown(node: Node): string {
  if (node.nodeType === TEXT_NODE) {
    return escapeInline((node.nodeValue ?? "").replace(/\s+/g, " "));
  }
  if (node.nodeType !== ELEMENT_NODE) return "";

  const element = node as Element;
  const tag = element.localName.toLowerCase();
  const inner = () => Array.from(element.childNodes).map(inlineMarkdown).join("");

  switch (tag) {
    case "br":
      return "  \n";
    case "strong":
    case "b":
      return `**${inner()}**`;
    case "em":
    case "i":
      return `*${inner()}*`;
    case "del":
    case "s":
      return `~~${inner()}~~`;
    case "code": {
      // Backticks inside inline code need a longer fence than anything within.
      const text = element.textContent ?? "";
      const longest = /`+/.exec(text)?.[0]?.length ?? 0;
      const fence = "`".repeat(longest + 1);
      return `${fence}${text}${fence}`;
    }
    case "a": {
      const href = element.getAttribute("href");
      const label = inner();
      return href ? `[${label}](${href})` : label;
    }
    case "img": {
      const alt = escapeInline(element.getAttribute("alt") ?? "");
      const src = element.getAttribute("src");
      return src ? `![${alt}](${src})` : "";
    }
    case "sup":
    case "sub":
      return inner();
    case "math": {
      const latex = element.getAttribute("data-latex");
      return latex ? `$${latex}$` : (element.textContent ?? "");
    }
    default:
      return inner();
  }
}

function listMarkdown(list: Element, depth: number): string {
  const ordered = list.localName.toLowerCase() === "ol";
  const start = Number.parseInt(list.getAttribute("start") ?? "1", 10) || 1;
  const items = Array.from(list.children).filter((child) => child.localName === "li");
  const indent = "  ".repeat(depth);

  return items
    .map((item, index) => {
      const marker = ordered ? `${start + index}.` : "-";
      const nested: string[] = [];
      const inline: Node[] = [];

      for (const child of Array.from(item.childNodes)) {
        const tag = (child as Element).localName?.toLowerCase();
        if (tag === "ul" || tag === "ol") {
          nested.push(listMarkdown(child as Element, depth + 1));
        } else {
          inline.push(child);
        }
      }

      const text = inline.map(inlineMarkdown).join("").trim();
      return [`${indent}${marker} ${text}`, ...nested].join("\n");
    })
    .join("\n");
}

/**
 * GFM pipe table.
 *
 * Lossy by construction: Markdown has no colspan, so a section whose table uses
 * spans carries `html` as well and the renderer uses that. This exists so the
 * rewrite layer sees *something* readable, and so a table has a plain-text form.
 */
function tableMarkdown(table: Element): string {
  const rows = Array.from(table.querySelectorAll("tr"));
  if (rows.length === 0) return "";

  const cellsOf = (row: Element) =>
    Array.from(row.children)
      .filter((cell) => cell.localName === "td" || cell.localName === "th")
      .map((cell) =>
        Array.from(cell.childNodes)
          .map(inlineMarkdown)
          .join("")
          .replace(/\|/g, "\\|")
          .replace(/\s+/g, " ")
          .trim(),
      );

  const header = cellsOf(rows[0]!);
  const body = rows.slice(1).map(cellsOf);
  const width = Math.max(header.length, ...body.map((row) => row.length), 1);
  const pad = (row: string[]) => [...row, ...Array(Math.max(0, width - row.length)).fill("")];

  const lines = [
    `| ${pad(header).join(" | ")} |`,
    `| ${Array(width).fill("---").join(" | ")} |`,
    ...body.map((row) => `| ${pad(row).join(" | ")} |`),
  ];

  const caption = table.querySelector("caption");
  return caption ? `${lines.join("\n")}\n\n*${(caption.textContent ?? "").trim()}*` : lines.join("\n");
}

/** Markdown for one block element. */
export function blockMarkdown(element: Element): string {
  const tag = element.localName.toLowerCase();

  switch (tag) {
    case "h1":
    case "h2":
    case "h3":
    case "h4":
    case "h5":
    case "h6":
      return `${"#".repeat(Number(tag[1]))} ${inlineMarkdown(element).trim()}`;

    case "ul":
    case "ol":
      return listMarkdown(element, 0);

    case "blockquote":
      return childBlocks(element)
        .map((line) => line.split("\n").map((part) => `> ${part}`.trimEnd()).join("\n"))
        .join("\n>\n");

    case "pre": {
      const code = element.querySelector("code");
      const language = code?.getAttribute("data-lang") ?? "";
      const text = (code ?? element).textContent ?? "";
      // A fence has to be longer than the longest backtick run in the body, or
      // the block ends early and the rest of the page becomes code.
      const longest = /`{3,}/.exec(text)?.[0]?.length ?? 2;
      const fence = "`".repeat(Math.max(3, longest + 1));
      return `${fence}${language}\n${text.replace(/\n$/, "")}\n${fence}`;
    }

    case "table":
      return tableMarkdown(element);

    case "figure": {
      const image = element.querySelector("img");
      const caption = element.querySelector("figcaption");
      const parts: string[] = [];
      if (image) parts.push(inlineMarkdown(image));
      if (caption) parts.push(`*${(caption.textContent ?? "").trim()}*`);
      return parts.join("\n\n") || (element.textContent ?? "").trim();
    }

    case "math": {
      const latex = element.getAttribute("data-latex");
      return latex ? `$$\n${latex}\n$$` : (element.textContent ?? "").trim();
    }

    case "hr":
      return "---";

    case "dl":
      return Array.from(element.children)
        .map((child) =>
          child.localName === "dt"
            ? `**${inlineMarkdown(child).trim()}**`
            : `: ${inlineMarkdown(child).trim()}`,
        )
        .join("\n");

    case "div":
    case "section":
    case "article":
    case "details":
      return childBlocks(element).join("\n\n");

    default:
      return inlineMarkdown(element).replace(/\s+\n/g, "\n").trim();
  }
}

function childBlocks(element: Element): string[] {
  const blocks: string[] = [];
  let inlineRun: Node[] = [];

  const flush = () => {
    if (inlineRun.length === 0) return;
    const text = inlineRun.map(inlineMarkdown).join("").trim();
    if (text) blocks.push(text);
    inlineRun = [];
  };

  for (const child of Array.from(element.childNodes)) {
    const tag = (child as Element).localName?.toLowerCase();
    if (tag && BLOCK_TAGS.has(tag)) {
      flush();
      const markdown = blockMarkdown(child as Element).trim();
      if (markdown) blocks.push(markdown);
    } else {
      inlineRun.push(child);
    }
  }
  flush();

  return blocks;
}

// MARK: - Markdown → DOM
//
// Only what a rewritten prose section can contain. Deliberately narrow: this
// path exists for M5 streaming patches, where the input is model output.

const INLINE_PATTERN =
  /(\*\*|__)(.+?)\1|(\*|_)(.+?)\3|`([^`]+)`|\[([^\]]*)\]\(([^)\s]+)\)|(\\)(.)/;

function appendInline(target: Node, markdown: string, doc: Document): void {
  let rest = markdown;

  while (rest.length > 0) {
    const match = INLINE_PATTERN.exec(rest);
    if (!match || match.index === undefined) break;

    if (match.index > 0) target.appendChild(doc.createTextNode(rest.slice(0, match.index)));

    if (match[2] !== undefined) {
      const strong = doc.createElement("strong");
      appendInline(strong, match[2], doc);
      target.appendChild(strong);
    } else if (match[4] !== undefined) {
      const em = doc.createElement("em");
      appendInline(em, match[4], doc);
      target.appendChild(em);
    } else if (match[5] !== undefined) {
      const code = doc.createElement("code");
      code.textContent = match[5];
      target.appendChild(code);
    } else if (match[7] !== undefined) {
      const href = match[7];
      // Same protocol rule as the sanitizer: a rewritten link is still a link.
      const safe = /^(https?:|mailto:|tel:|#)/i.test(href);
      // Checked by tag rather than `instanceof`: nodes created for a document
      // from another realm (every corpus test) fail a cross-realm instanceof.
      const node = doc.createElement(safe ? "a" : "span");
      if (safe) {
        node.setAttribute("href", href);
        node.setAttribute("rel", "noopener noreferrer");
      }
      appendInline(node, match[6] ?? "", doc);
      target.appendChild(node);
    } else if (match[9] !== undefined) {
      target.appendChild(doc.createTextNode(match[9]));
    }

    rest = rest.slice(match.index + match[0].length);
  }

  if (rest.length > 0) target.appendChild(doc.createTextNode(rest));
}

/** Render prose Markdown into DOM nodes. Never produces an HTML string. */
export function markdownToFragment(markdown: string, doc: Document): DocumentFragment {
  const fragment = doc.createDocumentFragment();
  const lines = markdown.split("\n");
  let index = 0;

  while (index < lines.length) {
    const line = lines[index]!;

    if (!line.trim()) {
      index += 1;
      continue;
    }

    const fence = /^```([\w+#.-]*)\s*$/.exec(line);
    if (fence) {
      const body: string[] = [];
      index += 1;
      while (index < lines.length && !/^```\s*$/.test(lines[index]!)) {
        body.push(lines[index]!);
        index += 1;
      }
      index += 1;
      const pre = doc.createElement("pre");
      const code = doc.createElement("code");
      if (fence[1]) code.setAttribute("data-lang", fence[1]);
      code.textContent = body.join("\n");
      pre.appendChild(code);
      fragment.appendChild(pre);
      continue;
    }

    const heading = /^(#{1,6})\s+(.*)$/.exec(line);
    if (heading) {
      const element = doc.createElement(`h${heading[1]!.length}`);
      appendInline(element, heading[2]!, doc);
      fragment.appendChild(element);
      index += 1;
      continue;
    }

    if (/^\s*(?:[-*+]|\d+\.)\s+/.test(line)) {
      const ordered = /^\s*\d+\./.test(line);
      const list = doc.createElement(ordered ? "ol" : "ul");
      while (index < lines.length && /^\s*(?:[-*+]|\d+\.)\s+/.test(lines[index]!)) {
        const item = doc.createElement("li");
        appendInline(item, lines[index]!.replace(/^\s*(?:[-*+]|\d+\.)\s+/, ""), doc);
        list.appendChild(item);
        index += 1;
      }
      fragment.appendChild(list);
      continue;
    }

    if (line.startsWith(">")) {
      const quote = doc.createElement("blockquote");
      const paragraph = doc.createElement("p");
      const body: string[] = [];
      while (index < lines.length && lines[index]!.startsWith(">")) {
        body.push(lines[index]!.replace(/^>\s?/, ""));
        index += 1;
      }
      appendInline(paragraph, body.join(" ").trim(), doc);
      quote.appendChild(paragraph);
      fragment.appendChild(quote);
      continue;
    }

    const paragraph = doc.createElement("p");
    const body: string[] = [];
    while (index < lines.length && lines[index]!.trim() && !/^(#{1,6}\s|```|>|\s*[-*+]\s)/.test(lines[index]!)) {
      body.push(lines[index]!);
      index += 1;
    }
    appendInline(paragraph, body.join(" "), doc);
    fragment.appendChild(paragraph);
  }

  return fragment;
}
