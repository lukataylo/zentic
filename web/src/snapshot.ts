// A compact structural outline of the page for a model that writes CSS.
//
// The goal is selectors that actually match: real tag names, ids, the stable
// part of the class list, roles and test ids, plus enough geometry and a hint
// of text that the model can tell the sidebar from the article. Repetition is
// the enemy of the budget, so runs of look-alike siblings collapse to one.

export const SNAPSHOT_BUDGET = 14_000;

const SKIP = new Set([
  "script", "style", "noscript", "template", "link", "meta", "br", "wbr", "head", "source", "track", "path", "use",
]);
const LEAF = new Set(["svg", "img", "video", "audio", "iframe", "canvas", "input", "select", "textarea", "picture", "math"]);
const SEMANTIC = new Set([
  "header", "nav", "main", "article", "aside", "footer", "section", "form", "h1", "h2", "h3", "h4", "h5", "h6",
  "ul", "ol", "table", "figure", "button", "a", "dialog", "details",
]);

interface Pass {
  maxDepth: number;
  minArea: number;
  textChars: number;
}

const PASSES: Pass[] = [
  { maxDepth: 18, minArea: 0, textChars: 50 },
  { maxDepth: 14, minArea: 400, textChars: 40 },
  { maxDepth: 11, minArea: 2_000, textChars: 32 },
  { maxDepth: 9, minArea: 8_000, textChars: 24 },
  { maxDepth: 7, minArea: 20_000, textChars: 20 },
  { maxDepth: 5, minArea: 40_000, textChars: 16 },
];

export function snapshot(): string {
  const view = document.defaultView;
  const header = [
    `URL: ${location.href}`,
    `Title: ${document.title.trim().slice(0, 140)}`,
    `Viewport: ${view?.innerWidth ?? 0}×${view?.innerHeight ?? 0}`,
    "Outline (tag#id.class[attr] {w×h, position} \"text\"; (×N similar) = repeated siblings):",
  ].join("\n");

  const budget = SNAPSHOT_BUDGET - header.length - 1;
  const geometry = hasGeometry();
  let out = "";
  for (const pass of PASSES) {
    const lines: string[] = [];
    if (document.body) walk(document.body, 0, pass, geometry, lines, budget * 2);
    out = lines.join("\n");
    if (out.length <= budget) break;
  }
  if (out.length > budget) out = out.slice(0, budget - 12).replace(/\n[^\n]*$/, "") + "\n…truncated";
  return `${header}\n${out}`;
}

function hasGeometry(): boolean {
  return !/jsdom/i.test(navigator.userAgent);
}

function walk(el: Element, depth: number, pass: Pass, geometry: boolean, lines: string[], hardCap: number): void {
  if (lines.length > 4000 || totalLength(lines) > hardCap) return;
  const children = Array.from(el.children).filter((c) => !SKIP.has(c.localName) && !c.hasAttribute("data-zentic"));
  let i = 0;
  while (i < children.length) {
    const child = children[i]!;
    // Collapse runs of structurally identical siblings.
    const sig = signature(child);
    let run = 1;
    while (i + run < children.length && signature(children[i + run]!) === sig) run++;

    emit(child, depth, pass, geometry, lines, hardCap);
    if (run >= 3) {
      lines.push(`${indent(depth)}(×${run - 1} similar)`);
      i += run;
    } else {
      i += 1;
    }
  }
}

let lengthCache = new WeakMap<string[], { count: number; length: number }>();
function totalLength(lines: string[]): number {
  const cached = lengthCache.get(lines);
  let length = cached?.length ?? 0;
  for (let k = cached?.count ?? 0; k < lines.length; k++) length += lines[k]!.length + 1;
  lengthCache.set(lines, { count: lines.length, length });
  return length;
}

function emit(el: Element, depth: number, pass: Pass, geometry: boolean, lines: string[], hardCap: number): void {
  let rect: DOMRect | null = null;
  let position = "";
  if (geometry) {
    rect = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    if (style.display === "none" || style.visibility === "hidden") return;
    if (rect.width === 0 && rect.height === 0 && style.display !== "contents") return;
    if (rect.width * rect.height < pass.minArea && !SEMANTIC.has(el.localName)) return;
    if (style.position === "fixed" || style.position === "sticky") position = style.position;
  } else if (el.hasAttribute("hidden")) {
    return;
  }

  // Pass-through wrappers: div > div > div with nothing of their own fold into one line.
  const chain: Element[] = [el];
  let tail = el;
  while (chain.length < 4 && !SEMANTIC.has(tail.localName) && !LEAF.has(tail.localName) && ownText(tail, 1) === "") {
    const kids = Array.from(tail.children).filter((c) => !SKIP.has(c.localName));
    if (kids.length !== 1) break;
    tail = kids[0]!;
    chain.push(tail);
  }

  let line = indent(depth) + chain.map(describe).join(" > ");
  const meta: string[] = [];
  if (rect) meta.push(`${Math.round(rect.width)}×${Math.round(rect.height)}`);
  if (position) meta.push(position);
  if (meta.length) line += ` {${meta.join(", ")}}`;
  const text = ownText(tail, pass.textChars);
  if (text) line += ` "${text}"`;
  const media = mediaHint(tail);
  if (media) line += ` ${media}`;
  lines.push(line);

  if (!LEAF.has(tail.localName) && depth + 1 < pass.maxDepth) walk(tail, depth + 1, pass, geometry, lines, hardCap);
}

function describe(el: Element): string {
  let out = el.localName;
  const id = el.id;
  if (id && id.length <= 40 && !/\d{4,}|[:.]/.test(id)) out += `#${id}`;
  out += classes(el).map((c) => `.${c}`).join("");
  const role = el.getAttribute("role");
  if (role) out += `[role=${role}]`;
  const testId = el.getAttribute("data-testid") ?? el.getAttribute("data-test-id");
  if (testId && testId.length <= 40) out += `[data-testid=${testId}]`;
  const label = el.getAttribute("aria-label");
  if (label && label.length <= 40) out += `[aria-label="${label.replace(/"/g, "'")}"]`;
  if (el.localName === "input") out += `[type=${el.getAttribute("type") ?? "text"}]`;
  return out;
}

/** Up to three classes, preferring readable ones over hashes and utility soup. */
function classes(el: Element): string[] {
  const raw = Array.from(el.classList).filter((c) => /^[A-Za-z_-][\w-]*$/.test(c) && c.length <= 32);
  const readable = raw.filter((c) => !looksHashed(c));
  const chosen = (readable.length ? readable : raw).slice(0, 3);
  return chosen;
}

function looksHashed(c: string): boolean {
  // css-modules (`Header_root__a8Fk2`), styled-components (`sc-bdfBwQ`, `css-1x2y3z`), emotion.
  return /__[A-Za-z0-9]{4,}$|^(sc|css|jsx|emotion)-[A-Za-z0-9]{4,}$|[A-Z].*\d.*[A-Z]|\d{3,}/.test(c);
}

function ownText(el: Element, limit: number): string {
  let text = "";
  for (const node of Array.from(el.childNodes)) {
    if (node.nodeType === 3) text += node.textContent ?? "";
    if (text.length > limit * 2) break;
  }
  text = text.replace(/\s+/g, " ").trim();
  if (!text && (el.localName === "a" || el.localName === "button" || /^h[1-6]$/.test(el.localName))) {
    text = (el.textContent ?? "").replace(/\s+/g, " ").trim();
  }
  if (text.length > limit) text = text.slice(0, limit - 1) + "…";
  return text.replace(/"/g, "'");
}

function mediaHint(el: Element): string {
  if (el.localName === "img") {
    const alt = (el.getAttribute("alt") ?? "").trim().slice(0, 30);
    return alt ? `[img alt="${alt.replace(/"/g, "'")}"]` : "[img]";
  }
  if (el.localName === "iframe") {
    try {
      return `[iframe ${new URL(el.getAttribute("src") ?? "", location.href).host}]`;
    } catch {
      return "[iframe]";
    }
  }
  return "";
}

function signature(el: Element): string {
  return `${el.localName}.${classes(el).join(".")}|${el.children.length > 0 ? 1 : 0}`;
}

function indent(depth: number): string {
  return "  ".repeat(depth);
}

/** Test hook. */
export function __resetSnapshotForTests(): void {
  lengthCache = new WeakMap();
}
