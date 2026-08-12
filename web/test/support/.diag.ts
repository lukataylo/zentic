import { extract } from "../../src/extract/index.js";
import { corpusEntries, loadCorpusPage } from "./corpus.js";
import { countWords } from "../../src/dom.js";

const want = process.argv.slice(2);
for (const entry of corpusEntries().filter((e) => want.includes(e.slug))) {
  const page = loadCorpusPage(entry)!;
  const out = extract(page.doc, { url: entry.url, minWordCount: 40 });
  const r = out.result;
  const kinds: Record<string, number> = {};
  for (const s of r.sections) kinds[s.kind] = (kinds[s.kind] ?? 0) + 1;
  const long = r.sections.filter((s) => s.kind === "paragraph" && countWords(s.markdown) >= 25).length;
  const links = r.sections.reduce((n, s) => n + (s.markdown.match(/\]\(/g)?.length ?? 0), 0);
  console.log("=".repeat(70));
  console.log(entry.slug, { archetype: r.archetype, words: r.wordCount, conf: r.confidence, long, links, kinds, app: out.app.confidence.toFixed(2) });
  console.log("title:", JSON.stringify(r.title));
  console.log("first sections:");
  for (const s of r.sections.slice(0, 8)) console.log(" ", s.kind, JSON.stringify(s.markdown.slice(0, 110)));
  page.close();
}
