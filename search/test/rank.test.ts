import { describe, expect, it } from "vitest";

import { bm25, combine, pageRank, tokenise, type PostingList } from "../src/rank.js";
import { snippet } from "../src/query.js";
import { parseRobots } from "../src/fetcher.js";
import { isCrawlable, parseFeed } from "../src/seeds.js";

// Tests against the ways this can be wrong in a way nobody notices: a ranking that
// silently prefers the wrong thing still returns results, and a crawler that
// silently ignores robots.txt still crawls.

describe("pageRank", () => {
  it("gives the most-linked page the highest rank", () => {
    const ranks = pageRank({
      nodes: ["a", "b", "c", "hub"],
      edges: [
        { src: "a", dst: "hub" },
        { src: "b", dst: "hub" },
        { src: "c", dst: "hub" },
        { src: "a", dst: "b" },
      ],
    });
    expect(ranks.get("hub")).toBe(1);
    expect(ranks.get("hub")!).toBeGreaterThan(ranks.get("b")!);
    expect(ranks.get("b")!).toBeGreaterThan(ranks.get("c")!);
  });

  it("does not leak rank through pages with no outbound links", () => {
    // The dangling-node bug: without redistribution the totals decay towards zero
    // every iteration and the whole vector becomes meaningless. It still *returns*
    // numbers, which is why this needs asserting rather than eyeballing.
    const ranks = pageRank({
      nodes: ["a", "b", "dead"],
      edges: [
        { src: "a", dst: "dead" },
        { src: "b", dst: "dead" },
      ],
    });
    for (const value of ranks.values()) {
      expect(value).toBeGreaterThan(0);
      expect(Number.isFinite(value)).toBe(true);
    }
  });

  it("ignores links to pages that were never indexed", () => {
    // Counting an outside link in the out-degree would dilute every real link on
    // the page, so a page linking out heavily would quietly stop endorsing anything.
    const inside = pageRank({
      nodes: ["a", "b"],
      edges: [{ src: "a", dst: "b" }],
    });
    const withOutside = pageRank({
      nodes: ["a", "b"],
      edges: [
        { src: "a", dst: "b" },
        { src: "a", dst: "https://elsewhere.example/never-fetched" },
      ],
    });
    expect(withOutside.get("b")).toBeCloseTo(inside.get("b")!, 10);
  });

  /// The pathology this caught on the first real crawl: two posts on one blog
  /// linking to each other form a closed loop with nowhere for rank to escape, so
  /// they absorb it. Eight pages came out tied at exactly the maximum, every one of
  /// them half of a same-site pair, above genuinely well-cited essays.
  it("does not let a site endorse itself", () => {
    const ranks = pageRank({
      nodes: [
        "https://blog.example/a",
        "https://blog.example/b",
        "https://elsewhere.example/cited",
      ],
      edges: [
        // A mutual pair on one host — navigation, not endorsement.
        { src: "https://blog.example/a", dst: "https://blog.example/b" },
        { src: "https://blog.example/b", dst: "https://blog.example/a" },
        // One genuine citation across sites.
        { src: "https://blog.example/a", dst: "https://elsewhere.example/cited" },
      ],
    });
    expect(ranks.get("https://elsewhere.example/cited")).toBe(1);
    expect(ranks.get("https://blog.example/a")!).toBeLessThan(1);
    expect(ranks.get("https://blog.example/b")!).toBeLessThan(1);
  });

  it("treats www and the bare host as one site", () => {
    const ranks = pageRank({
      nodes: ["https://www.blog.example/a", "https://blog.example/b"],
      edges: [{ src: "https://www.blog.example/a", dst: "https://blog.example/b" }],
    });
    // The link was dropped as internal, so both are danglers and share rank evenly.
    expect(ranks.get("https://blog.example/b")).toBeCloseTo(
      ranks.get("https://www.blog.example/a")!,
      10,
    );
  });

  it("survives an empty graph and a self-link", () => {
    expect(pageRank({ nodes: [], edges: [] }).size).toBe(0);
    const selfish = pageRank({ nodes: ["a", "b"], edges: [{ src: "a", dst: "a" }] });
    expect([...selfish.values()].every(Number.isFinite)).toBe(true);
  });
});

describe("bm25", () => {
  const lists = (postings: PostingList[]) => postings;

  it("prefers a rare term over a common one", () => {
    const common: PostingList = {
      term: "the",
      documentFrequency: 900,
      postings: [{ url: "a", tf: 20, inTitle: 0 }],
    };
    const rare: PostingList = {
      term: "monotreme",
      documentFrequency: 2,
      postings: [{ url: "b", tf: 3, inTitle: 0 }],
    };
    const scores = bm25(lists([common, rare]), 1000, 500, () => 500);
    const byUrl = new Map(scores.map((s) => [s.url, s.score]));
    expect(byUrl.get("b")!).toBeGreaterThan(byUrl.get("a")!);
  });

  it("saturates term frequency instead of rewarding repetition", () => {
    const once: PostingList = {
      term: "x",
      documentFrequency: 10,
      postings: [{ url: "a", tf: 1, inTitle: 0 }],
    };
    const many: PostingList = {
      term: "x",
      documentFrequency: 10,
      postings: [{ url: "b", tf: 50, inTitle: 0 }],
    };
    const [a] = bm25(lists([once]), 100, 400, () => 400);
    const [b] = bm25(lists([many]), 100, 400, () => 400);
    // More is better, but nowhere near fifty times better — otherwise keyword
    // stuffing wins every query.
    expect(b!.score).toBeGreaterThan(a!.score);
    expect(b!.score).toBeLessThan(a!.score * 4);
  });

  it("weights a title hit above the same term in the body", () => {
    const list: PostingList = {
      term: "x",
      documentFrequency: 10,
      postings: [
        { url: "body", tf: 3, inTitle: 0 },
        { url: "title", tf: 3, inTitle: 1 },
      ],
    };
    const scores = new Map(bm25(lists([list]), 100, 400, () => 400).map((s) => [s.url, s.score]));
    expect(scores.get("title")!).toBeGreaterThan(scores.get("body")!);
  });
});

describe("combine", () => {
  it("lets authority reorder relevant pages but never create relevance", () => {
    // The property that stops well-linked homepages colonising every result set.
    expect(combine(0, 1)).toBe(0);
    expect(combine(1, 1)).toBeGreaterThan(combine(1, 0));
  });

  it("cannot let authority overturn a large relevance gap", () => {
    const relevantUnlinked = combine(10, 0);
    const marginalFamous = combine(4, 1);
    expect(relevantUnlinked).toBeGreaterThan(marginalFamous);
  });
});

describe("tokenise", () => {
  it("drops stopwords and keeps technical tokens intact", () => {
    expect(tokenise("The rise of C++ and F# in the industry")).toEqual([
      "rise",
      "c++",
      "f#",
      "industry",
    ]);
  });

  it("folds accents and case", () => {
    expect(tokenise("Naïve BAYES")).toEqual(["naive", "bayes"]);
  });
});

describe("snippet", () => {
  it("shows the first match, not the first sentence", () => {
    const text = `${"filler ".repeat(80)}the monotreme in question was a platypus`;
    expect(snippet(text, ["monotreme"])).toContain("monotreme");
    expect(snippet(text, ["monotreme"]).startsWith("…")).toBe(true);
  });

  it("falls back to the opening when nothing matched", () => {
    expect(snippet("a short page", ["absent"])).toBe("a short page");
  });
});

describe("robots.txt", () => {
  it("obeys a disallow that applies to everyone", () => {
    const rules = parseRobots("User-agent: *\nDisallow: /private");
    expect(rules.disallow).toContain("/private");
  });

  it("ignores rules addressed to a different crawler", () => {
    const rules = parseRobots("User-agent: EvilBot\nDisallow: /");
    expect(rules.disallow).toEqual([]);
  });

  it("treats an empty disallow as permission, not as a block on everything", () => {
    // `Disallow:` with no value means "nothing is disallowed". Pushing "" would
    // make every path start with it and silently halt the whole crawl.
    const rules = parseRobots("User-agent: *\nDisallow:");
    expect(rules.disallow).toEqual([]);
  });

  it("truncates a wildcard pattern to its literal prefix", () => {
    // Erring towards not fetching is the right direction to err.
    const rules = parseRobots("User-agent: *\nDisallow: /search/*/results");
    expect(rules.disallow).toEqual(["/search/"]);
  });

  it("reads a crawl delay", () => {
    expect(parseRobots("User-agent: *\nCrawl-delay: 10").crawlDelay).toBe(10);
  });
});

describe("feed parsing", () => {
  it("reads an Atom entry", () => {
    const [entry] = parseFeed(
      `<feed><entry><title>Hello &amp; goodbye</title>
       <link href="https://example.com/post" /></entry></feed>`,
    );
    expect(entry).toEqual({ link: "https://example.com/post", title: "Hello & goodbye" });
  });

  it("reads an RSS item with a CDATA title", () => {
    const [entry] = parseFeed(
      `<rss><item><title><![CDATA[Post title]]></title>
       <link>https://example.com/a</link></item></rss>`,
    );
    expect(entry?.title).toBe("Post title");
    expect(entry?.link).toBe("https://example.com/a");
  });

  /// Reddit's `<link>` is the comment thread even for a link post. Without pulling
  /// the `[link]` anchor out of the body, every Reddit seed is a reddit.com URL the
  /// crawler then refuses, and the source silently contributes nothing.
  it("prefers the article over the discussion in a Reddit entry", () => {
    const [entry] = parseFeed(
      `<feed><entry><title>Stack Overflow drops</title>
       <content type="html">&lt;a href=&quot;https://ppc.land/article&quot;&gt;[link]&lt;/a&gt;
       &lt;a href=&quot;https://www.reddit.com/r/programming/comments/x/&quot;&gt;[comments]&lt;/a&gt;</content>
       <link href="https://www.reddit.com/r/programming/comments/x/" /></entry></feed>`,
    );
    expect(entry?.outbound).toBe("https://ppc.land/article");
    expect(entry?.link).toContain("reddit.com");
  });

  it("leaves a self post with no outbound link", () => {
    const [entry] = parseFeed(
      `<feed><entry><title>Ask</title>
       <content type="html">just some text</content>
       <link href="https://www.reddit.com/r/x/comments/y/" /></entry></feed>`,
    );
    expect(entry?.outbound).toBeUndefined();
  });
});

describe("crawlable hosts", () => {
  it("never crawls the aggregators the seeds came from", () => {
    expect(isCrawlable("news.ycombinator.com")).toBe(false);
    expect(isCrawlable("old.reddit.com")).toBe(false);
    expect(isCrawlable("www.reddit.com")).toBe(false);
  });

  it("never crawls an ad or tracking host", () => {
    // The index has no advertising in it. This is the last line of that: extraction
    // stops ad copy arriving through a page, and this stops one being a destination.
    for (const host of [
      "doubleclick.net",
      "pagead2.googlesyndication.com",
      "analytics.google-analytics.com",
      "taboola.com",
      "cdn.outbrain.com",
    ]) {
      expect(isCrawlable(host), host).toBe(false);
    }
  });

  it("crawls ordinary blogs, including subdomains", () => {
    for (const host of ["danluu.com", "simonwillison.net", "someone.substack.com"]) {
      expect(isCrawlable(host), host).toBe(true);
    }
  });

  it("does not block a host that merely ends with a banned name as a substring", () => {
    // `notreddit.com` is not `reddit.com`. Matching on a bare `endsWith` would ban it.
    expect(isCrawlable("notreddit.com")).toBe(true);
    expect(isCrawlable("myx.com")).toBe(true);
  });
});
