import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { Budget, NAME, TAGLINE } from "./config.js";
import { crawl, seedFrontier } from "./crawl.js";
import { logoASCII } from "./logo.js";
import { pageRank } from "./rank.js";
import { search } from "./query.js";
import { collectSeeds, type SeedSet } from "./seeds.js";
import { serve } from "./server.js";
import { Store } from "./store.js";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const DATA = join(root, "data");
const SEEDS = join(DATA, "seeds.json");
const INDEX = join(DATA, "index.db");

function open(): Store {
  mkdirSync(DATA, { recursive: true });
  return new Store(INDEX);
}

async function main(): Promise<void> {
  const [command, ...rest] = process.argv.slice(2);

  switch (command) {
    case "seed": {
      const seeds = await collectSeeds();
      mkdirSync(DATA, { recursive: true });
      writeFileSync(SEEDS, JSON.stringify(seeds, null, 2));
      console.log(`  wrote ${seeds.seeds.length} seeds → ${SEEDS}`);

      const store = open();
      const added = seedFrontier(store, seeds.seeds);
      console.log(`  queued ${added} new url(s)`);
      store.close();
      break;
    }

    case "crawl": {
      const store = open();
      if (store.pendingCount() === 0) {
        // Re-seed from the cached file rather than the network: a crawl should be
        // repeatable offline once the seeds have been collected once.
        try {
          const cached = JSON.parse(readFileSync(SEEDS, "utf8")) as SeedSet;
          seedFrontier(store, cached.seeds);
        } catch {
          console.error("  nothing queued and no cached seeds. Run `npm run seed` first.");
          store.close();
          process.exitCode = 1;
          return;
        }
      }

      const max = Number(flag(rest, "--max") ?? Budget.maxPages);
      console.log(`  crawling up to ${max.toLocaleString()} pages…`);
      const started = Date.now();
      let lastLog = 0;

      const progress = await crawl(store, {
        maxPages: max,
        onProgress: (p) => {
          const now = Date.now();
          if (now - lastLog < 2_000) return;
          lastLog = now;
          const rate = p.fetched / Math.max(1, (now - started) / 1000);
          process.stdout.write(
            `\r  ${p.indexed} indexed · ${p.fetched} fetched · ${p.skipped} skipped · `
              + `${p.failed} failed · ${p.pending} queued · ${rate.toFixed(1)}/s   `,
          );
        },
      });

      console.log(
        `\n  done: ${progress.indexed} indexed, ${progress.skipped} skipped, `
          + `${progress.failed} failed, ${progress.pending} still queued`,
      );
      console.log("  run `npm run rank` to recompute authority");
      store.close();
      break;
    }

    case "rank": {
      const store = open();
      const nodes = store.allPageUrls();
      if (nodes.length === 0) {
        console.error("  nothing indexed yet");
        store.close();
        return;
      }
      console.log(`  ranking ${nodes.length.toLocaleString()} pages…`);
      const ranks = pageRank({ nodes, edges: store.allLinks() });
      store.setRanks(ranks);

      const top = [...ranks.entries()].sort((a, b) => b[1] - a[1]).slice(0, 10);
      console.log("  most-linked pages in the index:");
      for (const [url, rank] of top) console.log(`    ${rank.toFixed(3)}  ${url}`);
      store.setMeta("rankedAt", new Date().toISOString());
      store.close();
      break;
    }

    case "search": {
      const query = rest.join(" ");
      if (!query) {
        console.error("  usage: npm run search -- \"your query\"");
        process.exitCode = 1;
        return;
      }
      const store = open();
      const response = search(store, query, 10);
      console.log(logoASCII);
      if (response.results.length === 0) {
        console.log(`  nothing for "${query}"`);
      }
      response.results.forEach((result, i) => {
        console.log(`  ${String(i + 1).padStart(2)}  ${result.title}`);
        console.log(`      ${result.host}  ·  ${result.score.toFixed(2)}`);
        console.log(`      ${result.snippet.slice(0, 150)}`);
        console.log("");
      });
      console.log(`  ${response.total} results · ${response.elapsedMs} ms`);
      store.close();
      break;
    }

    case "serve": {
      const store = open();
      serve(store, Number(flag(rest, "--port") ?? 7777));
      break;
    }

    case "stats": {
      const store = open();
      const stats = store.stats();
      console.log(`\n  ${NAME} — ${TAGLINE}\n`);
      console.log(`  pages     ${stats.pages.toLocaleString()}`);
      console.log(`  sites     ${stats.hosts.toLocaleString()}`);
      console.log(`  links     ${stats.links.toLocaleString()}`);
      console.log(`  terms     ${stats.terms.toLocaleString()}`);
      console.log(`  queued    ${stats.pending.toLocaleString()}`);
      console.log(`  ranked    ${store.meta("rankedAt") ?? "never"}\n`);
      console.log("  most indexed:");
      for (const host of stats.topHosts) {
        console.log(`    ${String(host.n).padStart(5)}  ${host.host}`);
      }
      console.log("");
      store.close();
      break;
    }

    default:
      console.log(logoASCII);
      console.log(`  ${TAGLINE}\n`);
      console.log("  npm run seed              collect seeds from HN, Reddit, LessWrong, Substack");
      console.log("  npm run crawl             crawl them (resumable — ^C is safe)");
      console.log("  npm run crawl -- --max 500   a smaller run, to try it out");
      console.log("  npm run rank              recompute PageRank over the link graph");
      console.log("  npm run serve             the local UI on :7777");
      console.log('  npm run search -- "query" one-off search from the terminal');
      console.log("  npm run stats             what is in the index\n");
  }
}

function flag(args: string[], name: string): string | undefined {
  const at = args.indexOf(name);
  return at === -1 ? undefined : args[at + 1];
}

await main();
