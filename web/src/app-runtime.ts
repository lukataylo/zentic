import { MINIMAL_TOKENS } from "./minimal-css";

// `window.zentic` — the whole surface a generated app has. Built to `zentic-app.js`.
//
// Served from the app's own origin (`zentic://<id>/_zentic/runtime.js`) and run
// before any script the model wrote. Everything here is a thin, read-only view
// of the library through the scheme handler, which is where scope is enforced;
// this file is convenience, not security. An app that bypassed it and called
// the endpoints directly would get exactly the same answers.

interface AppConfig {
  appID: string;
  name: string;
}

export interface Runtime {
  readonly app: { readonly id: string; readonly name: string };
  query(query?: Record<string, unknown>): Promise<unknown[]>;
  sources(): Promise<unknown[]>;
  onChange(listener: () => void): () => void;
  h(strings: TemplateStringsArray, ...values: unknown[]): DocumentFragment;
  text(source: string | null | undefined): DocumentFragment;
  plain(source: string | null | undefined, max?: number): string;
  timeAgo(iso: string | null | undefined, now?: number): string;
}

const ESCAPES: Record<string, string> = {
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;",
  "`": "&#96;",
};

export function escapeHTML(value: string): string {
  return value.replace(/[&<>"'`]/g, (c) => ESCAPES[c]!);
}

/**
 * A tagged template that escapes every interpolation.
 *
 * Nodes (including other `h` results) are spliced in as nodes; arrays are
 * flattened; `null`, `undefined` and `false` render as nothing so conditionals
 * read naturally. Everything else becomes escaped text — the point of the
 * function, since records are text from the web.
 */
export function makeH(doc: Document) {
  return function h(strings: TemplateStringsArray, ...values: unknown[]): DocumentFragment {
    const nodes: Node[] = [];
    const render = (value: unknown): string => {
      if (value == null || value === false) return "";
      if (Array.isArray(value)) return value.map(render).join("");
      if (typeof value === "object" && "nodeType" in (value as object)) {
        nodes.push(value as Node);
        return `<!--zentic-node:${nodes.length - 1}-->`;
      }
      return escapeHTML(String(value));
    };

    let html = strings[0] ?? "";
    values.forEach((value, index) => {
      html += render(value) + (strings[index + 1] ?? "");
    });

    const template = doc.createElement("template");
    template.innerHTML = html;
    const walker = doc.createTreeWalker(template.content, NodeFilter.SHOW_COMMENT);
    const placeholders: Comment[] = [];
    while (walker.nextNode()) placeholders.push(walker.currentNode as Comment);
    for (const comment of placeholders) {
      const match = /^zentic-node:(\d+)$/.exec(comment.data);
      const node = match ? nodes[Number(match[1])] : undefined;
      if (node) comment.replaceWith(node);
    }
    return template.content;
  };
}

const URL_PATTERN = /\[([^\]\n]{1,300})\]\((https?:\/\/[^\s)]+)\)|(https?:\/\/[^\s<>"')\]]+[^\s<>"')\].,;:!?])/g;

/**
 * A record's text as safe, readable DOM: paragraphs on blank lines, breaks on
 * single newlines, and links — Markdown `[label](url)` or bare `https://…` —
 * as real anchors that open beside the app. Images in Markdown are dropped;
 * everything else is text, never markup.
 *
 * Every app needs exactly this, and every app that writes its own does it with
 * `innerHTML`. Here it is built from text nodes, so captured markup stays text.
 */
export function makeText(doc: Document) {
  return function text(source: string | null | undefined): DocumentFragment {
    const fragment = doc.createDocumentFragment();
    const cleaned = (source ?? "").replace(/!\[[^\]]*\]\([^)]*\)/g, "").trim();
    if (!cleaned) return fragment;

    for (const block of cleaned.split(/\n{2,}/)) {
      const p = doc.createElement("p");
      block.split("\n").forEach((line, index) => {
        if (index > 0) p.appendChild(doc.createElement("br"));
        let last = 0;
        for (const match of line.matchAll(URL_PATTERN)) {
          const at = match.index ?? 0;
          if (at > last) p.appendChild(doc.createTextNode(line.slice(last, at)));
          const href = match[2] ?? match[3] ?? "";
          const a = doc.createElement("a");
          a.href = href;
          a.target = "_blank";
          a.rel = "noopener";
          a.textContent = match[1] ?? displayURL(href);
          p.appendChild(a);
          last = at + match[0].length;
        }
        if (last < line.length) p.appendChild(doc.createTextNode(line.slice(last)));
      });
      fragment.appendChild(p);
    }
    return fragment;
  };
}

/** `https://www.example.com/a/b?c` → `example.com/a/b…`, for a link's label. */
export function displayURL(href: string): string {
  try {
    const url = new URL(href);
    const path = url.pathname === "/" ? "" : url.pathname;
    const shown = url.hostname.replace(/^www\./, "") + path;
    return shown.length > 40 ? `${shown.slice(0, 39)}…` : shown + (url.search ? "…" : "");
  } catch {
    return href;
  }
}

/** Text without Markdown, whitespace collapsed, cut at a word boundary. */
export function plain(source: string | null | undefined, max = 280): string {
  const text = (source ?? "")
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/^#{1,6}\s+/gm, "")
    .replace(/^\s*[-*+>]\s+/gm, "")
    .replace(/[*_`~]{1,3}([^*_`~]+)[*_`~]{1,3}/g, "$1")
    .replace(/\s+/g, " ")
    .trim();
  if (text.length <= max) return text;
  const cut = text.slice(0, max);
  const space = cut.lastIndexOf(" ");
  return `${(space > max * 0.6 ? cut.slice(0, space) : cut).replace(/[,;:.!?-]+$/, "")}…`;
}

export function timeAgo(iso: string | null | undefined, now = Date.now()): string {
  if (!iso) return "";
  const then = Date.parse(iso);
  if (Number.isNaN(then)) return "";
  const seconds = Math.max(0, Math.round((now - then) / 1000));
  if (seconds < 45) return "now";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours}h`;
  const days = Math.round(hours / 24);
  if (days < 7) return `${days}d`;
  const date = new Date(then);
  const sameYear = date.getFullYear() === new Date(now).getFullYear();
  return date.toLocaleDateString(undefined, sameYear ? { month: "short", day: "numeric" } : { month: "short", day: "numeric", year: "numeric" });
}

/** Minimal's tokens on `:root`, so an app built on `var(--z-…)` looks like the
 * rest of Zentic and follows dark mode with no work of its own. */
export function themeStylesheet(): string {
  return [
    MINIMAL_TOKENS,
    "html { background: var(--z-bg); color: var(--z-fg); font: 400 var(--z-size) / 1.55 var(--z-font); }",
  ].join("\n");
}

export function createRuntime(win: Window, config: AppConfig): Runtime {
  const listeners = new Set<() => void>();
  let pending: ReturnType<typeof setTimeout> | undefined;

  // Swift dispatches this when the library changes. Coalesced, because a scroll
  // on the source site lands as a burst of captures.
  win.addEventListener("zentic:change", () => {
    if (pending !== undefined) clearTimeout(pending);
    pending = setTimeout(() => {
      pending = undefined;
      for (const listener of listeners) {
        try {
          listener();
        } catch (error) {
          console.error("[zentic] onChange listener threw", error);
        }
      }
    }, 250);
  });

  const get = async (path: string): Promise<unknown[]> => {
    const response = await fetch(path, { cache: "no-store" });
    if (!response.ok) throw new Error(`zentic: ${path} → ${response.status}`);
    const body = (await response.json()) as unknown;
    return Array.isArray(body) ? body : [];
  };

  return Object.freeze({
    app: Object.freeze({ id: config.appID, name: config.name }),
    query: (query: Record<string, unknown> = {}) =>
      get(`/_zentic/query?q=${encodeURIComponent(JSON.stringify(query))}`),
    sources: () => get("/_zentic/sources"),
    onChange(listener: () => void) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    h: makeH(win.document),
    text: makeText(win.document),
    plain,
    timeAgo,
  });
}

/**
 * A second lock on WebRTC. The shell switches peer connections off in the
 * engine for app tabs; if a WebKit ever lacks that switch, this removes the
 * constructors before any app script runs. Iframes are where a fresh copy would
 * come from, and frames are refused by the app's policy.
 */
export function removePeerConnections(win: Window): void {
  for (const name of ["RTCPeerConnection", "webkitRTCPeerConnection", "RTCDataChannel", "RTCIceCandidate"]) {
    try {
      Object.defineProperty(win, name, { value: undefined, writable: false, configurable: false });
    } catch {
      // Already absent or locked down: either way, not usable.
    }
  }
}

function boot(): void {
  const config = (window as { __zenticAppConfig?: AppConfig }).__zenticAppConfig;
  if (!config) return;
  removePeerConnections(window);

  const style = document.createElement("style");
  style.textContent = themeStylesheet();
  // The document is still being parsed, and this script sits in its head.
  (document.head ?? document.documentElement).appendChild(style);

  Object.defineProperty(window, "zentic", {
    value: createRuntime(window, config),
    writable: false,
    configurable: false,
    enumerable: true,
  });
}

if (typeof window !== "undefined" && !(globalThis as { __ZENTIC_TEST__?: boolean }).__ZENTIC_TEST__) {
  boot();
}
