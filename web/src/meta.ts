import { post } from "./post";

// Site icon and theme colour, for the sidebar and the toolbar tint.

export interface PageMeta {
  icon: string | null;
  themeColor: string | null;
}

export function readMeta(doc: Document = document): PageMeta {
  return { icon: bestIcon(doc), themeColor: themeColor(doc) };
}

export function bestIcon(doc: Document): string | null {
  const links = Array.from(
    doc.querySelectorAll<HTMLLinkElement>("link[rel~='icon' i], link[rel='apple-touch-icon' i], link[rel='apple-touch-icon-precomposed' i], link[rel='shortcut icon' i]"),
  );
  let best: { href: string; score: number } | null = null;
  for (const link of links) {
    const href = link.href || link.getAttribute("href");
    if (!href || href.startsWith("data:") && href.length > 200_000) continue;
    const rel = (link.getAttribute("rel") ?? "").toLowerCase();
    const type = (link.getAttribute("type") ?? "").toLowerCase();
    const sizes = (link.getAttribute("sizes") ?? "").toLowerCase();
    let size = 16;
    if (sizes === "any" || type.includes("svg") || /\.svg(\?|$)/i.test(href)) size = 256;
    else {
      for (const token of sizes.split(/\s+/)) {
        const n = Number.parseInt(token.split("x")[0] ?? "", 10);
        if (Number.isFinite(n)) size = Math.max(size, n);
      }
      if (!sizes && rel.includes("apple-touch-icon")) size = 180;
    }
    // Ideal is a crisp ~64–256px raster; enormous ones are fine but not preferred.
    const score = size > 512 ? 512 - (size - 512) / 10 : size;
    if (!best || score > best.score) best = { href: absolute(href, doc), score };
  }
  return best?.href ?? null;
}

function themeColor(doc: Document): string | null {
  const metas = Array.from(doc.querySelectorAll<HTMLMetaElement>("meta[name='theme-color' i]"));
  for (const meta of metas) {
    const media = meta.getAttribute("media");
    if (media && !(doc.defaultView?.matchMedia?.(media).matches ?? false)) continue;
    const content = meta.getAttribute("content")?.trim();
    if (content) return content;
  }
  return null;
}

function absolute(href: string, doc: Document): string {
  try {
    return new URL(href, doc.baseURI).href;
  } catch {
    return href;
  }
}

export function startMetaReporting(): void {
  let last = "";
  const send = () => {
    const meta = readMeta();
    const key = `${meta.icon}|${meta.themeColor}`;
    if (key === last) return;
    last = key;
    post({ type: "meta", icon: meta.icon, themeColor: meta.themeColor });
  };
  const start = () => {
    send();
    let timer: ReturnType<typeof setTimeout> | null = null;
    const observer = new MutationObserver(() => {
      if (timer) clearTimeout(timer);
      timer = setTimeout(send, 300);
    });
    if (document.head) observer.observe(document.head, { childList: true, subtree: true, attributes: true, attributeFilter: ["href", "content"] });
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start, { once: true });
  else start();
}
