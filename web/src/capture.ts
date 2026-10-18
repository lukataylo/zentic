import { post } from "./post";

// The isolated-world half of capture: receives what the recorder saw, decides
// whether it is worth sending, and sends it.
//
// Everything arriving here came from the page's world, so it is checked as if
// the page wrote it — because it may have. The checks are not about trust in
// the content (Swift files every capture under the sending frame's origin, as
// WebKit reports it); they are about not shipping a 4MB analytics blob across
// the bridge on every scroll.

const MAX_BYTES = 4_000_000;

/**
 * Same site as the page: its own host, or a subdomain of it with any leading
 * `www.` dropped (`api.x.com` for `x.com`, `static.bbc.co.uk` for
 * `www.bbc.co.uk`). Not "the last two labels" — on `bbc.co.uk` that is every
 * site in the UK. Third-party JSON is somebody's analytics.
 */
export function isSameSite(url: string, pageHost: string): boolean {
  let host: string;
  try {
    host = new URL(url).hostname;
  } catch {
    return false;
  }
  const site = pageHost.startsWith("www.") ? pageHost.slice(4) : pageHost;
  return host === pageHost || host === site || host.endsWith(`.${site}`);
}

/** Listen on the recorder's channel, and send embedded JSON once the document is parsed. */
export function startCapture(channel: string, win: Window = window, maxBytes = MAX_BYTES): void {
  if (!channel) return;

  win.document.addEventListener(channel, (event: Event) => {
    const detail = (event as CustomEvent<unknown>).detail;
    if (typeof detail !== "string" || detail.length > maxBytes + 4096) return;
    let data: unknown;
    try {
      data = JSON.parse(detail);
    } catch {
      return;
    }
    if (!data || typeof data !== "object") return;
    const { url, via, body } = data as Record<string, unknown>;
    if (typeof url !== "string" || typeof body !== "string") return;
    if (via !== "fetch" && via !== "xhr") return;
    if (body.length > maxBytes) return;
    if (!isSameSite(url, win.location.hostname)) return;
    post({ type: "capture", url, via, body });
  });

  // JSON the server embedded in the document: JSON-LD, Next.js data. Read once
  // the document is parsed, which is the only moment it is reliably all there.
  const scanEmbedded = () => {
    const scripts = win.document.querySelectorAll<HTMLScriptElement>(
      'script[type="application/ld+json"], script#__NEXT_DATA__, script[type="application/json"][id]',
    );
    scripts.forEach((script, index) => {
      const body = script.textContent ?? "";
      if (!body.trim() || body.length > maxBytes) return;
      const kind = script.type === "application/ld+json" ? "ld-json" : (script.id || "json").toLowerCase();
      post({ type: "capture", url: `embedded://${encodeURIComponent(kind)}/${index}`, via: "embedded", body });
    });
  };
  if (win.document.readyState === "loading") {
    win.document.addEventListener("DOMContentLoaded", scanEmbedded, { once: true });
  } else {
    scanEmbedded();
  }
}
