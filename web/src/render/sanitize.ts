// Whitelist sanitizer.
//
// Extraction output is untrusted: it is page HTML that has been rearranged, not
// content we authored. It gets parsed in an inert document and then *rebuilt*
// node by node into the reader's document — nothing from the source is ever
// adopted directly, so an element or attribute reaches the shadow root only by
// appearing in a table below.
//
// Rebuild rather than scrub, deliberately. A scrubbing sanitizer has to
// enumerate everything dangerous and loses to whatever the next parser quirk
// turns out to be; a rebuilding one has to enumerate everything *safe*, so a
// novel attack surface is absent by default rather than newly exploitable.

import { ELEMENT_NODE, TEXT_NODE } from "../dom.js";

const MATHML_NS = "http://www.w3.org/1998/Math/MathML";

/** Attributes allowed on any element they appear on. */
const GLOBAL_ATTRS = new Set(["dir", "lang"]);

/**
 * Element → allowed attributes.
 *
 * Absent from this table means one of three things, decided by the sets below:
 * unwrapped (children kept), dropped entirely, or — for anything we have never
 * heard of — unwrapped, because an unknown wrapper usually holds real content
 * and dropping it would lose text.
 */
const ELEMENTS: Record<string, string[]> = {
  p: [],
  h1: ["id"],
  h2: ["id"],
  h3: ["id"],
  h4: ["id"],
  h5: ["id"],
  h6: ["id"],
  br: [],
  hr: [],
  ul: ["id"],
  ol: ["id", "start", "reversed", "type"],
  li: ["id", "value"],
  dl: ["id"],
  dt: ["id"],
  dd: ["id"],
  blockquote: ["id", "cite"],
  q: ["cite"],
  pre: [],
  code: ["data-lang"],
  kbd: [],
  samp: [],
  var: [],
  strong: [],
  b: [],
  em: [],
  i: [],
  u: [],
  s: [],
  del: ["cite", "datetime"],
  ins: ["cite", "datetime"],
  sub: [],
  sup: ["id"],
  small: [],
  mark: [],
  abbr: ["title"],
  cite: [],
  time: ["datetime"],
  span: ["id"],
  a: ["id", "href", "title"],
  img: ["src", "srcset", "sizes", "alt", "width", "height"],
  figure: ["id"],
  figcaption: [],
  table: ["id"],
  caption: [],
  thead: [],
  tbody: [],
  tfoot: [],
  tr: [],
  th: ["colspan", "rowspan", "scope", "headers", "abbr"],
  td: ["colspan", "rowspan", "headers"],
  colgroup: ["span"],
  col: ["span"],
  details: ["open"],
  summary: [],
  iframe: ["src", "width", "height", "title"],
  // Self-hosted media. No `autoplay`, no `loop` — the reader decides when sound
  // and motion start, not the page.
  video: ["src", "poster", "width", "height", "controls", "muted", "playsinline"],
  audio: ["src", "controls"],
  source: ["src", "type", "srcset", "sizes"],
};

/** MathML subset. WebKit renders MathML Core natively, so this needs no CSS. */
const MATHML_ELEMENTS: Record<string, string[]> = {
  math: ["display", "data-latex", "dir"],
  semantics: [],
  annotation: ["encoding"],
  "annotation-xml": ["encoding"],
  mrow: [],
  mi: ["mathvariant"],
  mn: [],
  mo: ["stretchy", "fence", "separator", "largeop", "movablelimits", "lspace", "rspace"],
  ms: [],
  mtext: [],
  mfrac: ["linethickness"],
  msqrt: [],
  mroot: [],
  msub: [],
  msup: [],
  msubsup: [],
  munder: ["accentunder"],
  mover: ["accent"],
  munderover: ["accent", "accentunder"],
  mmultiscripts: [],
  mprescripts: [],
  none: [],
  mtable: ["columnalign", "rowalign", "displaystyle"],
  mtr: ["columnalign"],
  mtd: ["columnalign", "columnspan", "rowspan"],
  mspace: ["width", "height", "depth"],
  mpadded: ["width", "height", "depth", "lspace", "voffset"],
  mphantom: [],
  mstyle: ["displaystyle", "scriptlevel", "mathvariant"],
  merror: [],
};

/**
 * Removed with their subtree.
 *
 * Interactive controls are in here for a product reason rather than a security
 * one: a `<button>` lifted out of its page has nothing behind it, and a reader
 * that shows dead controls is worse than one that shows none. Anything that can
 * execute or fetch is here for the obvious reason.
 */
const DROPPED = new Set([
  "script",
  "style",
  "link",
  "meta",
  "base",
  "title",
  "noscript",
  "template",
  "object",
  "embed",
  "applet",
  "frame",
  "frameset",
  "param",
  "form",
  "input",
  "select",
  "option",
  "optgroup",
  "textarea",
  "button",
  "label",
  "fieldset",
  "legend",
  "output",
  "progress",
  "meter",
  "dialog",
  "menu",
  "nav",
  "track",
  "canvas",
  "map",
  "area",
  // SVG is dropped wholesale in M3: a safe subset means an attribute-level
  // allowlist plus rules for <use>, <style> and <foreignObject>, and getting
  // that wrong is a live network-request hole. Cost is losing inline diagrams.
  "svg",
]);

/** Kept as a wrapper only for its children. */
const UNWRAPPED = new Set([
  "div",
  "article",
  "section",
  "main",
  "header",
  "footer",
  "aside",
  "picture",
  "font",
  "center",
  "big",
  "tt",
  "hgroup",
  "address",
  "ruby",
  "rt",
  "rp",
  "bdi",
  "bdo",
  "wbr",
  "data",
  "dfn",
]);

/** Hosts whose frames are content rather than tracking. */
const EMBED_HOSTS = [
  "www.youtube.com",
  "youtube.com",
  "www.youtube-nocookie.com",
  "youtube-nocookie.com",
  "player.vimeo.com",
  "www.dailymotion.com",
  "geo.dailymotion.com",
  "w.soundcloud.com",
  "open.spotify.com",
  "bandcamp.com",
  "archive.org",
  "player.twitch.tv",
  "video.tv.adobe.com",
  "www.loom.com",
  "asciinema.org",
];

const SAFE_PROTOCOLS = new Set(["http:", "https:", "mailto:", "tel:"]);
const DATA_IMAGE = /^data:image\/(png|jpeg|jpg|gif|webp|avif);base64,[a-z0-9+/=\s]+$/i;
const SAFE_ID = /^[A-Za-z][\w:.-]*$/;
const INTEGER = /^\d{1,6}$/;

export interface SanitizeOptions {
  /** Resolves relative URLs. Extraction normally absolutises them already. */
  baseUrl?: string;
  /** Keep whitelisted video embeds. */
  allowEmbeds?: boolean;
}

/** Absolute, protocol-checked URL, or null. Fragments are handled by the caller. */
function safeUrl(value: string, baseUrl: string | undefined): string | null {
  const trimmed = value.trim();
  if (!trimmed) return null;
  if (DATA_IMAGE.test(trimmed)) return trimmed;

  try {
    const url = new URL(trimmed, baseUrl);
    return SAFE_PROTOCOLS.has(url.protocol) ? url.href : null;
  } catch {
    return null;
  }
}

/** Validate each candidate of a `srcset`, dropping the attribute if any is bad. */
function safeSrcset(value: string, baseUrl: string | undefined): string | null {
  const parts = value
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean);
  if (parts.length === 0) return null;

  const rebuilt: string[] = [];
  for (const part of parts) {
    const [url, ...descriptor] = part.split(/\s+/);
    if (!url) return null;
    const safe = safeUrl(url, baseUrl);
    if (!safe) return null;
    // Descriptors are `123w` or `2x`; anything else is not a descriptor.
    if (descriptor.some((d) => !/^\d+(\.\d+)?[wx]$/.test(d))) return null;
    rebuilt.push([safe, ...descriptor].join(" "));
  }
  return rebuilt.join(", ");
}

function isEmbeddableFrame(src: string): boolean {
  try {
    const url = new URL(src);
    if (url.protocol !== "https:") return false;
    return EMBED_HOSTS.some(
      (host) => url.hostname === host || url.hostname.endsWith(`.${host}`),
    );
  } catch {
    return false;
  }
}

/** Language hint from `data-lang` or a `language-*` / `lang-*` class. */
function codeLanguage(element: Element): string | null {
  const explicit = element.getAttribute("data-lang") ?? element.getAttribute("data-language");
  const candidate =
    explicit ??
    Array.from(element.classList)
      .map((token) => /^(?:language|lang|highlight-source)-([\w+#.-]+)$/.exec(token)?.[1])
      .find(Boolean);
  if (!candidate) return null;
  const normalised = candidate.toLowerCase();
  return /^[\w+#.-]{1,24}$/.test(normalised) ? normalised : null;
}

function copyAttributes(
  source: Element,
  target: Element,
  allowed: string[],
  options: SanitizeOptions,
): void {
  for (const name of [...allowed, ...GLOBAL_ATTRS]) {
    const raw = source.getAttribute(name);
    if (raw === null) continue;

    switch (name) {
      case "href": {
        // In-page references keep working: they are resolved against the
        // reader's own DOM by the click handler, not by the browser, since a
        // fragment cannot cross a shadow boundary.
        const trimmed = raw.trim();
        if (trimmed.startsWith("#")) {
          if (SAFE_ID.test(trimmed.slice(1))) target.setAttribute("href", trimmed);
          break;
        }
        const url = safeUrl(trimmed, options.baseUrl);
        if (url && !DATA_IMAGE.test(url)) {
          target.setAttribute("href", url);
          // Opening a page's link must not hand it a window reference or a
          // referrer we chose on the reader's behalf.
          target.setAttribute("rel", "noopener noreferrer");
        }
        break;
      }
      case "src":
      case "cite": {
        const url = safeUrl(raw, options.baseUrl);
        if (url) target.setAttribute(name, url);
        break;
      }
      case "srcset": {
        const srcset = safeSrcset(raw, options.baseUrl);
        if (srcset) target.setAttribute("srcset", srcset);
        break;
      }
      case "id": {
        if (SAFE_ID.test(raw)) target.setAttribute("id", raw);
        break;
      }
      case "width":
      case "height":
      case "colspan":
      case "rowspan":
      case "span":
      case "start":
      case "value": {
        if (INTEGER.test(raw.trim())) target.setAttribute(name, raw.trim());
        break;
      }
      case "headers": {
        const ids = raw.trim().split(/\s+/).filter((id) => SAFE_ID.test(id));
        if (ids.length) target.setAttribute("headers", ids.join(" "));
        break;
      }
      case "type": {
        // Two unrelated attributes share the name: an <ol> marker style and a
        // <source> MIME type.
        const value = raw.trim();
        if (/^[1aAiI]$/.test(value) || /^[a-z]+\/[\w.+-]+(;\s*codecs=[\w.,"' -]+)?$/i.test(value)) {
          target.setAttribute("type", value);
        }
        break;
      }
      case "dir": {
        const dir = raw.trim().toLowerCase();
        if (dir === "ltr" || dir === "rtl" || dir === "auto") target.setAttribute("dir", dir);
        break;
      }
      case "lang": {
        if (/^[A-Za-z0-9-]{2,35}$/.test(raw.trim())) target.setAttribute("lang", raw.trim());
        break;
      }
      default: {
        // Everything else is plain text. Length-capped because a multi-megabyte
        // `alt` is a memory problem, never real content.
        if (raw.length <= 4096) target.setAttribute(name, raw);
      }
    }
  }
}

function sanitizeNode(node: Node, doc: Document, options: SanitizeOptions): Node | Node[] | null {
  if (node.nodeType === TEXT_NODE) {
    return doc.createTextNode(node.nodeValue ?? "");
  }
  if (node.nodeType !== ELEMENT_NODE) {
    // Comments and processing instructions carry nothing worth rendering, and a
    // comment can hide markup that a later re-parse would resurrect.
    return null;
  }

  const element = node as Element;
  const tag = element.localName.toLowerCase();
  const children = () => sanitizeChildren(element, doc, options);

  if (element.namespaceURI === MATHML_NS) {
    const allowed = MATHML_ELEMENTS[tag];
    if (!allowed) return null;
    // `annotation` holds the source TeX, not display content — dropping it stops
    // the same equation being read out twice by assistive technology.
    if (tag === "annotation" || tag === "annotation-xml") return null;
    const target = doc.createElementNS(MATHML_NS, tag);
    copyAttributes(element, target, allowed, options);
    for (const child of children()) target.appendChild(child);
    return target;
  }

  if (DROPPED.has(tag)) return null;

  if (tag === "iframe") {
    const src = element.getAttribute("src") ?? "";
    const resolved = safeUrl(src, options.baseUrl);
    if (!options.allowEmbeds || !resolved || !isEmbeddableFrame(resolved)) return null;

    const frame = doc.createElement("iframe");
    copyAttributes(element, frame, ELEMENTS["iframe"]!, options);
    frame.setAttribute("src", resolved);
    frame.setAttribute("loading", "lazy");
    frame.setAttribute("referrerpolicy", "no-referrer");
    // allow-same-origin is safe here because the frame is cross-origin: it
    // grants the embed its own origin, not ours.
    frame.setAttribute(
      "sandbox",
      "allow-scripts allow-same-origin allow-presentation allow-popups",
    );
    frame.setAttribute("allow", "fullscreen; picture-in-picture; encrypted-media");
    return frame;
  }

  // A <source> only means anything to its parent. `<picture>` is unwrapped down
  // to its <img>, so a stray one there would be inert clutter.
  if (tag === "source") {
    const parent = element.parentElement?.localName.toLowerCase();
    if (parent !== "video" && parent !== "audio") return null;
  }

  if (UNWRAPPED.has(tag) || !ELEMENTS[tag]) {
    return children();
  }

  const target = doc.createElement(tag);
  copyAttributes(element, target, ELEMENTS[tag]!, options);

  if (tag === "code") {
    const language = codeLanguage(element);
    if (language) target.setAttribute("data-lang", language);
  }
  if (tag === "img") {
    // Lazy by default and never eager: a reading view that fetches forty images
    // before the first paint is slower than the page it replaced.
    target.setAttribute("loading", "lazy");
    target.setAttribute("decoding", "async");
    if (!target.hasAttribute("alt")) target.setAttribute("alt", "");
    if (!target.hasAttribute("src") && !target.hasAttribute("srcset")) {
      // Common lazy-loading shapes, for pages whose real src never landed.
      for (const attribute of ["data-src", "data-original", "data-lazy-src"]) {
        const url = safeUrl(element.getAttribute(attribute) ?? "", options.baseUrl);
        if (url) {
          target.setAttribute("src", url);
          break;
        }
      }
      if (!target.hasAttribute("src")) return null;
    }
  }

  for (const child of children()) target.appendChild(child);
  return target;
}

function sanitizeChildren(parent: Element, doc: Document, options: SanitizeOptions): Node[] {
  const output: Node[] = [];
  for (const child of Array.from(parent.childNodes)) {
    const result = sanitizeNode(child, doc, options);
    if (result === null) continue;
    if (Array.isArray(result)) output.push(...result);
    else output.push(result);
  }
  return output;
}

/**
 * Parse untrusted HTML without side effects.
 *
 * `<template>` content is inert *by specification*: it belongs to a separate
 * document with no browsing context, so scripts do not run and subresources are
 * not fetched — an `<img src>` pointing at a tracking pixel stays unrequested
 * until we decide to keep it.
 *
 * Preferred over `DOMParser` for a second reason: it needs no global, so it works
 * against any document from any realm. The corpus tests load pages into their own
 * jsdom instances, and a sanitizer that reached for `globalThis.DOMParser` would
 * be untestable there.
 */
export function parseUntrusted(html: string, doc: Document): DocumentFragment {
  const template = doc.createElement("template");
  template.innerHTML = html;
  return template.content;
}

/** Sanitize an HTML string into a fragment belonging to `doc`. */
export function sanitizeHTML(
  html: string,
  doc: Document,
  options: SanitizeOptions = {},
): DocumentFragment {
  const fragment = doc.createDocumentFragment();
  const parsed = parseUntrusted(html, doc);
  for (const child of Array.from(parsed.childNodes)) {
    const result = sanitizeNode(child, doc, options);
    if (result === null) continue;
    if (Array.isArray(result)) for (const node of result) fragment.appendChild(node);
    else fragment.appendChild(result);
  }
  return fragment;
}

/** Sanitize an element's children into a fragment belonging to `doc`. */
export function sanitizeElement(
  root: Element | null,
  doc: Document,
  options: SanitizeOptions = {},
): DocumentFragment {
  const fragment = doc.createDocumentFragment();
  if (!root) return fragment;
  for (const child of sanitizeChildren(root, doc, options)) fragment.appendChild(child);
  return fragment;
}
