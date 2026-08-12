import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import { extract } from "../src/extract/index.js";
import type { Expectation } from "./corpus/measure.js";
import { corpusEntries, loadCorpusPage, CORPUS_DIR } from "./support/corpus.js";

// The golden corpus: 76 real pages, extraction pinned to a reviewed answer.
//
// This is the primary safety net for the highest-risk component. The pages are
// the HTML the server actually sent, so the test is offline and deterministic,
// and it catches the regressions that matter — a page that stops restructuring,
// a page that starts restructuring when it shouldn't, a title that collapses to
// a date, a section kind that disappears.
//
// When extraction changes on purpose:
//
//     npm run corpus              # read the table
//     npm run corpus -- --write   # rewrite expectations.json, then READ THE DIFF
//
// A machine can record what extraction does today; only a person can say whether
// that is the right answer. Never bless a --write without reading it.

const MIN_CONFIDENCE = 0.55;
const MIN_WORD_COUNT = 40;

const expectations = new Map(
  (
    JSON.parse(readFileSync(join(CORPUS_DIR, "expectations.json"), "utf8")) as Expectation[]
  ).map((row) => [row.slug, row]),
);

const entries = corpusEntries();

describe("golden corpus", () => {
  it("has an expectation for every page, and a page for every expectation", () => {
    const slugs = entries.map((entry) => entry.slug).sort();
    expect([...expectations.keys()].sort()).toEqual(slugs);
    for (const entry of entries) {
      expect(loadCorpusPage(entry), `missing HTML: ${entry.slug}`).not.toBeNull();
    }
  });

  for (const entry of entries) {
    const want = expectations.get(entry.slug);
    if (!want) continue;

    it(
      `${entry.slug} — ${want.restructured ? "restructures" : `passes through (${want.declined})`}`,
      async () => {
        // Extraction is one long synchronous block — up to ~13s for a 1MB page,
        // because jsdom matches selectors in JavaScript where WebKit uses a
        // native engine. Yield first so vitest's reporter can flush; without
        // this the run reports a spurious worker RPC timeout.
        await new Promise((resolve) => setTimeout(resolve, 0));

        const page = loadCorpusPage(entry);
        expect(page).not.toBeNull();
        if (!page) return;

        try {
          const outcome = extract(page.doc, {
            url: entry.url,
            minWordCount: MIN_WORD_COUNT,
          });
          const result = outcome.result;
          const restructured =
            result.archetype !== "app" && !outcome.empty && result.confidence >= MIN_CONFIDENCE;

          // Invariant 2: never restructure an app. Asserted directly rather than
          // read off the golden file, so a --write can never bless a regression
          // that mangles someone's mail client.
          if (result.archetype === "app") expect(restructured).toBe(false);

          expect({
            archetype: result.archetype,
            restructured,
            title: result.title,
            words: result.wordCount,
            confidence: Number(result.confidence.toFixed(2)),
            kinds: [...new Set(result.sections.map((section) => section.kind))].sort(),
            fidelitySensitive: result.isFidelitySensitive,
          }).toEqual({
            archetype: want.archetype,
            restructured: want.restructured,
            title: want.title,
            words: want.words,
            confidence: want.confidence,
            kinds: want.kinds,
            fidelitySensitive: want.fidelitySensitive,
          });
        } finally {
          page.close();
        }
      },
      60_000,
    );
  }

  it("restructures the pages a reader mode exists for", () => {
    // A floor, not a target. The pages we decline are apps, index and hub pages,
    // threads (M4), and two that ship no content without JavaScript. If this
    // number falls, extraction got worse; if it climbs, check *what* changed.
    const restructured = [...expectations.values()].filter((row) => row.restructured).length;
    expect(restructured).toBeGreaterThanOrEqual(48);
  });
});
