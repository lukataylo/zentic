import { createServer } from "node:http";

import { NAME, TAGLINE } from "./config.js";
import { logoSVG } from "./logo.js";
import { search, type SearchResponse } from "./query.js";
import type { Store } from "./store.js";

/**
 * The local UI.
 *
 * Bound to loopback, no framework, no bundler, no external request of any kind —
 * the page is one string with its own CSS in a `<style>` block. Partly because a
 * search box and a list of links do not need a build step, and partly because an
 * index whose whole premise is "nothing here is advertising" should not be loading
 * a font from a CDN that logs the request.
 */
export function serve(store: Store, port: number): void {
  const server = createServer((request, response) => {
    const url = new URL(request.url ?? "/", `http://localhost:${port}`);

    if (url.pathname === "/api/search") {
      const query = url.searchParams.get("q") ?? "";
      const body = JSON.stringify(search(store, query, 40));
      response.writeHead(200, { "content-type": "application/json; charset=utf-8" });
      response.end(body);
      return;
    }

    if (url.pathname !== "/") {
      response.writeHead(404, { "content-type": "text/plain" });
      response.end("not found");
      return;
    }

    const query = url.searchParams.get("q")?.trim() ?? "";
    const results = query ? search(store, query, 40) : undefined;
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    response.end(page(store, query, results));
  });

  server.listen(port, "127.0.0.1", () => {
    const stats = store.stats();
    console.log(`\n  ${NAME} — ${TAGLINE}`);
    console.log(
      `  ${stats.pages.toLocaleString()} pages · ${stats.hosts.toLocaleString()} sites · `
        + `${stats.links.toLocaleString()} links`,
    );
    console.log(`  http://localhost:${port}\n`);
  });
}

function page(store: Store, query: string, results: SearchResponse | undefined): string {
  const stats = store.stats();
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${query ? `${escape(query)} — ${NAME}` : NAME}</title>
<style>
  :root {
    --bg: #fbfaf7;
    --surface: #ffffff;
    --text: #1a1a19;
    --muted: #6b6963;
    --line: #e6e3dc;
    --accent: #4a6b3d;
    --measure: 42rem;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #14150f;
      --surface: #1b1c16;
      --text: #eceade;
      --muted: #9a978c;
      --line: #2c2e25;
      --accent: #9dbd85;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font: 16px/1.6 ui-serif, Charter, Georgia, serif;
    padding: 0 1.25rem 6rem;
  }
  header { max-width: var(--measure); margin: 0 auto; padding: ${query ? "2rem 0 1.25rem" : "18vh 0 2rem"}; }
  .brand { display: flex; align-items: center; gap: .6rem; color: var(--accent); text-decoration: none; }
  .brand h1 { font-size: 1.5rem; letter-spacing: .01em; margin: 0; font-weight: 600; color: var(--text); }
  .tagline { color: var(--muted); font-size: .9rem; margin: .5rem 0 0; font-style: italic; }
  form { max-width: var(--measure); margin: 1.5rem auto 0; display: flex; gap: .5rem; }
  input[type=search] {
    flex: 1; padding: .8rem 1rem; font: inherit; color: var(--text);
    background: var(--surface); border: 1px solid var(--line); border-radius: 10px;
  }
  input[type=search]:focus { outline: 2px solid var(--accent); outline-offset: 1px; }
  button {
    padding: .8rem 1.2rem; font: inherit; cursor: pointer; color: var(--bg);
    background: var(--accent); border: 0; border-radius: 10px;
  }
  main { max-width: var(--measure); margin: 0 auto; }
  .meta { color: var(--muted); font-size: .85rem; margin: 1.5rem 0 .5rem; font-family: ui-sans-serif, system-ui, sans-serif; }
  .result { padding: 1.1rem 0; border-top: 1px solid var(--line); }
  .result h2 { margin: 0 0 .2rem; font-size: 1.06rem; font-weight: 600; line-height: 1.35; }
  .result h2 a { color: var(--text); text-decoration: none; }
  .result h2 a:hover { text-decoration: underline; text-decoration-color: var(--accent); }
  .cite { font-family: ui-sans-serif, system-ui, sans-serif; font-size: .8rem; color: var(--accent); }
  .byline { color: var(--muted); }
  .snippet { margin: .4rem 0 0; color: var(--muted); font-size: .94rem; }
  .snippet mark { background: none; color: var(--text); font-weight: 600; }
  .scores { font-family: ui-monospace, SFMono-Regular, monospace; font-size: .72rem; color: var(--muted); opacity: .8; }
  .empty { color: var(--muted); padding: 2rem 0; }
  footer {
    max-width: var(--measure); margin: 3rem auto 0; padding-top: 1.25rem;
    border-top: 1px solid var(--line); color: var(--muted);
    font-family: ui-sans-serif, system-ui, sans-serif; font-size: .78rem;
  }
</style>
</head>
<body>
<header>
  <a class="brand" href="/">${logoSVG(query ? 26 : 34)}<h1>${NAME}</h1></a>
  ${query ? "" : `<p class="tagline">${TAGLINE}</p>`}
  <form action="/" method="get" role="search">
    <input type="search" name="q" value="${escape(query)}" placeholder="what are you looking for?"
      autofocus autocomplete="off" spellcheck="false">
    <button type="submit">Search</button>
  </form>
</header>
<main>
${results ? renderResults(results) : renderIdle(stats)}
</main>
<footer>
  ${stats.pages.toLocaleString()} pages from ${stats.hosts.toLocaleString()} sites ·
  ${stats.links.toLocaleString()} links · ${stats.terms.toLocaleString()} terms ·
  crawled from Hacker News, Reddit, LessWrong and Substack ·
  <strong>no advertising, no tracking, no page ever left this machine</strong>
</footer>
</body>
</html>`;
}

function renderResults(results: SearchResponse): string {
  if (results.results.length === 0) {
    return `<p class="empty">Nothing for <strong>${escape(results.query)}</strong>.
      This index is small on purpose — about a thousand sites — so a miss usually means
      nobody in it has written about this, not that the query was wrong.</p>`;
  }

  const rows = results.results
    .map(
      (result) => `
    <article class="result">
      <h2><a href="${escape(result.url)}" rel="noreferrer">${escape(result.title)}</a></h2>
      <div class="cite">${escape(result.host)}${
        result.byline ? ` <span class="byline">· ${escape(result.byline)}</span>` : ""
      }${result.published ? ` <span class="byline">· ${escape(result.published.slice(0, 10))}</span>` : ""}</div>
      <p class="snippet">${highlight(result.snippet, results.terms)}</p>
      <div class="scores">score ${result.score.toFixed(2)} · authority ${result.authority.toFixed(3)}</div>
    </article>`,
    )
    .join("");

  return `<p class="meta">${results.total.toLocaleString()} result${
    results.total === 1 ? "" : "s"
  } · ${results.elapsedMs} ms</p>${rows}`;
}

function renderIdle(stats: { pages: number; topHosts: { host: string; n: number }[] }): string {
  if (stats.pages === 0) {
    return `<p class="empty">The index is empty. Run <code>npm run seed</code> then
      <code>npm run crawl</code>, and <code>npm run rank</code> when it finishes.</p>`;
  }
  return `<p class="meta">most-indexed sites</p><p class="snippet">${stats.topHosts
    .map((host) => escape(host.host))
    .join(" · ")}</p>`;
}

function escape(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Bold the query terms in a snippet. Escapes first, so this cannot inject. */
function highlight(text: string, terms: string[]): string {
  let html = escape(text);
  for (const term of terms) {
    if (term.length < 2) continue;
    const pattern = new RegExp(`\\b(${term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")})`, "gi");
    html = html.replace(pattern, "<mark>$1</mark>");
  }
  return html;
}
