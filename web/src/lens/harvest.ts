import { safeItemSelector, safeSelector } from "./selectors.js";
import type { HarvestField, HarvestSpec } from "../wire.js";

// Harvest and insert: pulling values out of repeated items and rendering them
// somewhere else on the page.
//
// This is the one part of the lens engine that touches real page text, and the
// rule that makes that safe is that the text never goes anywhere. A harvest reads
// characters, keeps them in a `HarvestStore` that lives and dies with the page,
// and writes them back into the same document through `textContent`. Nothing
// harvested is ever put in a `LensReport`, and nothing harvested crosses the
// bridge — invariant 7 and the lens privacy contract both depend on that, so the
// store deliberately has no serialiser.
//
// The rendering side never builds markup from strings. Every node is created and
// every value assigned through `textContent`, so a page whose headings contain
// `<script>` produces a text node saying `<script>` rather than a script. There
// is no sanitiser here because there is nothing to sanitise.

/** What one harvested item became: field name → value, in spec order. */
export interface HarvestedRecord {
  fields: Record<string, string>;
}

/** Marks every node this engine put into the page, so `clear()` can find them
 * even if the journal was lost — and so the catalog never offers one as a region. */
export const LENS_NODE_ATTR = "data-zentic-lens";

/** The same mark, as a selector. Extraction and the DOM skeleton both step around
 * it: a label the model wrote and a list we rendered are Zentic's own furniture,
 * not the page's content, and neither belongs in an `ExtractionResult` that a
 * rewrite might then re-voice. */
export const LENS_NODE_SELECTOR = `[${LENS_NODE_ATTR}]`;

/**
 * Named buckets of harvested values for one page load.
 *
 * Buckets are named by the `harvest` op (`HarvestSpec.into`) and read by an
 * `insert` op, which is what lets "collect every headline and put the list at the
 * top" be two independent ops that can drift independently.
 *
 * The element → fields map is a `WeakMap` on purpose: a feed that scrolls for an
 * hour would otherwise pin every card it ever showed. It exists so a `reorder`
 * sorting on `harvestedField` can look up what an item harvested to, without
 * re-reading the DOM.
 */
export class HarvestStore {
  private readonly buckets = new Map<string, HarvestedRecord[]>();
  private readonly byElement = new WeakMap<Element, Record<string, string>>();

  put(bucket: string, records: HarvestedRecord[], elements: Element[]): void {
    this.buckets.set(bucket, records);
    for (const [index, element] of elements.entries()) {
      const record = records[index];
      if (record) this.byElement.set(element, record.fields);
    }
  }

  get(bucket: string): HarvestedRecord[] | undefined {
    return this.buckets.get(bucket);
  }

  /** Value a previously harvested element produced for one field, for sorting. */
  fieldOf(element: Element, field: string): string | undefined {
    return this.byElement.get(element)?.[field];
  }

  clear(): void {
    this.buckets.clear();
  }
}

/**
 * Read one field out of one item.
 *
 * Attributes are read with `getAttribute`, not through the reflected property,
 * because `element.href` resolves to an absolute URL while the page's own markup
 * may hold a relative one — and a harvested value is shown next to the page's own
 * links, where the two forms sitting side by side looks like a bug.
 *
 * The selector goes through the same shape gate every other selector in a lens
 * does. It reaches no stylesheet, so nothing here is exploitable today — but a
 * field selector crosses the bridge exactly as an item selector does, and one
 * validated path with one unvalidated path beside it is how the next caller ends
 * up using the wrong one.
 */
function readField(item: Element, field: HarvestField): string {
  const selector = safeSelector(field.selector);
  if (!selector) return "";

  let source: Element | null = item;
  if (selector !== ":scope") {
    try {
      source = item.querySelector(selector);
    } catch {
      return "";
    }
  }
  if (!source) return "";

  switch (field.attribute) {
    case "text":
      return (source.textContent ?? "").replace(/\s+/g, " ").trim();
    case "href":
    case "src":
    case "alt":
    case "title":
      return (source.getAttribute(field.attribute) ?? "").trim();
    default:
      // An unknown attribute name is a lens from a future schema, or a hand-edited
      // `Lenses.json`. Reading nothing is the honest answer; guessing is not.
      return "";
  }
}

export interface HarvestOutcome {
  records: HarvestedRecord[];
  elements: Element[];
  /** True when the item run was longer than the per-pass budget allowed. */
  truncated: boolean;
}

/** Collect `spec.fields` from every item under `region`, up to `limit` items. */
export function harvestItems(region: Element, spec: HarvestSpec, limit: number): HarvestOutcome {
  const selector = safeItemSelector(spec.itemSelector);
  if (!selector) return { records: [], elements: [], truncated: false };

  let found: Element[];
  try {
    found = Array.from(region.querySelectorAll(selector));
  } catch {
    return { records: [], elements: [], truncated: false };
  }

  const elements = found.slice(0, Math.max(0, limit));
  const records = elements.map((item) => {
    const fields: Record<string, string> = {};
    for (const field of spec.fields) fields[field.name] = readField(item, field);
    return { fields };
  });

  return { records, elements, truncated: found.length > elements.length };
}

/**
 * Render a bucket as a block ready to be inserted into the page.
 *
 * Structure is flat and predictable — a row per record, a cell per field, the
 * field name on a `data-field` attribute — because the only styling available is
 * the site's own. Anything that looks like a link becomes one, since a harvested
 * list of headlines that cannot be clicked is a screenshot.
 */
export function buildInsertion(
  doc: Document,
  bucket: string,
  records: HarvestedRecord[],
  limit: number,
): Element {
  const block = doc.createElement("zentic-lens-insert");
  block.setAttribute(LENS_NODE_ATTR, "insert");
  block.setAttribute("data-bucket", bucket);

  for (const record of records.slice(0, Math.max(0, limit))) {
    const row = doc.createElement("zentic-lens-row");
    const href = record.fields["href"];

    for (const [name, value] of Object.entries(record.fields)) {
      if (name === "href") continue;
      if (!value) continue;

      // A row with an href becomes one link, so the whole row is clickable rather
      // than only the field that happened to be named "text".
      const cell = href ? doc.createElement("a") : doc.createElement("span");
      if (href) cell.setAttribute("href", href);
      cell.setAttribute("data-field", name);
      cell.textContent = value;
      row.appendChild(cell);
    }

    if (row.childNodes.length > 0) block.appendChild(row);
  }

  return block;
}
