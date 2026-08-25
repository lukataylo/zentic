import { bm25, combine, tokenise, type PostingList } from "./rank.js";
import type { PageMeta, Store } from "./store.js";

export interface Result {
  url: string;
  host: string;
  title: string;
  snippet: string;
  score: number;
  authority: number;
  byline: string | null;
  published: string | null;
}

export interface SearchResponse {
  query: string;
  terms: string[];
  results: Result[];
  total: number;
  elapsedMs: number;
}

export function search(store: Store, query: string, limit = 25): SearchResponse {
  const started = performance.now();
  const terms = [...new Set(tokenise(query))];
  if (terms.length === 0) {
    return { query, terms, results: [], total: 0, elapsedMs: 0 };
  }

  const totalDocuments = Math.max(1, store.pageCount());
  const averageLength = Math.max(1, store.averageWordCount());

  const lists: PostingList[] = terms.map((term) => {
    const postings = store.postingsFor(term);
    return { term, documentFrequency: postings.length, postings };
  });

  // Pages matching every term first. Without this a two-word query is dominated by
  // pages that use one of the words constantly and the other never, which is almost
  // never what was meant.
  const lengths = new Map<string, number>();
  const candidates = bm25(lists, totalDocuments, averageLength, (url) => lengths.get(url) ?? 1);

  const meta = store.pageMeta(candidates.map((candidate) => candidate.url));
  for (const [url, page] of meta) lengths.set(url, page.wordCount);

  // Re-score now that real lengths are known — the first pass could not know them
  // without fetching metadata for the whole posting list.
  const rescored = bm25(lists, totalDocuments, averageLength, (url) => lengths.get(url) ?? 1);

  const complete = rescored.filter((candidate) => candidate.matchedTerms === terms.length);
  const pool = complete.length > 0 ? complete : rescored;

  const ranked = pool
    .map((candidate) => {
      const page = meta.get(candidate.url);
      if (!page) return null;
      return {
        candidate,
        page,
        score: combine(candidate.score, page.rank),
      };
    })
    .filter((entry): entry is { candidate: (typeof pool)[number]; page: PageMeta; score: number } =>
      entry !== null,
    )
    .sort((a, b) => b.score - a.score);

  const results = ranked.slice(0, limit).map(({ page, score }) => ({
    url: page.url,
    host: page.host,
    title: page.title,
    snippet: snippet(page.text, terms),
    score,
    authority: page.rank,
    byline: page.byline,
    published: page.published,
  }));

  return {
    query,
    terms,
    results,
    total: ranked.length,
    elapsedMs: Math.round(performance.now() - started),
  };
}

/**
 * A window of text around the first query term that appears.
 *
 * The first *match*, not the first paragraph: a snippet showing the opening line of
 * every article tells you nothing about why it was returned.
 */
export function snippet(text: string, terms: string[], width = 240): string {
  const haystack = text.replace(/\s+/g, " ").trim();
  const lowered = haystack.toLowerCase();

  let at = -1;
  for (const term of terms) {
    const found = lowered.indexOf(term);
    if (found !== -1 && (at === -1 || found < at)) at = found;
  }
  if (at === -1) return haystack.slice(0, width).trim();

  const start = Math.max(0, at - width / 3);
  const end = Math.min(haystack.length, start + width);
  const body = haystack.slice(start, end).trim();
  return `${start > 0 ? "…" : ""}${body}${end < haystack.length ? "…" : ""}`;
}
