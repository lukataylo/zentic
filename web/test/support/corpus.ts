import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "jsdom";

// Loads the golden corpus into jsdom.
//
// Scripts are never executed. That is not a limitation to work around — it is
// what the corpus is: HTML exactly as the server sent it. Pages whose content
// arrives only after hydration therefore look empty here, and extraction has to
// handle that case anyway, because on a real device it is what the reader sees
// if the settle wait ends early.

export interface CorpusEntry {
  slug: string;
  url: string;
  note: string;
  /** Hand-authored rather than fetched. See the note on each entry. */
  synthetic?: boolean;
}

const here = dirname(fileURLToPath(import.meta.url));
export const CORPUS_DIR = join(here, "..", "corpus");

export function corpusEntries(): CorpusEntry[] {
  const raw = JSON.parse(readFileSync(join(CORPUS_DIR, "sources.json"), "utf8")) as CorpusEntry[];
  return raw.filter((entry) => Boolean(entry.url));
}

export function corpusHTML(slug: string): string | null {
  try {
    return readFileSync(join(CORPUS_DIR, "pages", `${slug}.html`), "utf8");
  } catch {
    return null;
  }
}

export interface LoadedPage {
  dom: JSDOM;
  doc: Document;
  close(): void;
}

export function loadCorpusPage(entry: CorpusEntry): LoadedPage | null {
  const html = corpusHTML(entry.slug);
  if (html === null) return null;

  const dom = new JSDOM(html, {
    url: entry.url,
    // No scripts, no subresource fetches. A test suite that reaches the network
    // is not a regression test.
    runScripts: undefined,
    resources: undefined,
    pretendToBeVisual: false,
  });

  return {
    dom,
    doc: dom.window.document as unknown as Document,
    close: () => dom.window.close(),
  };
}
