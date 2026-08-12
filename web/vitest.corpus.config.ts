import { defineConfig } from "vitest/config";

// The golden corpus, run on its own: `npm run test:corpus`.
//
// A standalone config rather than a merge of vitest.config.ts, because that one
// excludes this file: parsing 76 real pages in jsdom takes ~100s, too slow for
// the edit loop. `npm run check` runs both.
export default defineConfig({
  test: {
    environment: "jsdom",
    globals: true,
    include: ["test/corpus.test.ts"],
    exclude: ["node_modules/**"],
    // One synchronous 30s parse (Node's fs docs) starves a worker thread's RPC
    // channel and reports a spurious teardown error. Forks do not have that
    // problem.
    pool: "forks",
    testTimeout: 60_000,
    teardownTimeout: 60_000,
  },
  define: {
    __ZENTIC_VERSION__: JSON.stringify("0.0.0-test"),
  },
});
