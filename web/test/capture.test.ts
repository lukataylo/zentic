import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { isSameSite, startCapture } from "../src/capture";

(globalThis as { __ZENTIC_TEST__?: boolean }).__ZENTIC_TEST__ = true;
const { install } = await import("../src/recorder-entry");

// Capture has two halves in two worlds, and the property both must hold is the
// same: the page gets exactly what it would have got without us, and only a
// source's own JSON crosses the bridge.

/** What `post()` sends to the `zentic` handler, as Swift would receive it. */
function fakeHandler() {
  const posted: Array<{ type: string; url?: string; via?: string; body?: string }> = [];
  (window as unknown as { webkit: unknown }).webkit = {
    messageHandlers: { zentic: { postMessage: (m: (typeof posted)[number]) => posted.push(m) } },
  };
  return posted;
}

/** jsdom delivers postMessage asynchronously, like a browser. */
const flush = () => new Promise((resolve) => setTimeout(resolve, 10));

describe("isSameSite", () => {
  it("accepts the page's host and its API subdomains, nothing else", () => {
    expect(isSameSite("https://x.com/i/api/graphql/a/HomeTimeline", "x.com")).toBe(true);
    expect(isSameSite("https://api.x.com/2/timeline", "x.com")).toBe(true);
    expect(isSameSite("https://static.bbc.co.uk/feed.json", "www.bbc.co.uk")).toBe(true);
    expect(isSameSite("https://evil.co.uk/feed.json", "www.bbc.co.uk")).toBe(false);
    expect(isSameSite("https://analytics.tracker.example/collect", "x.com")).toBe(false);
    expect(isSameSite("https://x.com.evil.example/", "x.com")).toBe(false);
    expect(isSameSite("not a url", "x.com")).toBe(false);
  });
});

const CHANNEL = "zc0123456789abcdef";

describe("forwarder", () => {
  const send = (data: unknown, channel = CHANNEL) =>
    document.dispatchEvent(new CustomEvent(channel, { detail: typeof data === "string" ? data : JSON.stringify(data) }));

  it("forwards a source's own JSON", () => {
    const posted = fakeHandler();
    startCapture(CHANNEL, window, 1000);
    send({ url: `${location.origin}/api/feed`, via: "fetch", body: '{"a":1}' });
    const captured = posted.filter((e) => e.type === "capture");
    expect(captured).toHaveLength(1);
    expect(captured[0]).toEqual({ type: "capture", url: `${location.origin}/api/feed`, via: "fetch", body: '{"a":1}' });
  });

  it("drops other channels, wrong shapes, third parties and oversize bodies", () => {
    // A channel of its own: listeners from earlier tests are still on the document.
    const channel = `${CHANNEL}-drops`;
    const posted = fakeHandler();
    startCapture(channel, window, 10);
    send({ url: `${location.origin}/a`, via: "fetch", body: "{}" }, "zc-someone-else");
    send({ url: `${location.origin}/a`, via: "beacon", body: "{}" }, channel);
    send({ url: "https://tracker.example/a", via: "fetch", body: "{}" }, channel);
    send({ url: `${location.origin}/a`, via: "fetch", body: '{"much":"too long"}' }, channel);
    send("not json", channel);
    document.dispatchEvent(new CustomEvent(channel, { detail: { url: `${location.origin}/a`, via: "fetch", body: "{}" } }));
    expect(posted.filter((e) => e.type === "capture")).toHaveLength(0);
  });

  it("listens on nothing without a channel", () => {
    const posted = fakeHandler();
    startCapture("", window, 1000);
    send({ url: `${location.origin}/a`, via: "fetch", body: "{}" }, "");
    expect(posted.filter((e) => e.type === "capture")).toHaveLength(0);
  });

  it("forwards JSON the server embedded in the document", () => {
    document.body.innerHTML = `
      <script type="application/ld+json">{"@type":"NewsArticle","headline":"h"}</script>
      <script id="__NEXT_DATA__" type="application/json">{"props":{}}</script>
      <script type="application/json">{"no":"id, so not app data"}</script>`;
    const posted = fakeHandler();
    startCapture(CHANNEL, window, 1000);
    const urls = posted.filter((e) => e.type === "capture").map((e) => e.url);
    expect(urls).toEqual(["embedded://ld-json/0", "embedded://__next_data__/1"]);
    document.body.innerHTML = "";
  });
});

describe("recorder", () => {
  let originalFetch: typeof fetch;
  let originalSend: typeof XMLHttpRequest.prototype.send;
  let messages: Array<{ url: string; via: string; body: string }>;
  const origin = () => `${location.protocol}//${location.hostname}`;
  const site = () => location.hostname.replace(/^www\./, "");
  const listener = (event: Event) => messages.push(JSON.parse((event as CustomEvent<string>).detail));

  beforeEach(() => {
    originalFetch = window.fetch;
    originalSend = XMLHttpRequest.prototype.send;
    messages = [];
    document.addEventListener(CHANNEL, listener);
  });

  afterEach(() => {
    window.fetch = originalFetch;
    XMLHttpRequest.prototype.send = originalSend;
    document.removeEventListener(CHANNEL, listener);
  });

  const json = (body: string, init: ResponseInit = {}) => {
    const response = new Response(body, { ...init, headers: { "content-type": "application/json", ...(init.headers ?? {}) } });
    Object.defineProperty(response, "url", { value: `${origin()}/api/feed` });
    return response;
  };

  it("patches nothing on a page that is not a source, or without a channel", () => {
    const before = window.fetch;
    expect(install(window, ["somewhere.else"], CHANNEL)).toBe(false);
    expect(install(window, "__ZENTIC_CAPTURE_SITES__", CHANNEL)).toBe(false);
    expect(install(window, [site()], "__ZENTIC_CAPTURE_CHANNEL__")).toBe(false);
    expect(window.fetch).toBe(before);
  });

  it("gives the page its own response, untouched, and forwards a copy", async () => {
    const body = JSON.stringify({ items: [1, 2, 3] });
    const response = json(body);
    window.fetch = vi.fn(async () => response) as typeof fetch;

    expect(install(window, [site()], CHANNEL)).toBe(true);
    const got = await window.fetch("/api/feed");
    expect(got).toBe(response);
    expect(await got.json()).toEqual({ items: [1, 2, 3] });

    await flush();
    expect(messages).toContainEqual({ url: `${origin()}/api/feed`, via: "fetch", body });
  });

  it("never forwards an error body, which would teach the library an endpoint is empty", async () => {
    window.fetch = vi.fn(async () => json('{"errors":[{"code":88}]}', { status: 429 })) as typeof fetch;
    install(window, [site()], CHANNEL);
    await window.fetch("/api/feed");
    await flush();
    expect(messages).toHaveLength(0);
  });

  it("does not change a failing fetch into a different failure", async () => {
    const failure = new TypeError("Load failed");
    window.fetch = vi.fn(async () => {
      throw failure;
    }) as typeof fetch;
    install(window, [site()], CHANNEL);
    await expect(window.fetch("/x")).rejects.toBe(failure);
  });

  it("ignores responses that are not JSON", async () => {
    window.fetch = vi.fn(async () => new Response("<html>", { headers: { "content-type": "text/html" } })) as typeof fetch;
    install(window, [site()], CHANNEL);
    await window.fetch("/page");
    await flush();
    expect(messages).toHaveLength(0);
  });

  it("reports a reused XHR once per load, not once per send so far", () => {
    // Stub the network half of send: fire `load` synchronously as a 200 JSON reply.
    XMLHttpRequest.prototype.send = function (this: XMLHttpRequest) {
      Object.defineProperty(this, "status", { value: 200, configurable: true });
      Object.defineProperty(this, "responseText", { value: '{"n":1}', configurable: true });
      Object.defineProperty(this, "responseURL", { value: `${origin()}/poll`, configurable: true });
      this.getResponseHeader = () => "application/json";
      this.dispatchEvent(new Event("load"));
    };
    install(window, [site()], CHANNEL);
    const xhr = new XMLHttpRequest();
    for (let i = 0; i < 3; i++) xhr.send();
    expect(messages).toHaveLength(3);
  });
});
