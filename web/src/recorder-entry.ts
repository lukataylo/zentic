// The page-world recorder. The only Zentic code that runs in a page's own world.
//
// It exists because a site's own requests are the most durable source of its
// data there is: the site signs them, paginates them and keeps them working,
// and anything that reimplements them — a scraper, an unofficial API client —
// breaks every time the site rotates a token. So instead of asking the site for
// anything, this watches what the page already fetched and forwards a copy.
//
// Constraints, all deliberate:
//
//  - **Forward, don't decide.** No parsing, no filtering beyond "a successful JSON
//    response, small enough". The bundle in the isolated `zentic` world decides
//    what to keep; code here is visible to page script and holds nothing worth
//    reading.
//  - **Never change what the page gets.** Responses are cloned; the original goes
//    back to the caller untouched, on the same tick, with the same errors. A bug
//    here must cost a capture, never a broken site.
//  - **Only on sources.** Swift bakes the user's source sites in at injection
//    (`InPageScript.recorderScript`); on any other site this returns before
//    patching anything. Never installed in a private window.
//  - **Say nothing the page can hear.** Captures travel as a DOM event whose name
//    is random per tab and baked in by Swift, dispatched through a reference taken
//    before any page script ran. `window.postMessage` would hand every body to
//    every `message` listener on the page, the site's and its trackers' alike.
//
// Built as its own bundle (`zentic-recorder.js`) by build.mjs.

const SITES: unknown = "__ZENTIC_CAPTURE_SITES__";
const CHANNEL = "__ZENTIC_CAPTURE_CHANNEL__";
const MAX_BYTES = 4_000_000;

/** The site key, as Swift's `SiteKey` spells it: host, lowercased, no `www.`. */
export function siteKeyOf(location: Location): string {
  return location.hostname.toLowerCase().replace(/^www\./, "");
}

export function install(target: Window & typeof globalThis, sites: unknown, channel: string): boolean {
  const web = target.location.protocol === "https:" || target.location.protocol === "http:";
  if (!web || !Array.isArray(sites) || !sites.includes(siteKeyOf(target.location))) return false;
  if (!channel || channel.startsWith("__")) return false;

  // Taken now, before the page can replace them.
  const dispatch = EventTarget.prototype.dispatchEvent;
  const CustomEventCtor = target.CustomEvent;
  const doc = target.document;

  const post = (url: string, via: "fetch" | "xhr", body: string) => {
    if (body.length > MAX_BYTES) return;
    // Cheap JSON sniff. Parsing happens in the zentic world, never here.
    const first = body.trimStart()[0];
    if (first !== "{" && first !== "[") return;
    dispatch.call(doc, new CustomEventCtor(channel, { detail: JSON.stringify({ url, via, body }) }));
  };

  const isJSON = (contentType: string | null) => !!contentType && /\bjson\b/i.test(contentType);
  const tooBig = (length: string | null) => length !== null && Number(length) > MAX_BYTES;

  const originalFetch = target.fetch;
  if (typeof originalFetch === "function") {
    const patched = function fetch(this: unknown, ...args: Parameters<typeof globalThis.fetch>) {
      const pending = originalFetch.apply(this, args);
      pending.then(
        (response) => {
          try {
            // Errors and rate-limit bodies are not records, and judging an
            // endpoint by its 429 would teach the library it holds nothing.
            if (!response.ok || !isJSON(response.headers.get("content-type"))) return;
            if (tooBig(response.headers.get("content-length"))) return;
            response.clone().text().then(
              (text) => post(response.url, "fetch", text),
              () => {},
            );
          } catch {
            // A locked or opaque body. Not ours to worry about.
          }
        },
        () => {},
      );
      return pending;
    };
    Object.defineProperty(patched, "name", { value: "fetch" });
    Object.defineProperty(patched, "toString", { value: () => originalFetch.toString() });
    target.fetch = patched as typeof globalThis.fetch;
  }

  const XHR = target.XMLHttpRequest;
  if (XHR) {
    const originalSend = XHR.prototype.send;
    // One listener per request object, however many times it is sent: a polling
    // XHR reused for its hundredth load must report one response, not a hundred.
    const watched = new WeakSet<XMLHttpRequest>();
    const onLoad = function (this: XMLHttpRequest) {
      try {
        if (this.status < 200 || this.status >= 300) return;
        if (!isJSON(this.getResponseHeader("content-type"))) return;
        if (this.responseType === "" || this.responseType === "text") {
          post(this.responseURL, "xhr", this.responseText);
        } else if (this.responseType === "json" && this.response != null) {
          post(this.responseURL, "xhr", JSON.stringify(this.response));
        }
      } catch {
        // Same rule as fetch: never let capture surface as a page error.
      }
    };
    // Named `send` for anything that inspects it — which is why the original
    // is held under a different name, or this would call itself.
    const sendPatched = function send(this: XMLHttpRequest, ...args: Parameters<XMLHttpRequest["send"]>) {
      if (!watched.has(this)) {
        watched.add(this);
        this.addEventListener("load", onLoad);
      }
      return originalSend.apply(this, args);
    };
    Object.defineProperty(sendPatched, "toString", { value: () => originalSend.toString() });
    XHR.prototype.send = sendPatched;
  }
  return true;
}

// Only when running as the injected bundle; the test suite imports `install`.
if (typeof window !== "undefined" && !(globalThis as { __ZENTIC_TEST__?: boolean }).__ZENTIC_TEST__) {
  install(window, SITES, CHANNEL);
}
