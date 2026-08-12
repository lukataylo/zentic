# Zentic

A browser where the clean version of a page *is* the page you land on. macOS + iOS,
Swift, WKWebView. Three layers: **strip** (block ads/trackers/cookie walls),
**restructure** (extract and re-render in our own design system — deterministic, no
AI), **rewrite** (optionally re-voice the prose — on demand, AI).

Full design: `~/.claude/plans/hazy-swimming-flame.md`.

## Layout

| Path | What |
|---|---|
| `Sources/ZenticKit/` | Shared core. Contracts, models, policy. No UI. |
| `Sources/ZenticMac/` | macOS shell. Arc-style sidebar, spaces, ⌘K palette, tab suspension. |
| `web/` | TypeScript injected into every page. Builds to `Sources/ZenticKit/Resources/zentic.js`. |
| `Tests/Fixtures/wire/` | Golden files. The bridge contract, shared by both languages. |

## Build

```sh
swift build && swift test          # Swift
cd web && npm run check            # typecheck + fast tests + corpus + bundle
cd web && npm test                 # fast tests only, for the edit loop
cd web && npm run corpus           # print the extraction table across all 76 pages
```

The golden corpus (`npm run test:corpus`) takes ~90s because jsdom matches selectors
in JavaScript, so it is split out of `npm test` and gated by `npm run check`. After an
intentional extraction change: `npm run corpus -- --write`, then **read the diff** —
a changed title or a collapsed word count is the test working, not noise to bless.

`web/dist` output is **committed** so an Xcode build never needs Node. Run
`npm run build` and commit the result after changing anything in `web/src/`.

After an intentional wire-format change: `ZENTIC_UPDATE_FIXTURES=1 swift test`, review
the diff, then `cd web && npm test` to confirm TypeScript still parses it.

## Invariants

These are not style preferences. Each one is load-bearing, and each has a test.

1. **The page always becomes visible.** The reader hides the document at
   `document-start` to avoid a flash of the original, so it must guarantee a reveal.
   `Budget.revealFailsafe` (1500ms) is a hard ceiling — never raise it to make a slow
   site work. Arm the timer *before* hiding. See `web/src/visibility.ts`.

2. **Never restructure an app.** Archetype detection fails *open*: low confidence
   means pass the original through. Mangling someone's mail client costs their trust;
   declining to restructure an article costs nothing.

3. **Code, tables, math and embeds are never sent to a model.** A model asked to
   restyle a code block renames identifiers; asked to restyle a table it drops cells.
   `SectionKind.isRewritable` encodes this, and the rule is asserted in both languages
   from one fixture.

4. **A DOM skeleton carries no page text.** Recipe inference gets tag names, classes,
   geometry and text *lengths* — never characters. Guarded by
   `PrivacyContractTests`. If you need real text, you want `ExtractionResult`, which
   stays on-device.

5. **A model emits validated tokens, never CSS.** Free-form CSS can contain `url()`,
   which would beacon on every page read. `ThemeTokens.validated()` clamps ranges and
   repairs contrast. Fonts come from the closed `FontKey` set — all local, no webfonts.

6. **Rewriting is opt-in and reversible.** Off by default, badged while shown,
   original always one keystroke away (⌘\). The original DOM is hidden, never
   destroyed. Fidelity-sensitive content (news, medical, legal, financial) needs an
   explicit confirm.

7. **No telemetry.** Nothing about browsing leaves the device. `RevealPayload.elapsedMs`
   is for local diagnosis only.

8. **Never invent a blocked-tracker count.** `WKContentRuleList` reports nothing back
   to the app. Show shield *state*. A plausible-looking number would be fabricated.

## Conventions

- One `ReaderBridge` per tab. Reader state (recipe, theme, mode) rides on
  `WKUserScript`, which belongs to a `WKWebViewConfiguration` — so tabs cannot share a
  configuration without sharing reader state.
- Everything in-page runs in the `zentic` `WKContentWorld`. Page script must not be
  able to see or patch us.
- DOM work goes in `web/`, not Swift: extraction needs the post-JavaScript DOM, and
  one implementation then serves both platforms and is testable in Node.
- Budgets and thresholds live in `Budget`. Don't scatter magic numbers.
- Tests are written against real failure modes, not for coverage. If a test can't fail,
  delete it.
