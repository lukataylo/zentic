import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // The bundle's whole job is DOM manipulation, so tests need a DOM. jsdom is
    // not WebKit and never will be — visual correctness is verified on-device
    // against the golden corpus in M3. What jsdom is good for is the logic that
    // must hold regardless of engine: the reveal failsafe, eligibility rules,
    // and wire parsing.
    environment: "jsdom",
    globals: true,
    include: ["test/**/*.test.ts"],
    // The corpus test parses 76 real pages in jsdom and takes ~100s, which is
    // too slow for the edit loop — `npm run test:corpus` runs it, and
    // `npm run check` gates on it. Forks rather than threads because a single
    // synchronous 30s parse (Node's fs docs) starves the worker RPC and the
    // thread pool reports a spurious teardown error.
    exclude: ["node_modules/**", "test/corpus.test.ts"],
    pool: "forks",
  },
  define: {
    __ZENTIC_VERSION__: JSON.stringify("0.0.0-test"),
  },
});
