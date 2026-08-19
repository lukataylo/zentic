# Loam

*a small, well-tended patch of the web*

A search engine that crawls about a thousand sites instead of a billion. The sites
are the ones that Hacker News, a set of subreddits, LessWrong and Substack were
already pointing at — the premise being that a link surviving those is worth
fetching, and that almost nothing else is.

It runs entirely on your machine. Nothing is uploaded, no query leaves the process,
and **there is no advertising anywhere in it** — not in the results, and not in what
was crawled to produce them.

```sh
npm install
npm run seed      # collect seeds from HN, Reddit, LessWrong, Substack
npm run crawl     # crawl them — resumable, ^C is safe
npm run rank      # PageRank over the link graph
npm run serve     # the UI on http://localhost:7777
```

`npm run crawl -- --max 300` for a small run first. A full crawl is 50,000 pages and
takes hours; it can be stopped and restarted freely, because the frontier lives in
SQLite rather than in memory.

## How it ranks

Two scores doing two different jobs, and keeping them separate is the whole design.

**BM25** decides whether a page is an answer at all. It is text relevance, computed
per query, with term-frequency saturation so that repeating a word twenty times is
worth barely more than saying it twice, and length normalisation so a long page does
not win by containing everything.

**PageRank** decides what the rest of the index thinks matters. It is a property of
the link graph, computed once after a crawl, and it knows nothing about any query.

They are combined multiplicatively, so authority *scales* relevance rather than
substituting for it — a page with no relevance stays at zero however well-linked it
is. That is what stops homepages colonising every result set, which is what happens
when you rank on PageRank alone.

Two details that matter more at this scale than at web scale:

- **Links within a site do not count.** A blog linking to itself is navigation, not
  endorsement. The first real crawl produced eight pages tied at exactly the maximum
  rank, every one of them half of a same-site pair, because two posts linking to
  each other form a loop that rank cannot escape.
- **Links to pages outside the index are dropped** rather than counted in a page's
  out-degree, which would quietly dilute every real link it makes.
- **Only links inside the article count.** Every page of a site carries the same
  footer, so counting navigation gives boilerplate more in-links than any piece of
  writing can earn: at 400 pages the highest-ranked results were a status page, a
  terms-of-use page and a privacy policy. Links are still *collected* from the whole
  document — a blogroll in a sidebar is the best discovery source a crawl like this
  has — but the rank graph sees only what an author wrote into a sentence. On the
  test index that is 1,753 links rather than 26,324: **93% of what looked like a
  link graph was site chrome.**

On a 185-page test crawl the top-ranked page was *Choose Boring Technology*, and the
second result for `boring technology` was the Tailscale post that cites it. That is
the behaviour working.

Changing what counts as a link invalidates the graph, so `rank` after a recrawl
rather than after an edit to the crawler: pages fetched under the old rules keep the
links they were stored with.

## How advertising stays out

Three layers, none of which is a filter list to maintain.

1. **Only extracted content is ever stored.** Pages go through Zentic's own
   extractor — the same code the browser uses — which returns article content, not
   documents. Navigation, promos, related-content rails and ad slots are discarded
   before anything reaches the database, and no raw HTML is kept for them to be
   recovered from.
2. **Ad, tracker and analytics hosts are never fetched**, so one cannot enter the
   index as a destination either.
3. **The UI has no third-party anything.** One HTML string, its own CSS, an inline
   SVG logo. No font CDN, no analytics, no external request of any kind.

## Being a good guest

The crawler is the only part that touches anyone else's server, so every default is
a politeness decision: one request per host per second, `robots.txt` obeyed and
cached, an honest user agent that says what this is, exponential backoff on 429 and
5xx, and a host that keeps failing is dropped rather than retried at. Concurrency is
across hosts only — never within one.

Seeds come from RSS rather than the JSON APIs, which needs no key and no OAuth
registration to read a public list.

## Layout

| Path | What |
|---|---|
| `src/seeds.ts` | HN, Reddit, LessWrong, Substack → a seed list |
| `src/fetcher.ts` | robots.txt, rate limiting, backoff. The politeness lives here |
| `src/extract.ts` | Adapter onto `web/src/extract` — the browser's own extractor |
| `src/crawl.ts` | The loop. Deliberately dull; the decisions are in the two above |
| `src/rank.ts` | Tokenising, BM25, PageRank |
| `src/query.ts` | Query → ranked results with snippets |
| `src/server.ts` | The local UI |
| `src/config.ts` | Every threshold, in one place |

`npm test` covers the parts that can be wrong without anyone noticing: a ranking
that silently prefers the wrong thing still returns results, and a crawler that
silently ignores `robots.txt` still crawls.

## Why it reuses the browser's extractor

Because the index then contains **exactly what Zentic would show you**. Search
results and the page you land on are the same content, produced by the same code. A
second extractor would drift, and the day it did the index would start describing
pages that no longer exist.
