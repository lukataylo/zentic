import { MINIMAL_CSS } from "./minimal-css";
import { OWN } from "./types";

// Minimal mode: the page's own live DOM, under Zentic's stylesheet instead of
// the site's.
//
// The order of operations is the whole design:
//
//   1. Hide the document (opacity, not visibility — visibility inherits, and
//      step 2 reads computed visibility) with the failsafe armed *first*.
//   2. While the site's CSS is still on, record what it had hidden: menus,
//      modals, mobile duplicates, screen-reader-only helpers. Without author CSS
//      every one of those would suddenly render.
//   3. Switch every author sheet off, stash inline styles, install ours.
//   4. Reveal.
//
// Everything is reversible without a reload: sheets get their `media` back,
// inline styles come back from `data-zentic-style`, our marks are removed.

export const FAILSAFE_MS = 1200;

const STASH_STYLE = "data-zentic-style";
const STASH_MEDIA = "data-zentic-media";
const HIDDEN = "data-zentic-hidden";
const SLIDE_HIDDEN = "data-zentic-slide-hidden";
const SIZED = "data-zentic-sized";
const NO_MEDIA = "\u0000";
const OFF_MEDIA = "not all";
const MAX_SCAN = 20_000;

let active = false;
let transformed = false;
let observer: MutationObserver | null = null;
let failsafe: ReturnType<typeof setTimeout> | null = null;
let disabledAdopted: CSSStyleSheet[] = [];
let readyListener: (() => void) | null = null;
let clickListener: ((event: Event) => void) | null = null;
let pendingRoots = new Set<Element>();
let rescanTimer: ReturnType<typeof setTimeout> | null = null;
let rescans = 0;
let scannedShapes = new Set<string>();
let bodyRescans = 0;
const MAX_BODY_RESCANS = 4;
const RESCAN_DELAY_MS = 250;
const MAX_RESCANS = 16;

export function isMinimalActive(): boolean {
  return active;
}

/** Turn minimal on. Safe to call repeatedly. */
export function enableMinimal(): void {
  if (active) return;
  active = true;

  if (document.readyState === "loading" && !transformed) {
    // Arm the failsafe before hiding: whatever else happens, the page shows.
    failsafe = setTimeout(() => {
      transform();
      reveal();
    }, FAILSAFE_MS);
    guard();
    readyListener = () => {
      // The parser is done, but the site's stylesheets may still be in flight,
      // and step 2 is only true once they apply. Wait for them, inside the failsafe.
      void sheetsLoaded().then(() => {
        transform();
        reveal();
      });
    };
    document.addEventListener("DOMContentLoaded", readyListener, { once: true });
  } else {
    transform();
  }
}

/** Turn minimal off and restore the page exactly. */
export function disableMinimal(): void {
  if (!active) return;
  active = false;
  if (readyListener) document.removeEventListener("DOMContentLoaded", readyListener);
  readyListener = null;
  reveal();
  if (!transformed) return;
  transformed = false;

  observer?.disconnect();
  observer = null;
  if (rescanTimer !== null) clearTimeout(rescanTimer);
  rescanTimer = null;
  pendingRoots.clear();
  if (clickListener) document.removeEventListener("click", clickListener, true);
  clickListener = null;

  for (const el of Array.from(document.querySelectorAll<HTMLElement>(`[${STASH_MEDIA}]`))) {
    const media = el.getAttribute(STASH_MEDIA);
    el.removeAttribute(STASH_MEDIA);
    if (media === NO_MEDIA || media === null) el.removeAttribute("media");
    else el.setAttribute("media", media);
  }
  for (const sheet of disabledAdopted) sheet.disabled = false;
  disabledAdopted = [];

  for (const el of Array.from(document.querySelectorAll<HTMLElement>(`[${STASH_STYLE}]`))) {
    el.setAttribute("style", el.getAttribute(STASH_STYLE) ?? "");
    el.removeAttribute(STASH_STYLE);
  }
  for (const el of Array.from(document.querySelectorAll(`[${SIZED}]`))) {
    el.removeAttribute("width");
    el.removeAttribute("height");
    el.removeAttribute(SIZED);
  }
  for (const el of Array.from(document.querySelectorAll(`[${HIDDEN}], [${SLIDE_HIDDEN}]`))) {
    el.removeAttribute(HIDDEN);
    el.removeAttribute(SLIDE_HIDDEN);
  }
  document.querySelector(`style[${OWN}="minimal"]`)?.remove();
}

// ---------------------------------------------------------------------------

function sheetsLoaded(): Promise<void> {
  const pending = Array.from(document.querySelectorAll<HTMLLinkElement>("link[rel~='stylesheet' i]")).filter(
    (link) => !link.sheet && !link.disabled && !isOwn(link),
  );
  if (pending.length === 0) return Promise.resolve();
  return Promise.all(
    pending.map(
      (link) =>
        new Promise<void>((resolve) => {
          link.addEventListener("load", () => resolve(), { once: true });
          link.addEventListener("error", () => resolve(), { once: true });
        }),
    ),
  ).then(() => undefined);
}

function guard(): void {
  if (document.querySelector(`style[${OWN}="guard"]`)) return;
  const style = document.createElement("style");
  style.setAttribute(OWN, "guard");
  style.textContent = "html{opacity:0!important}";
  (document.head ?? document.documentElement).appendChild(style);
}

function reveal(): void {
  if (failsafe !== null) clearTimeout(failsafe);
  failsafe = null;
  document.querySelector(`style[${OWN}="guard"]`)?.remove();
}

function transform(): void {
  if (!active || transformed) return;
  transformed = true;
  rescans = 0;
  bodyRescans = 0;
  scannedShapes = new Set();

  // 2. What the site hid, it meant to hide. Read it before its CSS goes.
  markHidden();
  markCollapsed(document);
  // 3. Off with the author styles.
  for (const el of Array.from(document.querySelectorAll<HTMLElement>("link, style"))) disableSheet(el);
  disableAdoptedSheets();
  for (const el of Array.from(document.querySelectorAll<HTMLElement>("[style]"))) stashInline(el);
  markEmbeds(document);
  capCarousels();
  install();

  observer = new MutationObserver(onMutations);
  observe();

  // Disclosure widgets: when the site opens something we had hidden, follow it.
  clickListener = (event) => {
    const trigger = (event.target as Element | null)?.closest?.("[aria-controls]");
    if (!trigger) return;
    setTimeout(() => {
      const id = trigger.getAttribute("aria-controls");
      const target = id ? document.getElementById(id) : null;
      if (!target) return;
      if (trigger.getAttribute("aria-expanded") === "true") target.removeAttribute(HIDDEN);
      else if (trigger.getAttribute("aria-expanded") === "false") target.setAttribute(HIDDEN, "");
    }, 60);
  };
  document.addEventListener("click", clickListener, true);
}

function observe(): void {
  observer?.observe(document.documentElement, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ["style", "media", "rel"],
  });
}

/**
 * Elements the site builds after we took over (JS-rendered navs, flyouts,
 * modals) were never seen under its own CSS, so we cannot know what it meant
 * to hide. Briefly hand the site its styles back — inside one synchronous
 * task, so nothing paints — read the late subtrees, and take them away again.
 */
function scheduleRescan(root: Element): void {
  if (hideDuplicate(root)) return;
  if (rescans >= MAX_RESCANS) return;
  // A site that re-renders a component whenever its styles flicker would
  // otherwise feed us an endless series of identical subtrees to read.
  const shape = shapeOf(root);
  if (scannedShapes.has(shape)) return;
  scannedShapes.add(shape);
  pendingRoots.add(root);
  if (rescanTimer !== null) clearTimeout(rescanTimer);
  rescanTimer = setTimeout(rescan, RESCAN_DELAY_MS);
}

/**
 * A stylesheet the site injects after we took over can change what the site
 * means to hide on elements we already read (Apple's nav does exactly this).
 * Once it has loaded, read the whole page again against it.
 */
function lateSheet(el: Element): void {
  if (bodyRescans >= MAX_BODY_RESCANS) return;
  const run = () => {
    if (!active || !transformed || !document.body || bodyRescans >= MAX_BODY_RESCANS) return;
    bodyRescans++;
    pendingRoots.add(document.body);
    if (rescanTimer !== null) clearTimeout(rescanTimer);
    rescanTimer = setTimeout(rescan, RESCAN_DELAY_MS);
  };
  if (el.localName === "link" && !(el as HTMLLinkElement).sheet) {
    el.addEventListener("load", run, { once: true });
  } else {
    run();
  }
}

function shapeOf(el: Element): string {
  const cls = typeof el.className === "string" ? el.className.trim() : "";
  return `${el.localName}.${cls}|${el.childElementCount}|${Math.round((el.textContent?.length ?? 0) / 20)}`;
}

/**
 * Late subtrees identical to a sibling already on the page — a banner a site
 * re-inserts because, without its CSS, it cannot see the first one — are
 * hidden rather than stacked.
 */
function hideDuplicate(el: Element): boolean {
  const html = el.outerHTML;
  if (html.length < 200) return false;
  for (const sibling of Array.from(el.parentElement?.children ?? [])) {
    if (sibling === el || sibling.hasAttribute(HIDDEN)) continue;
    if (sibling.localName === el.localName && sibling.outerHTML === html) {
      el.setAttribute(HIDDEN, "duplicate");
      return true;
    }
  }
  return false;
}

function rescan(): void {
  rescanTimer = null;
  if (!active || !transformed) return;
  const roots = Array.from(pendingRoots).filter(
    (el) => el.isConnected && !el.closest(`[${HIDDEN}]`) && !isOwn(el),
  );
  pendingRoots = new Set();
  const top = roots.filter((el) => !roots.some((other) => other !== el && other.contains(el)));
  if (top.length === 0) return;
  if (!top.includes(document.body!)) rescans++;

  observer?.disconnect();
  const sheets = Array.from(document.querySelectorAll<HTMLElement>(`[${STASH_MEDIA}]`));
  const ours = document.querySelector<HTMLStyleElement>(`style[${OWN}="minimal"]`);
  const custom = document.querySelector<HTMLStyleElement>(`style[${OWN}="custom"]`);
  const inline: Element[] = [];
  try {
    for (const el of sheets) {
      const media = el.getAttribute(STASH_MEDIA);
      if (media === NO_MEDIA || media === null) el.removeAttribute("media");
      else el.setAttribute("media", media);
    }
    for (const sheet of disabledAdopted) sheet.disabled = false;
    ours?.setAttribute("media", OFF_MEDIA);
    custom?.setAttribute("media", OFF_MEDIA);
    for (const root of top) {
      for (const el of [root, ...Array.from(root.querySelectorAll(`[${STASH_STYLE}]`))]) {
        if (!el.hasAttribute(STASH_STYLE)) continue;
        el.setAttribute("style", el.getAttribute(STASH_STYLE) ?? "");
        inline.push(el);
      }
    }
    for (const root of top) markHidden(root);
  } finally {
    for (const el of inline) el.removeAttribute("style");
    for (const el of sheets) el.setAttribute("media", OFF_MEDIA);
    for (const sheet of disabledAdopted) sheet.disabled = true;
    ours?.removeAttribute("media");
    custom?.removeAttribute("media");
    observer?.takeRecords();
    observe();
  }
}

function install(): void {
  // Ours goes first in the cascade among Zentic's sheets, so a custom version's
  // <style id="zentic-custom"> (appended after) wins on equal specificity.
  let style = document.querySelector<HTMLStyleElement>(`style[${OWN}="minimal"]`);
  if (!style) {
    style = document.createElement("style");
    style.setAttribute(OWN, "minimal");
    style.textContent = MINIMAL_CSS;
  }
  const parent = document.head ?? document.documentElement;
  const custom = document.getElementById("zentic-custom");
  if (custom && custom.parentNode) custom.parentNode.insertBefore(style, custom);
  else parent.appendChild(style);
}

function isOwn(el: Element): boolean {
  return el.hasAttribute(OWN) || el.id === "zentic-custom";
}

function insideSVG(el: Element): boolean {
  return el.namespaceURI === "http://www.w3.org/2000/svg" || el.closest("svg") !== null;
}

function isStyleElement(el: Element): boolean {
  if (el.localName === "style") return true;
  if (el.localName !== "link") return false;
  const rel = (el.getAttribute("rel") ?? "").toLowerCase();
  return /\bstylesheet\b/.test(rel) || (/\bpreload\b/.test(rel) && el.getAttribute("as") === "style");
}

function disableSheet(el: Element): void {
  if (!isStyleElement(el) || isOwn(el) || insideSVG(el)) return;
  const media = el.getAttribute("media");
  if (media === OFF_MEDIA && el.hasAttribute(STASH_MEDIA)) return;
  el.setAttribute(STASH_MEDIA, media ?? NO_MEDIA);
  el.setAttribute("media", OFF_MEDIA);
}

function disableAdoptedSheets(): void {
  try {
    const sheets = (document as Document & { adoptedStyleSheets?: CSSStyleSheet[] }).adoptedStyleSheets ?? [];
    for (const sheet of sheets) {
      if (!sheet.disabled) {
        sheet.disabled = true;
        disabledAdopted.push(sheet);
      }
    }
  } catch {
    // Not every engine exposes adopted sheets to an isolated world.
  }
}

function stashInline(el: Element, fromMutation = false): void {
  if (isOwn(el) || insideSVG(el)) return;
  const value = el.getAttribute("style");
  if (value === null) return;
  // The site showing or hiding something with inline style is a strong signal:
  // follow it, since its stylesheet can no longer say so.
  const display = /(?:^|;)\s*display\s*:\s*([a-z-]+)/i.exec(value)?.[1]?.toLowerCase();
  if (display === "none" || /(?:^|;)\s*visibility\s*:\s*hidden/i.test(value)) el.setAttribute(HIDDEN, "inline");
  else if (display && el.getAttribute(HIDDEN) === "inline") el.removeAttribute(HIDDEN);
  else if (display && fromMutation && el.hasAttribute(HIDDEN)) el.removeAttribute(HIDDEN);
  el.setAttribute(STASH_STYLE, value);
  el.removeAttribute("style");
}

function onMutations(records: MutationRecord[]): void {
  if (!active) return;
  for (const record of records) {
    if (record.type === "attributes") {
      const el = record.target as Element;
      if (record.attributeName === "style") {
        if (el.hasAttribute("style")) stashInline(el, true);
      } else if (record.attributeName === "media") {
        // `<link media=print onload="this.media='all'">` — the site re-enabling
        // its own sheet. Keep what it wanted for restore, keep it off for now.
        const media = el.getAttribute("media");
        if (el.hasAttribute(STASH_MEDIA) && media !== OFF_MEDIA) {
          el.setAttribute(STASH_MEDIA, media ?? NO_MEDIA);
          el.setAttribute("media", OFF_MEDIA);
        }
      } else if (record.attributeName === "rel") {
        disableSheet(el);
      }
      continue;
    }
    for (const node of Array.from(record.addedNodes)) {
      if (node.nodeType !== 1) continue;
      const el = node as Element;
      if (isStyleElement(el) && !isOwn(el) && !insideSVG(el)) lateSheet(el);
      disableSheet(el);
      if (el.hasAttribute("style")) stashInline(el);
      for (const child of Array.from(el.querySelectorAll("link, style, [style]"))) {
        disableSheet(child);
        if (child.hasAttribute("style")) stashInline(child);
      }
      markEmbeds(el);
      markCollapsed(el);
      if (el.childElementCount > 0 || el.localName === "div" || el.localName === "section") scheduleRescan(el);
    }
  }
}

// ---------------------------------------------------------------------------
// Reading what the site hid

const KEEP_FIXED = /^(header|nav)$/;

function markHidden(root: Element | null = document.body): void {
  const body = root;
  if (!body) return;
  const view = document.defaultView;
  if (!view) return;
  const vw = view.innerWidth || 1;
  const vh = view.innerHeight || 1;

  let scanned = 0;
  const walker = document.createTreeWalker(body, NodeFilter.SHOW_ELEMENT);
  // A rescan root is itself a candidate; the initial body is not.
  let node = (body === document.body ? walker.nextNode() : body) as Element | null;
  while (node && scanned < MAX_SCAN) {
    scanned++;
    const el = node;
    if (el.localName === "svg" || el.localName === "script" || el.localName === "style" || el.hasAttribute(HIDDEN)) {
      node = el === body ? null : skipSubtree(walker, el);
      continue;
    }
    const style = view.getComputedStyle(el);
    let hide = style.display === "none" || style.visibility === "hidden";

    if (!hide && style.opacity === "0" && style.pointerEvents === "none" && el.localName !== "input") hide = true;
    // Native controls the site redrew itself (opacity:0 radios with styled labels)
    // come back as plain controls. Only checkbox *hacks* — a checkbox standing in
    // for a menu button — stay hidden, since they control nothing visible now.
    if (!hide && el.localName === "input" && style.opacity === "0" && isCheckboxHack(el)) hide = true;
    if (!hide && style.overflow !== "visible" && style.display !== "contents" && hasLayout(el) && el.childElementCount > 0) {
      // Collapsed accordions and menus: clipped to nothing, content waiting inside.
      const rect = el.getBoundingClientRect();
      if (rect.height < 2 || rect.width < 2) hide = true;
    }
    if (!hide && style.position === "absolute") {
      // Screen-reader-only helpers: 1px boxes, clipped boxes, things parked off-screen.
      const clip = style.clip;
      const clipPath = style.clipPath;
      if ((clip && clip.startsWith("rect(0")) || clipPath === "inset(50%)" || clipPath === "inset(100%)") hide = true;
      else if (hasLayout(el)) {
        const rect = el.getBoundingClientRect();
        if ((rect.width <= 2 && rect.height <= 2) || rect.right < -100 || rect.left > vw + 100 || rect.bottom < -50) hide = true;
      }
    }

    if (!hide && el.localName === "a" && /^#/.test(el.getAttribute("href") ?? "") && /^\s*skip\b/i.test(el.textContent ?? "")) {
      // Skip links: parked off-screen until focused, which no longer works.
      hide = true;
    }
    if (!hide && (el.localName === "aside" || el.getAttribute("role") === "complementary") && isEmptyBox(el)) {
      // An ad slot that never filled, now drawn as an empty card.
      hide = true;
    }
    if (!hide && style.position === "fixed") {
      // Without author CSS, fixed things fall into the flow at the end of the
      // page. A site header is worth keeping; chat bubbles, toasts and modals are not.
      const isChrome = KEEP_FIXED.test(el.localName) || el.getAttribute("role") === "banner" || el.querySelector("nav") !== null;
      let coversScreen = false;
      if (hasLayout(el)) {
        const rect = el.getBoundingClientRect();
        coversScreen = rect.width * rect.height > vw * vh * 0.4;
      }
      if (!isChrome || coversScreen) hide = true;
    }

    if (!hide && el.localName === "img") keepDesignedSize(el as HTMLImageElement);
    if (hide) {
      el.setAttribute(HIDDEN, "");
      node = el === body ? null : skipSubtree(walker, el);
      continue;
    }
    walker.currentNode = el;
    node = walker.nextNode() as Element | null;
  }
}

/**
 * An image without width/height attributes was sized by the site's CSS — and
 * an SVG with only a viewBox collapses to nothing without it (Wikipedia's
 * wordmark). Record the size it was designed at; our max-width keeps it fluid.
 */
function keepDesignedSize(img: HTMLImageElement): void {
  if (img.hasAttribute("width") || img.hasAttribute("height") || !hasLayout(img)) return;
  const rect = img.getBoundingClientRect();
  if (rect.width < 4 || rect.height < 4) return;
  img.setAttribute("width", String(Math.round(rect.width)));
  img.setAttribute("height", String(Math.round(rect.height)));
  img.setAttribute(SIZED, "");
}

function isCheckboxHack(el: Element): boolean {
  if (el.getAttribute("type") !== "checkbox") return false;
  if (el.hasAttribute("aria-haspopup") || el.getAttribute("role") === "button") return true;
  const cls = typeof el.className === "string" ? el.className : "";
  if (/dropdown|toggle|menu|hack|burger|drawer/i.test(cls + " " + el.id)) return true;
  const label = el.id ? document.querySelector(`label[for="${CSS.escape(el.id)}"]`) : el.closest("label");
  return !label || (label.textContent ?? "").trim() === "" || label.getAttribute("aria-hidden") === "true";
}

function isEmptyBox(el: Element): boolean {
  return (el.textContent ?? "").trim() === "" && !el.querySelector("img, video, iframe, svg, canvas, input, picture");
}

/** A trigger that says it is collapsed is the most honest signal a page gives. */
function markCollapsed(root: ParentNode): void {
  for (const trigger of Array.from(root.querySelectorAll?.("[aria-expanded='false'][aria-controls]") ?? [])) {
    for (const id of (trigger.getAttribute("aria-controls") ?? "").split(/\s+/)) {
      const target = id ? document.getElementById(id) : null;
      if (target && target !== document.body && !target.contains(trigger)) target.setAttribute(HIDDEN, "collapsed");
    }
  }
}

function hasLayout(el: Element): boolean {
  // jsdom reports zero rects for everything; never treat that as "tiny".
  return !/jsdom/i.test(navigator.userAgent) && typeof el.getBoundingClientRect === "function";
}

function skipSubtree(walker: TreeWalker, el: Element): Element | null {
  walker.currentNode = el;
  let next = walker.nextSibling();
  let parent: Node | null = el;
  while (!next && parent) {
    parent = walker.parentNode();
    if (!parent) return null;
    next = walker.nextSibling();
  }
  return next as Element | null;
}

// ---------------------------------------------------------------------------

const VIDEO_HOSTS = /youtube|youtube-nocookie|vimeo|dailymotion|wistia|loom|twitch|spotify|soundcloud|bandcamp|codepen|ted\.com/i;
const AD_HINT = /doubleclick|googlesyndication|adservice|adsystem|amazon-adsystem|taboola|outbrain|\bads?\b|adnxs|criteo/i;

function markEmbeds(root: ParentNode): void {
  for (const frame of Array.from(root.querySelectorAll?.("iframe") ?? [])) {
    const src = frame.getAttribute("src") ?? "";
    const id = `${frame.id} ${frame.className} ${frame.getAttribute("name") ?? ""}`;
    if (VIDEO_HOSTS.test(src)) frame.setAttribute("data-zentic-video", "");
    else if (AD_HINT.test(src) || AD_HINT.test(id)) frame.setAttribute("data-zentic-ad", "");
  }
}

const CAROUSEL = /carousel|slider|swiper|slick|glide|splide|flickity|owl-/i;

/** Carousels without their CSS render every slide; keep the first three. */
function capCarousels(): void {
  const roots = Array.from(document.querySelectorAll<HTMLElement>("[class]")).filter((el) =>
    CAROUSEL.test(typeof el.className === "string" ? el.className : ""),
  );
  for (const root of roots.slice(0, 40)) {
    const slides = Array.from(root.querySelectorAll<HTMLElement>("[class*='slide' i], [role='group'][aria-roledescription='slide']"))
      .filter((s) => !CAROUSEL.test(s.className.replace(/slide(s)?\b/gi, "")) || /slide/i.test(s.className));
    // Only the innermost run of siblings: slides share a parent.
    const byParent = new Map<Element, HTMLElement[]>();
    for (const slide of slides) {
      const parent = slide.parentElement;
      if (!parent) continue;
      const list = byParent.get(parent) ?? [];
      list.push(slide);
      byParent.set(parent, list);
    }
    for (const list of byParent.values()) {
      if (list.length < 4) continue;
      for (const extra of list.slice(3)) extra.setAttribute(SLIDE_HIDDEN, "");
    }
  }
}

/** Test hook: reset module state between jsdom documents. */
export function __resetMinimalForTests(): void {
  active = false;
  transformed = false;
  observer?.disconnect();
  observer = null;
  if (failsafe !== null) clearTimeout(failsafe);
  failsafe = null;
  disabledAdopted = [];
  readyListener = null;
  clickListener = null;
  if (rescanTimer !== null) clearTimeout(rescanTimer);
  rescanTimer = null;
  pendingRoots = new Set();
  rescans = 0;
  scannedShapes = new Set();
  bodyRescans = 0;
}
