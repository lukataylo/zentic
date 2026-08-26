# Zentic

A browser where the clean version of a page **is** the page you land on.

Other browsers have a reader mode. You have to remember it's there, press it on every
page, and it falls apart on anything that isn't a plain article.

Zentic turns that around. Ads and trackers are gone, the article is re-set in its own
type, and it's all finished before the page appears. The site's real page is always one
keystroke away (`⌘\`).

macOS and iOS. Swift, and the same rendering engine as Safari — no browser fork to
maintain, and no security backlog of its own.

![Zentic showing swift.org restructured into its reading view](docs/screenshot.png)

*swift.org, restructured. Sidebar tabs on frosted glass, breadcrumb address bar,
and the five-stop level rail at top right.*

---

## Four things it can do to a page

| | What it does | What it costs |
|---|---|---|
| **Strip** | Blocks ads and trackers, answers cookie walls | Nothing — WebKit applies the rules before the page loads |
| **Restructure** | Pulls the real article out and re-renders it in Zentic's type | Nothing — no model involved, ever |
| **Rewrite** | Re-voices the prose | One model call, only when you ask |
| **Remodel** | A saved *lens* that hides, moves, restyles or filters parts of a site | One model call to write it. **None on every visit after** |

The important part: the first two need **no AI at all**. That is the common path, and
it is free, instant, offline and private. AI shows up only where you ask for it, and
even then the expensive half is paid once and remembered.

### Restructure and remodel sound alike. They're opposites.

**Restructure replaces the page.** Zentic reads the article, throws the site's layout
away and draws its own. Lovely for an essay. Ruinous for a mail client — which is why
it is forbidden on apps.

**Remodel leaves the page alone and rearranges it.** The site's own page stays live
and clickable; a lens only hides, moves, restyles or filters parts of it.

So the layer that is banned on apps and the layer that is *most useful* on apps are
different layers. "YouTube without the suggestions rail" works because the real player
is still the real player. Restructuring YouTube never will.

## Lenses

A lens is a change you describe once and keep. Press `⌥⌘L`, point at something on the
page or say what you want — *hide the suggestions rail*, *drop anything about crypto* —
and Zentic shows you which boxes it picked before it changes anything. Save it, and
every later visit applies it with no model call at all.

Lenses work where the reader can't: apps. They are checked every time and honest about
it — if a site redesigns and a lens stops matching, the badge says so and offers to
re-fit it rather than quietly doing nothing.

## One control

These used to be scattered across unrelated buttons, and blocking had no control at
all — so the question that actually matters on any page had nowhere to be answered:
*how much is this browser changing what I'm looking at?*

That is now a single five-stop rail in the toolbar, per site, with defaults inferred
per page rather than guessed once.

| Stop | What it does |
|---|---|
| **Original** | The site exactly as it shipped |
| **Clean** | Ads and trackers blocked, and the cookie wall answered; the site's own layout otherwise untouched |
| **Calm** | Also the interstitials, the chum and the sticky furniture |
| **Reader** | Rebuilt in Zentic's type and spacing — every word still the publisher's |
| **Rewritten** | Also re-voiced by a model. Badged, gated, one keystroke from the original |

The order matters. Each stop does everything the one below it does, and one thing more
— which is what makes a slider an honest control for it, rather than five buttons that
happen to sit in a row. Blocking and the reader aren't separate switches you could set
against each other, because two controls that can disagree are two controls that will.

Moving between Calm, Reader and Rewritten happens instantly. Changing what is *blocked*
reloads the page, because the browser decides what to block as a page loads and can't
un-send a request already on its way. The rail tells you which is which before you
click.

**It works out the default per page, not per site.** One site is rarely one kind of
page: a company's front door is marketing and its blog is prose. So Zentic decides
where to start from what the page actually turned out to be. You can leave a site on
Automatic, pin it to a level, or cap it (*never above Calm*).

Dragging the slider changes **this page only** — a reload keeps it, the next page
doesn't. Making a choice stick is a separate, deliberate action in the rail's menu, so
you can look at something without committing to it.

**Rewritten is persistent, and it is the one stop that carries consent.** Pinning a
site to it is standing consent for that origin — its pages are re-voiced on every
visit, because a control reading "Rewritten" over prose nobody rewrote is a control
lying about the page. It is never reached automatically: only an explicit pin gets
you there, and news, medical, legal and financial pages still ask every time.

**Design is a separate axis.** Presentation is lossless and reversible; tone changes
what the words say. Conflating them would mean crossing a consent boundary while
picking a font, so themes live in their own menu — six built-in looks, or describe
one and a model returns validated tokens, never CSS.

The prompt opens with suggestions drawn from what the page turned out to be, because
a blank field is a bad way to ask for a design: a reference page wants a tight
measure and legible code, an essay wants the opposite, and neither wants what the
other wants. Pick one and edit it, or ignore them and write your own.

## Performance

Measured against Safari on the same machine, same 30 origins, both from cold and
both allowed to settle. Reproduce with `ZenticMac --stress 30`.

| | Zentic | Safari |
|---|---|---|
| Warm launch → window | **≈430 ms** | ≈2550 ms |
| RAM, 30 sites, settled | **530 MB** | ≈1096 MB |
| Helper processes | **15** | ≈37 |

Zentic wins on memory because it suspends: beyond `Budget.maxLiveWebViews` (8),
least-recently-used tabs drop their web view and keep a snapshot plus restorable
state. That is a real trade — Safari keeps more tabs warm, so switching to one of
those is instant where a suspended Zentic tab reloads. Page rendering itself is
WKWebView, so per-page speed *is* Safari's; the wins are in the shell.

## Build

```sh
swift build && swift test          # Swift: 462 tests
cd web && npm run check            # typecheck + 410 tests + the 80-page corpus
swift run ZenticMac                # run it
```

The built JavaScript is committed so an Xcode build never needs Node. After changing
anything in `web/src/`, run `npm run build` and commit the result — **in that order**,
because SwiftPM copies the built file in at build time.

There are two bundles. The main one is injected into every page; the lens editor is a
second one, delivered only when you press `⌥⌘L`, because it cannot run until you do.

## Keyboard

| | |
|---|---|
| `⌥⌘[` / `⌥⌘]` | less / more — one stop along the level rail |
| `⌘\` | the site's own page, and back |
| `⌘⇧S` | simplify this page |
| `⌥⌘D` | describe a look for this site |
| `⌥⌘L` | make or edit a lens for this site |
| `⌥⌘S` / `⌥⌘T` | collapse the sidebar / toolbar to a hover-reveal edge |
| `⌘⇧F` | focus mode |
| `⌘K` | command palette |
| `⌥⌘B` | cycle the background glass |

## Invariants

These are not style preferences. Each is load-bearing, and each has a test.

1. **The page always becomes visible.** The reader hides the document at
   `document-start` to avoid a flash of the original, so it must guarantee a
   reveal. `Budget.revealFailsafe` (1500 ms) is a hard ceiling. A white screen is
   far worse than a flash.
2. **Never restructure an app — but you may remodel one.** When Zentic isn't sure
   what a page is, it leaves it alone. Mangling someone's mail client costs their
   trust; declining to restructure an article costs nothing. A *lens* is allowed
   everywhere, because it leaves the site's own page live and only rearranges it.
3. **Code, tables, math and embeds are never sent to a model.** A model asked to
   restyle a code block renames identifiers; asked to restyle a table it drops
   cells.
4. **What a model sees of a page contains none of its words.** When Zentic needs a
   model's help understanding a page's *shape*, it sends the structure — tag names,
   sizes, positions, and how *long* the text is — never the text itself. What you're
   reading stays on your machine.
5. **A model returns settings, never code.** Ask it for a look and it sends back
   numbers and colours, each checked against a legal range. It never sends CSS,
   because CSS can fetch a URL — and something that quietly phones home on every page
   you read is invisible while it works. Fonts come from a fixed local set, so there's
   no font server to call either.
6. **Rewriting is opt-in and reversible.** Off by default, badged while shown,
   original one keystroke away. News, medical, legal and financial pages need an
   explicit confirm.
7. **No telemetry.** Nothing about browsing leaves the device.
8. **Never make up a number.** The blocker doesn't report back what it stopped, so
   Zentic shows you that the shield is *on* rather than a satisfying "127 trackers
   blocked". The same rule governs the lens badge: it only ever shows what the page
   actually reported.

## Content blocking

EasyList, EasyPrivacy, EasyList Cookie, Peter Lowe's ad/tracking server list and
EasyList Annoyances, compiled to `WKContentRuleList` via AdGuard's
[SafariConverterLib](https://github.com/AdguardTeam/SafariConverterLib). Cookie
walls are dismissed in-page by [DuckDuckGo
autoconsent](https://github.com/duckduckgo/autoconsent), because a cookie dialog
is a DOM problem, not a network one.

## Bring your own key

Redesign and cloud rewriting use **your** OpenAI key, stored in the login
Keychain and sent only to OpenAI. There is no Zentic server, so there is nothing
of yours for us to hold. On-device rewriting via Apple Foundation Models needs no
key at all and is the default when Apple Intelligence is enabled.

## Status

| Milestone | State |
|---|---|
| M0 Skeleton · M1 Shell | done |
| M2 Strip | done |
| M3 Restructure | done — 48 of 80 corpus pages restructure; the rest are apps, front doors, index pages and threads, declined on purpose |
| M4 Recipes | not started |
| M5 Rewrite / Redesign | working — presets, built-in and prompted per-site designs, BYO key |
| Lenses | working — described once, replayed on every visit with no model call |
| M6 iOS | not started |

## Verification

The golden corpus is the safety net for the highest-risk component: 80 real pages
saved as HTML, extraction pinned to a reviewed answer, run offline under vitest.

```sh
cd web && npm run corpus            # print the table
cd web && npm run corpus -- --write # rewrite expectations, then READ THE DIFF
```

A machine can record what extraction does today; only a person can say whether
that is the right answer.
