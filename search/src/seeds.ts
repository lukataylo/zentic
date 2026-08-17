import { USER_AGENT, Budget } from "./config.js";

/**
 * Where the index starts.
 *
 * Not a crawl of the web — a crawl of the places people who write carefully tend
 * to publish. The seeds come from communities that already do the filtering:
 * Hacker News, a handful of subreddits, LessWrong, and the Substacks that show up
 * in them. The premise is that a link surviving those is worth a fetch, and
 * everything else is not worth the disk.
 */

export interface Seed {
  url: string;
  /** Which community surfaced it, for `loam stats` and for debugging a bad seed. */
  source: string;
  /** Upvotes, karma, whatever the source counts. Only used to rank the seed list. */
  score: number;
  title: string;
}

/**
 * Hosts that are never seeds and never crawled.
 *
 * Two kinds, and they are excluded for different reasons.
 *
 * **Aggregators and platforms** are where the links came *from*. Indexing them
 * would fill the index with comment threads and link lists rather than the writing
 * they point at, and a link list scores well on every text signal while containing
 * nothing.
 *
 * **Ad, tracker and analytics hosts** are excluded because this index has no
 * advertising in it — not in the results, and not in what was crawled to build
 * them. Extraction already discards page furniture, so an ad cannot reach the
 * index through a page; this stops one reaching it as a *destination*.
 */
const NEVER_CRAWL = [
  // Aggregators, forums and social platforms — the sources, not the writing.
  "news.ycombinator.com",
  "reddit.com",
  "old.reddit.com",
  "redd.it",
  "twitter.com",
  "x.com",
  "facebook.com",
  "instagram.com",
  "linkedin.com",
  "tiktok.com",
  "youtube.com",
  "youtu.be",
  "pinterest.com",
  "quora.com",
  // Link shorteners: a redirect is not a document.
  "bit.ly",
  "t.co",
  "tinyurl.com",
  "lnkd.in",
  // Advertising, tracking and analytics. Nothing here is ever a destination.
  "doubleclick.net",
  "googlesyndication.com",
  "googletagmanager.com",
  "google-analytics.com",
  "googleadservices.com",
  "adservice.google.com",
  "amazon-adsystem.com",
  "scorecardresearch.com",
  "outbrain.com",
  "taboola.com",
  "criteo.com",
  "adnxs.com",
  "quantserve.com",
  "hotjar.com",
  "branch.io",
  "segment.io",
  "mixpanel.com",
  // Stores and paywalled aggregators: not writing.
  "amazon.com",
  "ebay.com",
];

const NEVER_CRAWL_SET = new Set(NEVER_CRAWL);

/** Whether a host may be fetched at all. Matches the host and any subdomain. */
export function isCrawlable(hostname: string): boolean {
  const host = hostname.toLowerCase().replace(/^www\./, "");
  if (NEVER_CRAWL_SET.has(host)) return false;
  return !NEVER_CRAWL.some((banned) => host.endsWith(`.${banned}`));
}

async function getJSON(url: string): Promise<unknown> {
  const response = await fetch(url, {
    headers: { "user-agent": USER_AGENT, accept: "application/json" },
  });
  if (!response.ok) throw new Error(`${response.status} for ${url}`);
  return response.json();
}

/**
 * A feed, with one patient retry.
 *
 * Reddit answers 429 after roughly ten feed requests in quick succession. Seeding
 * is a job that runs once a day at most, so the right answer to being asked to slow
 * down is to slow down rather than to give up on the subreddit.
 */
async function getText(url: string, retryAfterMs = 6_000): Promise<string> {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const response = await fetch(url, {
      headers: {
        "user-agent": USER_AGENT,
        accept: "application/rss+xml, application/xml, text/xml",
      },
    });
    if (response.ok) return response.text();
    if (response.status !== 429 || attempt === 1) throw new Error(`${response.status}`);
    await new Promise((resolve) => setTimeout(resolve, retryAfterMs));
  }
  throw new Error("unreachable");
}

/**
 * Hacker News, via Algolia.
 *
 * Front page plus the best of the last month, because the front page alone is a
 * snapshot of one afternoon and the month is where the durable writing is.
 */
async function hackerNews(): Promise<Seed[]> {
  const windows = [
    { url: "https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=100", label: "front" },
    {
      url:
        "https://hn.algolia.com/api/v1/search_by_date?tags=story&numericFilters=points>150&hitsPerPage=200",
      label: "month",
    },
  ];

  const seeds: Seed[] = [];
  for (const window of windows) {
    try {
      const body = (await getJSON(window.url)) as {
        hits?: { url?: string | null; title?: string | null; points?: number }[];
      };
      for (const hit of body.hits ?? []) {
        if (!hit.url) continue;
        seeds.push({
          url: hit.url,
          source: `hn/${window.label}`,
          score: hit.points ?? 0,
          title: hit.title ?? "",
        });
      }
    } catch (error) {
      console.warn(`  hn/${window.label}: ${(error as Error).message}`);
    }
  }
  return seeds;
}

/**
 * Subreddits where the top links are usually articles rather than images.
 *
 * Read as RSS: the JSON API now answers 403 without OAuth, and a key to manage is
 * a poor trade for reading a public list.
 */
const SUBREDDITS = [
  "programming",
  "MachineLearning",
  "compsci",
  "rust",
  "golang",
  "haskell",
  "typescript",
  "devops",
  "hardware",
  "math",
  "physics",
  "AskHistorians",
  "slatestarcodex",
  "philosophy",
  "TrueReddit",
  "InDepthStories",
];

async function reddit(): Promise<Seed[]> {
  const seeds: Seed[] = [];
  for (const sub of SUBREDDITS) {
    try {
      // RSS, not the JSON API. Reddit now answers 403 to unauthenticated JSON
      // whatever user agent you send, and the alternative is an OAuth client
      // registration — a key to manage, for a personal index, to read a public
      // list. The feed carries the same links and needs nothing.
      const feed = await getText(
        `https://www.reddit.com/r/${sub}/top.rss?t=month&limit=50`,
      );
      for (const entry of parseFeed(feed)) {
        // The article, not the thread about it. A self post has no outbound link
        // and is skipped — its text lives on reddit.com, which is not crawled.
        if (!entry.outbound) continue;
        seeds.push({
          url: entry.outbound,
          // A feed carries no score. Having been selected by the subreddit is the
          // signal; the number would be invented.
          source: `reddit/${sub}`,
          score: 1,
          title: entry.title,
        });
      }
    } catch (error) {
      console.warn(`  reddit/${sub}: ${(error as Error).message}`);
    }
    // Still one at a time, and unhurried: Reddit starts refusing at roughly ten
    // feed requests in quick succession, and this job runs once a day.
    await new Promise((resolve) => setTimeout(resolve, 2_500));
  }
  return seeds;
}

/**
 * LessWrong, via RSS.
 *
 * Its GraphQL endpoint answers 429 to an unauthenticated client, and the feeds do
 * not — same content, no key, no rate limit to negotiate. Curated first because it
 * is hand-picked, then the high-karma front page for volume.
 */
async function lessWrong(): Promise<Seed[]> {
  const feeds = [
    { url: "https://www.lesswrong.com/feed.xml?view=curated-rss", label: "curated", score: 3 },
    {
      url: "https://www.lesswrong.com/feed.xml?view=frontpage-rss&karmaThreshold=75",
      label: "frontpage",
      score: 2,
    },
  ];

  const seeds: Seed[] = [];
  for (const feed of feeds) {
    try {
      for (const entry of parseFeed(await getText(feed.url))) {
        seeds.push({
          url: entry.link,
          source: `lesswrong/${feed.label}`,
          score: feed.score,
          title: entry.title,
        });
      }
    } catch (error) {
      console.warn(`  lesswrong/${feed.label}: ${(error as Error).message}`);
    }
  }
  return seeds;
}

/**
 * Enough RSS and Atom to read a link list.
 *
 * Regex rather than an XML parser, deliberately: the only things wanted are the
 * link and the title, feeds in the wild are frequently not well-formed, and adding
 * a parser dependency to survive that is a poor trade for two fields.
 */
export interface FeedEntry {
  link: string;
  title: string;
  /**
   * The first outbound link in the entry body, when the feed is a discussion feed.
   *
   * Reddit's `<link>` is always the comments page — for a link post as much as for
   * a self post — and the article it is discussing appears only inside `<content>`,
   * as the anchor labelled `[link]`. Without this every Reddit seed is a reddit.com
   * URL, which the crawler correctly refuses, and the whole source contributes
   * nothing.
   */
  outbound?: string;
}

export function parseFeed(xml: string): FeedEntry[] {
  const entries: FeedEntry[] = [];
  const items = xml.split(/<(?:item|entry)[\s>]/i).slice(1);

  for (const item of items) {
    // RSS puts the URL in the element body; Atom puts it in an href attribute.
    const rss = /<link[^>]*>([^<]+)<\/link>/i.exec(item)?.[1];
    const atom = /<link[^>]*href=["']([^"']+)["']/i.exec(item)?.[1];
    const link = (rss ?? atom ?? "").trim();
    if (!link) continue;

    const rawTitle = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(item)?.[1] ?? "";
    const rawContent = /<content[^>]*>([\s\S]*?)<\/content>/i.exec(item)?.[1] ?? "";
    const content = decodeXML(stripCDATA(rawContent));
    const outbound = /href=["']([^"']+)["'][^>]*>\s*\[link\]/i.exec(content)?.[1];

    entries.push({
      link: decodeXML(link),
      title: decodeXML(stripCDATA(rawTitle)).trim(),
      ...(outbound ? { outbound: decodeXML(outbound) } : {}),
    });
  }
  return entries;
}

function stripCDATA(value: string): string {
  return value.replace(/^\s*<!\[CDATA\[/, "").replace(/\]\]>\s*$/, "");
}

function decodeXML(value: string): string {
  return value
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;|&apos;/g, "'")
    .replace(/&amp;/g, "&");
}

/**
 * Substack and the other newsletter hosts.
 *
 * There is no directory worth querying, so these are recognised rather than
 * fetched: any seed already on a newsletter host is kept, and its archive is added
 * so the crawl finds the back catalogue rather than one post.
 */
const NEWSLETTER_HOSTS = [/\.substack\.com$/, /^substack\.com$/, /\.ghost\.io$/, /\.buttondown\.email$/];

function newsletterArchives(seeds: Seed[]): Seed[] {
  const archives = new Map<string, Seed>();
  for (const seed of seeds) {
    let host: string;
    try {
      host = new URL(seed.url).hostname;
    } catch {
      continue;
    }
    if (!NEWSLETTER_HOSTS.some((pattern) => pattern.test(host))) continue;
    const archive = `https://${host}/archive`;
    if (!archives.has(archive)) {
      archives.set(archive, {
        url: archive,
        source: "substack/archive",
        score: seed.score,
        title: `${host} archive`,
      });
    }
  }
  return [...archives.values()];
}

/** Seed URLs kept per host. Enough depth to matter, not enough to skew the crawl. */
const SEEDS_PER_HOST = 4;

export interface SeedSet {
  fetchedAt: string;
  seeds: Seed[];
}

/**
 * Collect seeds from every source, then reduce to the best domains.
 *
 * The reduction matters as much as the collection: a hundred links to one popular
 * site is one seed's worth of information, so seeds are grouped by host and the
 * host is kept once, scored by its best link. That is what turns "trending links"
 * into "sites worth crawling".
 */
export async function collectSeeds(now: () => Date = () => new Date()): Promise<SeedSet> {
  console.log("collecting seeds…");
  const [hn, rd, lw] = await Promise.all([hackerNews(), reddit(), lessWrong()]);
  const all = [...hn, ...rd, ...lw];
  all.push(...newsletterArchives(all));

  // Grouped by host, and a few kept from each rather than one.
  //
  // One per host was wrong in both directions: forty links to the same popular
  // site is one site's worth of information, but a community whose value *is* its
  // many posts — LessWrong, a busy Substack — would contribute a single URL and
  // the crawl would have to rediscover the rest by depth. A handful per host keeps
  // the breadth and the depth.
  const byHost = new Map<string, Seed[]>();
  for (const seed of all) {
    let host: string;
    try {
      const parsed = new URL(seed.url);
      if (parsed.protocol !== "https:" && parsed.protocol !== "http:") continue;
      host = parsed.hostname;
    } catch {
      continue;
    }
    if (!isCrawlable(host)) continue;

    const list = byHost.get(host) ?? [];
    if (!list.some((existing) => existing.url === seed.url)) list.push(seed);
    byHost.set(host, list);
  }

  const hosts = [...byHost.entries()]
    .map(([host, list]) => ({
      host,
      seeds: list.sort((a, b) => b.score - a.score).slice(0, SEEDS_PER_HOST),
      best: Math.max(...list.map((seed) => seed.score)),
    }))
    .sort((a, b) => b.best - a.best)
    .slice(0, Budget.maxSeedDomains);

  const seeds = hosts.flatMap((entry) => entry.seeds);
  console.log(
    `  ${all.length} links → ${byHost.size} domains → keeping ${seeds.length} urls `
      + `across ${hosts.length} domains`,
  );
  return { fetchedAt: now().toISOString(), seeds };
}
