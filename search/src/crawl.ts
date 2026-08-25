import { Budget } from "./config.js";
import { extractPage, hostOf } from "./extract.js";
import { Fetcher } from "./fetcher.js";
import { termFrequencies } from "./rank.js";
import type { Seed } from "./seeds.js";
import { isCrawlable } from "./seeds.js";
import type { Store } from "./store.js";

/**
 * The crawl.
 *
 * Breadth-first across hosts, resumable at any point, and bounded by every limit in
 * `Budget`. The loop is deliberately dull — the interesting decisions all live in
 * `Fetcher` (politeness) and `extractPage` (what is worth keeping), and a crawl
 * loop that is also making those decisions is one nobody can reason about.
 */

export interface CrawlProgress {
  fetched: number;
  indexed: number;
  skipped: number;
  failed: number;
  pending: number;
}

export function seedFrontier(store: Store, seeds: Seed[]): number {
  let added = 0;
  store.transaction(() => {
    for (const seed of seeds) {
      const host = hostOf(seed.url);
      if (!host || !isCrawlable(host)) continue;
      if (store.enqueue(seed.url, host, 0, seed.source)) added += 1;
    }
  });
  return added;
}

export async function crawl(
  store: Store,
  options: { maxPages?: number; onProgress?: (progress: CrawlProgress) => void } = {},
): Promise<CrawlProgress> {
  const fetcher = new Fetcher();
  const limit = options.maxPages ?? Budget.maxPages;
  const progress: CrawlProgress = {
    fetched: 0,
    indexed: 0,
    skipped: 0,
    failed: 0,
    pending: store.pendingCount(),
  };

  // Hosts counted in memory as well as in the store: the per-host cap is consulted
  // for every candidate link, and a COUNT query per link would dominate the run.
  const hostPages = new Map<string, number>();

  let stopping = false;
  const stop = () => {
    if (stopping) return;
    stopping = true;
    console.log("\n  stopping — the frontier is on disk, run `crawl` again to resume");
  };
  process.on("SIGINT", stop);

  while (!stopping && progress.fetched < limit) {
    const batch = store.nextBatch(Budget.hostConcurrency * 4);
    if (batch.length === 0) break;

    // One in-flight request per host. `Fetcher` also serialises per host, so this
    // is about not queueing twenty requests behind one slow server.
    const byHost = new Map<string, typeof batch>();
    for (const item of batch) {
      const list = byHost.get(item.host) ?? [];
      list.push(item);
      byHost.set(item.host, list);
    }

    const wave = [...byHost.values()]
      .map((list) => list[0]!)
      .slice(0, Budget.hostConcurrency);

    await Promise.all(
      wave.map(async (item) => {
        if (stopping || progress.fetched >= limit) return;
        try {
          const seen = hostPages.get(item.host) ?? store.pagesForHost(item.host);
          if (seen >= Budget.maxPagesPerHost) {
            store.markFrontier(item.url, "skipped", "host page cap");
            progress.skipped += 1;
            return;
          }

          const outcome = await fetcher.fetchPage(item.url);
          progress.fetched += 1;
          hostPages.set(item.host, seen + 1);

          if (outcome.kind === "skipped") {
            store.markFrontier(item.url, "skipped", outcome.reason);
            progress.skipped += 1;
            return;
          }
          if (outcome.kind === "failed") {
            store.markFrontier(item.url, "failed", outcome.reason);
            progress.failed += 1;
            return;
          }

          const extracted = extractPage(outcome.html, outcome.finalUrl);
          if (extracted.kind === "rejected") {
            // Still a successful fetch: its links are followed even though its
            // content is not kept. An index page is not worth indexing and is often
            // the best source of links there is.
            store.markFrontier(item.url, "skipped", extracted.reason);
            progress.skipped += 1;
            return;
          }

          const page = extracted.page;
          store.transaction(() => {
            store.savePage({
              url: outcome.finalUrl,
              host: item.host,
              title: page.title,
              text: page.text,
              wordCount: page.wordCount,
              archetype: page.archetype,
              confidence: page.confidence,
              lang: page.lang,
              byline: page.byline,
              published: page.published,
            });

            index(store, outcome.finalUrl, page.title, page.text);

            // Two different jobs, two different link sets. Everything on the page
            // feeds the frontier, because discovery wants the blogroll in the
            // sidebar. Only links from inside the article feed the rank graph,
            // because that is the difference between an endorsement and a footer.
            for (const link of page.contentLinks) {
              store.addLink(outcome.finalUrl, link);
            }
            if (item.depth < Budget.maxDepth) {
              for (const link of page.links) {
                const host = hostOf(link);
                if (host) store.enqueue(link, host, item.depth + 1, item.source);
              }
            }
            store.markFrontier(item.url, "done");
            // A redirect landed us somewhere else. Mark that URL done too, or the
            // crawl will fetch the same document again when the link that pointed at
            // the destination comes up in the frontier.
            if (outcome.finalUrl !== item.url) {
              const host = hostOf(outcome.finalUrl);
              if (host) {
                store.enqueue(outcome.finalUrl, host, item.depth, item.source);
                store.markFrontier(outcome.finalUrl, "done");
              }
            }
          });

            progress.indexed += 1;
        } catch (error) {
          // One page must never be able to end the crawl.
          //
          // Fifty thousand pages of arbitrary HTML will eventually produce
          // something that throws — a document jsdom chokes on, a title longer than
          // SQLite will take, a machine briefly out of memory. Left unguarded that
          // rejects the whole `Promise.all` and kills the run, and because the URL
          // is only marked *inside* the transaction it stays pending: the next
          // resumed crawl reaches the same page and dies at the same point. A
          // poison pill in a crawl that is meant to be resumable.
          //
          // Marked failed outside any transaction, so the mark survives whatever
          // the rollback undid.
          store.markFrontier(item.url, "failed", `threw: ${(error as Error).message}`);
          progress.failed += 1;
        }
      }),
    );

    progress.pending = store.pendingCount();
    options.onProgress?.(progress);
  }

  process.off("SIGINT", stop);
  if (fetcher.droppedHosts.size > 0) {
    console.log(`  dropped ${fetcher.droppedHosts.size} host(s) after repeated failures`);
  }
  return progress;
}

/** Write one page's postings. Title terms are flagged, not duplicated. */
function index(store: Store, url: string, title: string, text: string): void {
  const titleTerms = new Set(termFrequencies(title).keys());
  const counts = termFrequencies(`${title}\n${text}`);

  store.clearPostings(url);
  store.addPostings(
    url,
    [...counts.entries()].map(([term, tf]) => ({
      term,
      tf,
      inTitle: titleTerms.has(term),
    })),
  );
}
