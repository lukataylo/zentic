import { DatabaseSync } from "node:sqlite";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

/**
 * Everything the crawl and the index live in.
 *
 * SQLite because a 50,000-page crawl is not something to hold in memory and not
 * something to lose to a `^C` an hour in. `node:sqlite` because it ships with the
 * runtime — a search engine that fails to install because a native module will not
 * compile is a search engine nobody runs.
 *
 * The schema is written so a crawl is **resumable**: the frontier is a table, not a
 * queue in memory, so the process can be killed at any point and restarted without
 * refetching what it already has.
 */
export class Store {
  private readonly db: DatabaseSync;

  constructor(path: string) {
    mkdirSync(dirname(path), { recursive: true });
    this.db = new DatabaseSync(path);
    // WAL so a `serve` process can read while a `crawl` writes.
    this.db.exec("pragma journal_mode = wal");
    this.db.exec("pragma synchronous = normal");
    this.migrate();
  }

  private migrate(): void {
    this.db.exec(`
      -- The frontier. One row per URL ever considered, so this doubles as the
      -- "have I seen this?" set — a separate visited set would be a second thing
      -- to keep in sync.
      create table if not exists frontier (
        url        text primary key,
        host       text not null,
        depth      integer not null,
        source     text not null,
        -- pending | done | skipped | failed
        state      text not null default 'pending',
        reason     text,
        queued_at  integer not null
      );
      create index if not exists frontier_state on frontier(state, depth);
      create index if not exists frontier_host on frontier(host);

      -- A page worth keeping. Only extracted content is ever stored: no raw HTML,
      -- so no advertising markup can reach the index even by accident.
      create table if not exists page (
        url         text primary key,
        host        text not null,
        title       text not null,
        text        text not null,
        word_count  integer not null,
        archetype   text not null,
        confidence  real not null,
        lang        text,
        byline      text,
        published   text,
        fetched_at  integer not null,
        rank        real not null default 0
      );
      create index if not exists page_host on page(host);
      create index if not exists page_rank on page(rank desc);

      -- The link graph, for PageRank. Kept even when the destination was never
      -- fetched: a link to a page we skipped still says something about the page
      -- that made it.
      create table if not exists link (
        src text not null,
        dst text not null,
        primary key (src, dst)
      );
      create index if not exists link_dst on link(dst);

      -- Inverted index. One row per (term, page).
      create table if not exists posting (
        term  text not null,
        url   text not null,
        tf    integer not null,
        -- Term appears in the title. Cheap, and title hits matter far more.
        in_title integer not null default 0,
        primary key (term, url)
      );
      create index if not exists posting_term on posting(term);

      create table if not exists meta (
        key   text primary key,
        value text not null
      );
    `);
  }

  // MARK: - Frontier

  /** Add a URL if it has never been seen. Returns whether it was new. */
  enqueue(url: string, host: string, depth: number, source: string): boolean {
    const result = this.db
      .prepare(
        `insert or ignore into frontier (url, host, depth, source, queued_at)
         values (?, ?, ?, ?, ?)`,
      )
      .run(url, host, depth, source, Date.now());
    return result.changes > 0;
  }

  /**
   * The next batch to fetch, shallowest first and spread across hosts.
   *
   * Breadth-first matters here: depth-first would exhaust one site before touching
   * the next, and a crawl interrupted halfway would have indexed one blog rather
   * than a shallow slice of a thousand.
   */
  nextBatch(limit: number): { url: string; host: string; depth: number; source: string }[] {
    return this.db
      .prepare(
        `select url, host, depth, source from frontier
         where state = 'pending'
         order by depth asc, queued_at asc
         limit ?`,
      )
      .all(limit) as { url: string; host: string; depth: number; source: string }[];
  }

  markFrontier(url: string, state: "done" | "skipped" | "failed", reason?: string): void {
    this.db
      .prepare(`update frontier set state = ?, reason = ? where url = ?`)
      .run(state, reason ?? null, url);
  }

  pendingCount(): number {
    const row = this.db
      .prepare(`select count(*) as n from frontier where state = 'pending'`)
      .get() as { n: number };
    return row.n;
  }

  pagesForHost(host: string): number {
    const row = this.db
      .prepare(`select count(*) as n from frontier where host = ? and state = 'done'`)
      .get(host) as { n: number };
    return row.n;
  }

  // MARK: - Pages

  savePage(page: {
    url: string;
    host: string;
    title: string;
    text: string;
    wordCount: number;
    archetype: string;
    confidence: number;
    lang?: string | undefined;
    byline?: string | undefined;
    published?: string | undefined;
  }): void {
    this.db
      .prepare(
        `insert or replace into page
         (url, host, title, text, word_count, archetype, confidence, lang, byline, published, fetched_at)
         values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        page.url,
        page.host,
        page.title,
        page.text,
        page.wordCount,
        page.archetype,
        page.confidence,
        page.lang ?? null,
        page.byline ?? null,
        page.published ?? null,
        Date.now(),
      );
  }

  addLink(src: string, dst: string): void {
    this.db.prepare(`insert or ignore into link (src, dst) values (?, ?)`).run(src, dst);
  }

  pageCount(): number {
    return (this.db.prepare(`select count(*) as n from page`).get() as { n: number }).n;
  }

  // MARK: - Index

  addPostings(url: string, postings: { term: string; tf: number; inTitle: boolean }[]): void {
    const insert = this.db.prepare(
      `insert or replace into posting (term, url, tf, in_title) values (?, ?, ?, ?)`,
    );
    for (const posting of postings) {
      insert.run(posting.term, url, posting.tf, posting.inTitle ? 1 : 0);
    }
  }

  clearPostings(url: string): void {
    this.db.prepare(`delete from posting where url = ?`).run(url);
  }

  // MARK: - Ranking support

  allLinks(): { src: string; dst: string }[] {
    return this.db.prepare(`select src, dst from link`).all() as { src: string; dst: string }[];
  }

  allPageUrls(): string[] {
    return (this.db.prepare(`select url from page`).all() as { url: string }[]).map((r) => r.url);
  }

  setRanks(ranks: Map<string, number>): void {
    const update = this.db.prepare(`update page set rank = ? where url = ?`);
    this.db.exec("begin");
    for (const [url, rank] of ranks) update.run(rank, url);
    this.db.exec("commit");
  }

  // MARK: - Query

  postingsFor(term: string): { url: string; tf: number; inTitle: number }[] {
    return this.db
      .prepare(`select url, tf, in_title as inTitle from posting where term = ?`)
      .all(term) as { url: string; tf: number; inTitle: number }[];
  }

  pageMeta(urls: string[]): Map<string, PageMeta> {
    if (urls.length === 0) return new Map();
    const placeholders = urls.map(() => "?").join(",");
    const rows = this.db
      .prepare(
        `select url, host, title, word_count as wordCount, rank, byline, published, text
         from page where url in (${placeholders})`,
      )
      .all(...urls) as unknown as PageMeta[];
    return new Map(rows.map((row) => [row.url, row]));
  }

  averageWordCount(): number {
    const row = this.db.prepare(`select avg(word_count) as avg from page`).get() as {
      avg: number | null;
    };
    return row.avg ?? 1;
  }

  stats(): {
    pages: number;
    hosts: number;
    links: number;
    terms: number;
    pending: number;
    topHosts: { host: string; n: number }[];
  } {
    const one = (sql: string) => (this.db.prepare(sql).get() as { n: number }).n;
    return {
      pages: one(`select count(*) as n from page`),
      hosts: one(`select count(distinct host) as n from page`),
      links: one(`select count(*) as n from link`),
      terms: one(`select count(distinct term) as n from posting`),
      pending: one(`select count(*) as n from frontier where state = 'pending'`),
      topHosts: this.db
        .prepare(`select host, count(*) as n from page group by host order by n desc limit 15`)
        .all() as { host: string; n: number }[],
    };
  }

  meta(key: string): string | undefined {
    const row = this.db.prepare(`select value from meta where key = ?`).get(key) as
      | { value: string }
      | undefined;
    return row?.value;
  }

  setMeta(key: string, value: string): void {
    this.db.prepare(`insert or replace into meta (key, value) values (?, ?)`).run(key, value);
  }

  transaction(work: () => void): void {
    this.db.exec("begin");
    try {
      work();
      this.db.exec("commit");
    } catch (error) {
      this.db.exec("rollback");
      throw error;
    }
  }

  close(): void {
    this.db.close();
  }
}

export interface PageMeta {
  url: string;
  host: string;
  title: string;
  wordCount: number;
  rank: number;
  byline: string | null;
  published: string | null;
  text: string;
}
