/**
 * Every threshold the crawler and the ranker agree on.
 *
 * Same reasoning as `Budget` on the Swift side: several of these are politeness
 * limits rather than tuning knobs, and one of them changed in isolation is how a
 * hobby crawler turns into something that gets your IP blocked.
 */
export const Budget = {
  // MARK: Politeness
  //
  // These are the numbers that decide whether this is a well-behaved crawler or a
  // nuisance. A small index is not worth annoying anyone for.

  /** Minimum gap between two requests to the *same* host. */
  hostDelayMs: 1_000,
  /** Hosts fetched concurrently. Each host is still serialised by `hostDelayMs`. */
  hostConcurrency: 8,
  /** Give up on a single request after this. */
  requestTimeoutMs: 15_000,
  /** Retries for a transient failure, with exponential backoff from 2s. */
  maxRetries: 2,
  /** A host that returns 429 or 5xx this many times in a row is dropped for the run. */
  hostFailureLimit: 5,
  /** Refuse a body larger than this. A 40MB "page" is not an article. */
  maxBodyBytes: 4_000_000,

  // MARK: Shape of the crawl

  /** Seed domains to keep. */
  maxSeedDomains: 1_000,
  /** Pages to fetch in total. */
  maxPages: 50_000,
  /** Pages from any one host, so a wiki cannot eat the whole budget. */
  maxPagesPerHost: 120,
  /** Link hops from a seed URL. */
  maxDepth: 3,

  // MARK: What is worth indexing

  /** Below this extraction confidence the page is fetched but not indexed. */
  minConfidence: 0.55,
  /** Shorter than this and there is nothing to rank. */
  minWordCount: 120,
  /** Characters of extracted text stored per page, for snippets and scoring. */
  maxStoredChars: 40_000,

  // MARK: Ranking

  /** PageRank damping. The conventional 0.85. */
  damping: 0.85,
  /** PageRank iterations. Converges long before this at our scale. */
  rankIterations: 40,
  /** BM25 term-frequency saturation. */
  bm25K1: 1.2,
  /** BM25 length normalisation. */
  bm25B: 0.75,
  /**
   * How much PageRank is allowed to move a result.
   *
   * Deliberately small. Relevance decides *whether* a page is an answer; authority
   * only breaks ties between pages that are already answers. Turned up, a
   * well-linked homepage outranks the page that actually says the thing.
   */
  authorityWeight: 0.35,
} as const;

/**
 * The product name, in one place because it appears in the UI, the logo and the
 * user agent. Rename here and it is renamed everywhere.
 */
export const NAME = "Loam";
export const TAGLINE = "a small, well-tended patch of the web";

/**
 * Sent on every request.
 *
 * Honest about what this is and who to complain to. A crawler that disguises
 * itself as a browser is one that knows it is not welcome.
 */
export const USER_AGENT =
  `${NAME}/0.1 (+personal local index; respects robots.txt)`;
