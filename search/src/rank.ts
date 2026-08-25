import { Budget } from "./config.js";

/**
 * Two scores, doing two different jobs.
 *
 * **BM25** answers "is this page about the query" — it is a text-relevance score,
 * computed per query, and it is what decides whether a page is an answer at all.
 *
 * **PageRank** answers "does the rest of the index think this page matters" — it is
 * a property of the link graph, computed once after a crawl, and it knows nothing
 * about any query.
 *
 * Conflating them is the classic mistake. PageRank alone ranks a site's homepage
 * above the page that actually answers you, because the homepage is what everyone
 * links to. So authority here is a *tie-breaker*: it reorders pages that are
 * already relevant, and `Budget.authorityWeight` keeps it from doing more.
 */

// MARK: - Tokenising

/**
 * Text → terms.
 *
 * Deliberately simple: lowercase, split on non-letters, drop stopwords and
 * single characters. No stemmer — an English stemmer would collide "universal"
 * and "universe", and at this index size the recall it buys is not worth the
 * precision it costs.
 */
export function tokenise(text: string): string[] {
  return text
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .split(/[^a-z0-9+#.]+/)
    .map((token) => token.replace(/^[.]+|[.]+$/g, ""))
    .filter((token) => token.length > 1 && token.length < 40 && !STOPWORDS.has(token));
}

const STOPWORDS = new Set(
  ("a an and are as at be been but by can did do does for from had has have he her his how i if in into is it its "
    + "of on or our out so than that the their them then there these they this to too was we were what when where "
    + "which who why will with would you your").split(" "),
);

/** Term frequencies for one document. */
export function termFrequencies(text: string): Map<string, number> {
  const counts = new Map<string, number>();
  for (const term of tokenise(text)) {
    counts.set(term, (counts.get(term) ?? 0) + 1);
  }
  return counts;
}

// MARK: - PageRank

export interface Graph {
  /** Every node that can hold rank — i.e. every page actually indexed. */
  nodes: string[];
  edges: { src: string; dst: string }[];
}

/** Whether two URLs live on the same site, ignoring `www.`. */
export function sameHost(a: string, b: string): boolean {
  try {
    const host = (url: string) => new URL(url).hostname.replace(/^www\./, "").toLowerCase();
    return host(a) === host(b);
  } catch {
    return false;
  }
}

/**
 * Mini PageRank.
 *
 * The 1998 formulation, unchanged: rank flows along links, damped so that a
 * fraction of it teleports uniformly instead. Two details that are easy to get
 * wrong and that matter more at small scale than at web scale:
 *
 * **Dangling nodes.** A page with no outbound links into the index would leak its
 * rank out of the system each iteration, and the totals would sag towards zero. Its
 * rank is redistributed uniformly instead, which is the standard fix and keeps the
 * vector a probability distribution.
 *
 * **Edges to pages we never fetched** are dropped. A link to something outside the
 * index cannot carry rank to a node that does not exist, and counting it in the
 * out-degree would silently dilute every real link on the page.
 */
export function pageRank(graph: Graph): Map<string, number> {
  const nodes = graph.nodes;
  const count = nodes.length;
  const ranks = new Map<string, number>();
  if (count === 0) return ranks;

  const index = new Map(nodes.map((node, i) => [node, i]));
  const outbound: number[][] = Array.from({ length: count }, () => []);

  for (const edge of graph.edges) {
    const from = index.get(edge.src);
    const to = index.get(edge.dst);
    if (from === undefined || to === undefined || from === to) continue;
    // Only links *between sites* carry rank.
    //
    // A site linking to itself is not an endorsement, it is navigation — and at
    // this index size counting it is actively wrong. Two posts on one blog that
    // link to each other form a closed loop with nowhere for rank to escape to, so
    // they absorb it: the first run of this produced eight pages tied at exactly
    // the maximum, every one of them half of a same-site pair, while genuinely
    // well-cited essays sat below them.
    if (sameHost(edge.src, edge.dst)) continue;
    outbound[from]!.push(to);
  }

  const initial = 1 / count;
  let current = new Float64Array(count).fill(initial);
  const next = new Float64Array(count);

  for (let iteration = 0; iteration < Budget.rankIterations; iteration += 1) {
    next.fill(0);
    let dangling = 0;

    for (let node = 0; node < count; node += 1) {
      const targets = outbound[node]!;
      if (targets.length === 0) {
        dangling += current[node]!;
        continue;
      }
      const share = current[node]! / targets.length;
      for (const target of targets) next[target] = (next[target] ?? 0) + share;
    }

    const teleport = (1 - Budget.damping) / count + (Budget.damping * dangling) / count;
    let delta = 0;
    for (let node = 0; node < count; node += 1) {
      const updated = teleport + Budget.damping * next[node]!;
      delta += Math.abs(updated - current[node]!);
      next[node] = updated;
    }
    current = Float64Array.from(next);

    // Converged. At a few thousand nodes this is usually true well before the
    // iteration cap, and continuing would only burn cycles.
    if (delta < 1e-8) break;
  }

  // Normalised to 0…1 against the strongest page, so `authorityWeight` means the
  // same thing whatever the index size.
  let max = 0;
  for (const value of current) max = Math.max(max, value);
  const scale = max > 0 ? 1 / max : 0;
  for (let node = 0; node < count; node += 1) {
    ranks.set(nodes[node]!, current[node]! * scale);
  }
  return ranks;
}

// MARK: - BM25

export interface Candidate {
  url: string;
  /** Sum of the BM25 contributions of each query term. */
  score: number;
  matchedTerms: number;
}

export interface PostingList {
  term: string;
  /** How many documents contain the term. */
  documentFrequency: number;
  postings: { url: string; tf: number; inTitle: number }[];
}

/**
 * Okapi BM25 over the query's posting lists.
 *
 * The two knobs both exist to stop long documents winning by default: `k1`
 * saturates term frequency, so the tenth occurrence counts for far less than the
 * second, and `b` normalises by length against the index average.
 */
export function bm25(
  lists: PostingList[],
  totalDocuments: number,
  averageLength: number,
  lengthOf: (url: string) => number,
): Candidate[] {
  const scores = new Map<string, { score: number; matched: number }>();

  for (const list of lists) {
    if (list.documentFrequency === 0) continue;
    // The +0.5 smoothing is what keeps IDF positive for a term in most documents.
    const idf = Math.log(
      1 + (totalDocuments - list.documentFrequency + 0.5) / (list.documentFrequency + 0.5),
    );

    for (const posting of list.postings) {
      const length = Math.max(1, lengthOf(posting.url));
      const tf = posting.tf;
      const denominator =
        tf + Budget.bm25K1 * (1 - Budget.bm25B + (Budget.bm25B * length) / averageLength);
      let contribution = (idf * (tf * (Budget.bm25K1 + 1))) / denominator;

      // A term in the title is a much stronger signal than the same term buried in
      // the body — titles are written to say what a page is about.
      if (posting.inTitle) contribution *= 1.8;

      const existing = scores.get(posting.url) ?? { score: 0, matched: 0 };
      existing.score += contribution;
      existing.matched += 1;
      scores.set(posting.url, existing);
    }
  }

  return [...scores.entries()].map(([url, value]) => ({
    url,
    score: value.score,
    matchedTerms: value.matched,
  }));
}

/**
 * Relevance and authority, combined.
 *
 * Multiplicative rather than additive, so authority scales a page's relevance
 * instead of substituting for it: a page with no relevance stays at zero however
 * well-linked it is, which is the property that stops homepages colonising every
 * result set.
 */
export function combine(relevance: number, authority: number): number {
  return relevance * (1 + Budget.authorityWeight * authority);
}
