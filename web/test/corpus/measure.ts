// Measures extraction across the whole corpus, and regenerates the expectations
// the corpus test asserts against.
//
//     npm run corpus            # print the table
//     npm run corpus -- --write # rewrite expectations.json
//
// Expectations are generated *and then read by a human*. That is the only honest
// way to build a golden file: a machine can record what extraction does today,
// but only a person can say whether that is the right answer. After a --write,
// read the diff — a changed title or a collapsed word count is the test doing its
// job, not noise to be blessed away.

import { writeFileSync } from "node:fs";
import { join } from "node:path";

import { extract } from "../../src/extract/index.js";
import type { SectionKind } from "../../src/wire.js";
import { corpusEntries, loadCorpusPage, CORPUS_DIR } from "../support/corpus.js";

const MIN_CONFIDENCE = 0.55;
const MIN_WORD_COUNT = 40;

export interface Expectation {
  slug: string;
  archetype: string;
  title: string;
  words: number;
  confidence: number;
  kinds: SectionKind[];
  fidelitySensitive: boolean;
  /** Whether the pipeline would render this page rather than pass it through. */
  restructured: boolean;
  /** Why, when it is not restructured. */
  declined?: string;
}

function measure(): Expectation[] {
  const rows: Expectation[] = [];

  for (const entry of corpusEntries()) {
    const page = loadCorpusPage(entry);
    if (!page) {
      console.error(`missing page: ${entry.slug}`);
      continue;
    }

    const started = Date.now();
    try {
      const outcome = extract(page.doc, {
        url: entry.url,
        minWordCount: MIN_WORD_COUNT,
      });
      const result = outcome.result;
      const restructured =
        result.archetype !== "app" && !outcome.empty && result.confidence >= MIN_CONFIDENCE;

      const declined =
        result.archetype === "app"
          ? `app: ${outcome.app.reasons.slice(0, 2).join("; ")}`
          : outcome.empty
            ? `empty: ${result.wordCount} words`
            : result.confidence < MIN_CONFIDENCE
              ? `confidence ${result.confidence.toFixed(2)}`
              : undefined;

      rows.push({
        slug: entry.slug,
        archetype: result.archetype,
        title: result.title,
        words: result.wordCount,
        confidence: Number(result.confidence.toFixed(2)),
        kinds: [...new Set(result.sections.map((section) => section.kind))].sort(),
        fidelitySensitive: result.isFidelitySensitive,
        restructured,
        ...(declined ? { declined } : {}),
      });

      console.log(
        [
          restructured ? "OK  " : "PASS",
          result.archetype.padEnd(7),
          String(result.wordCount).padStart(6),
          result.confidence.toFixed(2),
          `${Date.now() - started}ms`.padStart(7),
          entry.slug.padEnd(34),
          declined ?? result.title.slice(0, 60),
        ].join(" "),
      );
    } catch (error) {
      console.log(`FAIL ${entry.slug}: ${(error as Error).message}`);
      rows.push({
        slug: entry.slug,
        archetype: "error",
        title: "",
        words: 0,
        confidence: 0,
        kinds: [],
        fidelitySensitive: false,
        restructured: false,
        declined: `threw: ${(error as Error).message}`,
      });
    } finally {
      page.close();
    }
  }

  return rows;
}

const rows = measure();
const restructured = rows.filter((row) => row.restructured).length;
console.log(`\n${restructured}/${rows.length} restructured (${((restructured / rows.length) * 100).toFixed(0)}%)`);

if (process.argv.includes("--write")) {
  const path = join(CORPUS_DIR, "expectations.json");
  writeFileSync(path, `${JSON.stringify(rows, null, 2)}\n`, "utf8");
  console.log(`wrote ${path}`);
}
