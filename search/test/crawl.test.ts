import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { Store } from "../src/store.js";

// The store is what makes a crawl resumable, so these are about the states a URL
// can be left in when something goes wrong halfway.

describe("store", () => {
  let dir: string;
  let store: Store;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "loam-"));
    store = new Store(join(dir, "test.db"));
  });

  afterEach(() => {
    store.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it("never queues the same url twice", () => {
    expect(store.enqueue("https://a.example/x", "a.example", 0, "seed")).toBe(true);
    expect(store.enqueue("https://a.example/x", "a.example", 1, "other")).toBe(false);
    expect(store.pendingCount()).toBe(1);
  });

  it("stops handing out a url once it is marked", () => {
    store.enqueue("https://a.example/x", "a.example", 0, "seed");
    expect(store.nextBatch(10)).toHaveLength(1);
    store.markFrontier("https://a.example/x", "done");
    expect(store.nextBatch(10)).toHaveLength(0);
    expect(store.pendingCount()).toBe(0);
  });

  /// The poison-pill case. A page that throws must end up marked, not left pending
  /// — otherwise every resumed crawl reaches it and dies at the same point, and a
  /// crawl advertised as resumable can never get past page N.
  it("a rolled-back page can still be marked failed", () => {
    store.enqueue("https://bad.example/x", "bad.example", 0, "seed");

    expect(() =>
      store.transaction(() => {
        store.savePage({
          url: "https://bad.example/x",
          host: "bad.example",
          title: "t",
          text: "body",
          wordCount: 10,
          archetype: "article",
          confidence: 0.9,
        });
        throw new Error("boom");
      }),
    ).toThrow("boom");

    // The write rolled back...
    expect(store.pageCount()).toBe(0);
    // ...and the mark, made outside the transaction, survives.
    store.markFrontier("https://bad.example/x", "failed", "threw: boom");
    expect(store.pendingCount()).toBe(0);
    expect(store.nextBatch(10)).toHaveLength(0);
  });

  it("a failed transaction leaves the connection usable", () => {
    // A rollback that left the connection inside a transaction would make every
    // later write fail, turning one bad page into a dead crawl by another route.
    try {
      store.transaction(() => {
        throw new Error("boom");
      });
    } catch {
      // expected
    }
    expect(() => store.enqueue("https://ok.example/", "ok.example", 0, "seed")).not.toThrow();
    store.transaction(() => store.addLink("https://a/", "https://b/"));
    expect(store.allLinks()).toHaveLength(1);
  });

  it("counts only completed pages against a host's cap", () => {
    for (let i = 0; i < 3; i += 1) {
      store.enqueue(`https://a.example/${i}`, "a.example", 0, "seed");
    }
    expect(store.pagesForHost("a.example")).toBe(0);
    store.markFrontier("https://a.example/0", "done");
    store.markFrontier("https://a.example/1", "skipped", "robots");
    // Skipped pages were never fetched into the index, so they must not consume
    // the host's budget.
    expect(store.pagesForHost("a.example")).toBe(1);
  });

  it("survives a reopen with the frontier intact", () => {
    store.enqueue("https://a.example/x", "a.example", 0, "seed");
    store.markFrontier("https://a.example/x", "done");
    store.enqueue("https://a.example/y", "a.example", 1, "seed");
    const path = join(dir, "test.db");
    store.close();

    store = new Store(path);
    expect(store.pendingCount()).toBe(1);
    expect(store.nextBatch(10)[0]?.url).toBe("https://a.example/y");
  });
});
