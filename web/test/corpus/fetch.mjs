// Fetches the golden corpus. Run manually, not from `npm run check` — the
// committed HTML is the test input, so tests must never depend on the network.
//
//     node test/corpus/fetch.mjs           # fetch anything missing
//     node test/corpus/fetch.mjs --force   # re-fetch everything
//
// Pages are saved verbatim as the server sent them. That is the point: a corpus
// of tidied-up HTML would test a world we don't ship into. What it does *not*
// capture is post-JavaScript DOM, so SPA-rendered pages arrive as empty shells —
// which is itself a case extraction has to survive.

import { mkdirSync, existsSync, writeFileSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const sources = JSON.parse(readFileSync(join(here, "sources.json"), "utf8"));
const force = process.argv.includes("--force");
const pagesDir = join(here, "pages");
mkdirSync(pagesDir, { recursive: true });

// A desktop Safari UA. Sending a bot UA gets a different (often better) page than
// the one a Zentic user would see, which would make the corpus optimistic.
const HEADERS = {
  "user-agent":
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
  accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
  "accept-language": "en-US,en;q=0.9",
};

const MAX_BYTES = 4_000_000;
const results = [];

for (const source of sources) {
  const file = join(pagesDir, `${source.slug}.html`);
  if (source.synthetic) {
    results.push({ slug: source.slug, status: existsSync(file) ? "synthetic" : "MISSING" });
    continue;
  }
  if (!force && existsSync(file)) {
    results.push({ slug: source.slug, status: "cached" });
    continue;
  }

  try {
    const response = await fetch(source.url, {
      headers: HEADERS,
      redirect: "follow",
      signal: AbortSignal.timeout(30_000),
    });
    const html = await response.text();

    if (!response.ok) {
      results.push({ slug: source.slug, status: `http ${response.status}` });
      continue;
    }
    if (html.length > MAX_BYTES) {
      results.push({ slug: source.slug, status: `too big (${html.length})` });
      continue;
    }
    if (html.length < 500) {
      results.push({ slug: source.slug, status: `too small (${html.length})` });
      continue;
    }

    writeFileSync(file, html, "utf8");
    results.push({
      slug: source.slug,
      status: "ok",
      bytes: html.length,
      finalUrl: response.url,
    });
  } catch (error) {
    results.push({ slug: source.slug, status: `error: ${error.message}` });
  }
}

for (const result of results) {
  const detail = result.bytes ? ` ${(result.bytes / 1024).toFixed(0)}KB` : "";
  console.log(`${result.status.padEnd(24)} ${result.slug}${detail}`);
}
const ok = results.filter((r) => r.status === "ok" || r.status === "cached").length;
console.log(`\n${ok}/${sources.length} available`);
