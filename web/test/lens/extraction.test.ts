import { beforeEach, describe, expect, it } from "vitest";

import { extract } from "../../src/extract/index.js";
import { LensJournal, runStructuralOps } from "../../src/lens/ops.js";
import { buildSkeleton } from "../../src/skeleton.js";
import type { Lens } from "../../src/wire.js";

// Where the lens engine meets the extraction pipeline.
//
// On the eligible path both run against the same document, and the lens pass runs
// first: it is registered at DOM ready and inserts its nodes before extraction
// reads a thing. That ordering is deliberate and worth keeping — a lens that hides
// a page's junk genuinely improves what the extractor finds.
//
// What is not acceptable is the other half of it. A `label` op puts a sentence the
// *model* wrote into the page, and an `insert` op renders rows Zentic harvested
// from somewhere else on it. Left in the document, both become sections of an
// `ExtractionResult` — verified below, they arrive as the first paragraphs of the
// article — and `ExtractionResult` is the input to a redesign and to a rewrite. So
// a model would be asked to re-voice a string Zentic invented and hand it back to
// the user as the page's own opening line. Nobody chose that; it fell out of two
// features meeting. Our nodes are invisible to the extractor and to the skeleton,
// and visible to nobody but the reader of the actual page.

const PAGE = `
  <main>
    <article>
      <h1>A quiet week in the archives</h1>
      <p>The cataloguing project has been running for eleven months now, and the
      shelves in the east wing are finally beginning to look like something a
      person could navigate without a map and a great deal of patience.</p>
      <p>Most of what has come out of the boxes is correspondence. Letters between
      the trustees, mostly, and a surprising quantity of receipts for coal. The
      interesting material is thinner than anyone hoped, which is the ordinary
      condition of an archive rather than a disappointment peculiar to this one.</p>
      <p>What did turn up, in a folder marked only with a year, was a run of
      photographs of the reading room before the second refit. They show a space
      arranged for a kind of reading nobody does here any more, and they are the
      best argument yet for finishing the catalogue before the building changes
      again around it.</p>
    </article>
    <nav id="elsewhere">
      <a href="/one">The east wing reopens in spring</a>
      <a href="/two">What the trustees wrote to each other</a>
    </nav>
  </main>
`;

/** A sentence that exists nowhere in the page, so finding it in an extraction can
 * only mean our own node was read. Long enough to survive as a paragraph, which
 * is exactly what makes the leak worth preventing rather than theoretical. */
const MODEL_SENTENCE =
  "Zentic wrote this heading itself and it is a whole sentence long, so it reads as prose.";

const HARVESTED = "The east wing reopens in spring";

function lensWith(ops: Lens["ops"]): Lens {
  return {
    id: "lens-1",
    name: "Focus",
    origin: "example.com",
    pathPattern: "*",
    isEnabled: true,
    prompt: "tidy the archive page",
    regions: [
      { id: "article", intent: "the article", selectors: ["article"] },
      { id: "elsewhere", intent: "the further reading links", selectors: ["#elsewhere"] },
    ],
    ops,
    createdAt: "2026-01-01T00:00:00Z",
    updatedAt: "2026-01-01T00:00:00Z",
    schemaVersion: 1,
  };
}

function apply(ops: Lens["ops"]): void {
  runStructuralOps(document, [lensWith(ops)], { journal: new LensJournal(document) });
}

function extracted(): string {
  const outcome = extract(document, {
    url: "https://example.com/archives/quiet-week",
    minWordCount: 40,
  });
  return [outcome.result.title, ...outcome.result.sections.map((section) => section.markdown)].join(
    "\n",
  );
}

const LABEL_OP: Lens["ops"][number] = {
  id: "op-label",
  kind: "label",
  region: "article",
  note: "label the article",
  text: MODEL_SENTENCE,
};

describe("lens nodes and the extraction pipeline", () => {
  beforeEach(() => {
    document.body.innerHTML = PAGE;
  });

  it("keeps a model-authored label out of the extracted document", () => {
    apply([LABEL_OP]);

    // In the page, at the top of the article — which is the content element the
    // extractor keeps, so this is the leak's shortest path.
    expect(document.querySelector("zentic-lens-label")?.textContent).toBe(MODEL_SENTENCE);

    const markdown = extracted();
    expect(markdown).not.toContain(MODEL_SENTENCE);
    expect(markdown).not.toContain("Zentic wrote this");
    // The page's own prose is untouched: the point is to remove our furniture, not
    // to make a lensed page extract worse than an unlensed one.
    expect(markdown).toContain("The cataloguing project has been running");

    // Stripped on a clone, never from the page. Invariant 6 says the original is
    // hidden and not destroyed, and that covers what a lens added to it.
    expect(document.querySelector("zentic-lens-label")).not.toBeNull();
  });

  it("keeps a harvested block out of the extracted document", () => {
    // Harvested from the nav and rendered into the article, which is the ordinary
    // shape of "collect the headlines and put them at the top". The values are the
    // page's own text, but this arrangement of them is ours.
    apply([
      {
        id: "op-harvest",
        kind: "harvest",
        region: "elsewhere",
        note: "collect the further reading",
        harvest: {
          itemSelector: ":scope > a",
          fields: [
            { name: "text", selector: ":scope", attribute: "text" },
            { name: "href", selector: ":scope", attribute: "href" },
          ],
          into: "links",
        },
      },
      {
        id: "op-insert",
        kind: "insert",
        region: "elsewhere",
        note: "put the list at the top",
        target: "article",
        bucket: "links",
        index: 0,
      },
    ]);

    expect(document.querySelector("zentic-lens-insert")?.textContent).toContain(HARVESTED);
    expect(extracted()).not.toContain(HARVESTED);
  });

  it("offers no lens node as a skeleton candidate", () => {
    // A recipe inferred from a page that includes our own boxes is a recipe for
    // our furniture — and the skeleton is the one artefact of a page read that is
    // allowed to reach a model at all.
    apply([LABEL_OP]);

    const skeleton = buildSkeleton(document, {
      url: "https://example.com/archives/quiet-week",
      nodeLimit: 200,
    });

    expect(skeleton.nodes.some((node) => node.tag.startsWith("zentic-"))).toBe(false);
    expect(skeleton.nodes.some((node) => node.path.includes("zentic-"))).toBe(false);
  });
});
