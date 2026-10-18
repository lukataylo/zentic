# Zentic

A macOS browser (Swift, SwiftUI, WKWebView) where each site has one of four versions,
remembered per site: **Original**, **Clean** (content blocking + cookie walls),
**Minimal** (site CSS off, Zentic's stylesheet over the live DOM, every element kept),
**Custom** (a stylesheet + hide list an OpenAI model writes from the user's words with
their own key; previewed, verified, kept, replayed with no further calls).

## Layout

| Path | What |
|---|---|
| `Sources/ZenticKit/Sites/` | `SiteMode`, `CustomVersion`, `SiteBook` (per-site choices), `PermissionBook` (per-site permissions), `Drift` (re-checking kept versions), `CSSSanitizer`, `JSONFile`, `DataDirectory` |
| `Sources/ZenticKit/Web/` | `InPageScript` (bootstrap + bundle injection), `URLGuess`, `IncomingURL` (links and files from other apps) |
| `Sources/ZenticKit/Intelligence/` | `OpenAIDesigner` (prompt, schema, parsing), `OpenAILibrarian` (recipe inference, app generation), `APIKeyStore` (Keychain) |
| `Sources/ZenticKit/Passwords/` | `LoginOrigin`, `PasswordPolicy` (what to offer, where to fill), `PasswordKeychain`, the sign-in script |
| `Sources/ZenticKit/Blocking/` | Filter lists → `WKContentRuleList` compiler and cache |
| `Sources/ZenticKit/Safety/` | `ThreatFeed` (the two host lists, parsing), `ThreatSet` (hashed matching), `ThreatLists` (download, ETag, on-disk copies), `ThreatRules` (subresource blocker), `CertificateCheck` (why a certificate failed), `CertificateExceptions` |
| `Sources/ZenticKit/Records/` | The user's database of sites: `SourceRecord`, `RecordStore` (SQLite), `SourceLibrary` (capture → raw → recipe → records), `JSONPath`, `SourceRecipe` (curated X; others inferred), `RecordMapper`, `ShapeSummary` (what recipe inference may send), `MediaCache`/`MediaPolicy`, `LibraryBudget` |
| `Sources/ZenticKit/Apps/` | Prompted apps: `GeneratedApp`/`AppStore` (versions on disk), `AppSandbox` (CSP, navigation, link allowance, records as an app sees them), `AppBrief` (everything the model is shown) |
| `Sources/ZenticKit/Library/` | `HistoryEntry`, `HistoryRange` (Clear History spans), `HistoryDay` (grouping), `Bookmark`/`BookmarkList`, `BookmarkImport` (Netscape HTML), `DownloadName` (safe, unique file names) |
| `Sources/ZenticKit/Extensions/` | `ExtensionRecord` (what the user allowed, persisted), `SiteAccess`, `SitePattern`, `ExtensionDiscovery`, `KeyChord`, `TabMoves` |
| `Sources/ZenticKit/Sync/` | `SyncedDevice` (one Mac's tabs, built from the session; its CloudKit record), `SyncedDevices` (merge), `SyncPacing` |
| `Sources/ZenticKit/Diagnostics/` | `ProblemReport` and its store, `MetricKitReports` (MetricKit JSON → report), `SystemCrashLog` (macOS `.ips`), `Symbolicator`, `Breadcrumb` |
| `Sources/ZenticKit/Session/` | `SessionSnapshot` (versioned), `LaunchGuard` (unclean-exit marker), `TabStateStore` (per-tab interaction state), `SpaceSwipe` |
| `Sources/ZenticMac/Model/` | `AppModel` (global state, persistence), `Browser` (one window: spaces, tabs), `Tab` (one web view), `DesignSession` |
| `Sources/ZenticMac/Features/` | `Windows/` (`Windows`: every browser, the session, crash recovery, app-wide tab suspension), `Spaces/`, `PrivateBrowsing/`, `Sessions/`, `Passwords/` (`Passwords`: accounts, never-save list, Touch ID; `TabPasswords`: one tab's menu and save prompt), `Permissions/` (store, per-tab requests, prompt, capture light, Settings pane), `Safety/` (Safe Browsing, certificate and threat warning pages, the address bar's Not Secure badge), `History/` (window, Recently Closed, Clear History), `Downloads/` (model, toolbar button, list), `Bookmarks/` (hidden unless turned on), `Library/` (command bar entries), `DefaultBrowser/` (status, links from other apps), `Onboarding/` (welcome tour), `Extensions/` (Safari Web Extensions: `Extensions` model, `ExtensionEvents` bridge, toolbar, Settings), `Recheck/` (`Rechecks`: drift of kept versions, its dot and picker actions), `Sync/` (`TabSync`: iCloud tabs over CKSyncEngine), `Diagnostics/` (MetricKit, breadcrumbs, Settings › Diagnostics, the report viewer), `Updates/` (Sparkle), `Apps/` (`Apps`: sources, captures, apps, the one path that sends a brief; `AppSchemeHandler` for `zentic://`; `AppEnvironment` seals an app's engine; `SourceRefresher`; the composer, tiles, notice, Settings › Library) |
| `Sources/ZenticMac/Views/` | SwiftUI: sidebar, card, floating toolbar, mode picker, composer, command bar, settings |
| `App/` | The app bundle's `Info.plist`, entitlements and icon (rendered by `scripts/render-icon.swift`) |
| `project.yml` | XcodeGen spec for `Zentic.app`; `Zentic.xcodeproj` is generated, never committed |
| `scripts/` | `build-app.sh` (→ `build/Zentic.app`), `release.sh` (archive, notarize, staple, zip), `test.sh` (every test, with a summary) |
| `Tests/` | `ZenticKitTests` (core logic), `ZenticMacTests` (integration: `@testable import ZenticMac`, real web views, `FixtureServer`), `ZenticUITests` (XCUITest, in `project.yml`), `Fixtures/Pages` (the pages both serve) |
| `web/src/` | The in-page script: `modes.ts` (the one switch), `minimal*.ts`, `custom.ts`, `sanitize.ts`, `snapshot.ts`, `health.ts`, `recheck.ts`, `scroll.ts`; `passwords.ts` (its own bundle, `zentic-passwords.js`); `capture.ts` (forwards a source's captures); `recorder-entry.ts` (`zentic-recorder.js`, the one page-world script); `app-runtime.ts` (`zentic-app.js`, `window.zentic` for apps) |

## Build

```sh
swift build && swift test
cd web && npm run check     # typecheck + tests + build into Sources/ZenticKit/Resources/zentic.js
```

```sh
scripts/build-app.sh          # the signed app → build/Zentic.app (needs xcodegen)
scripts/test.sh [--no-ui]     # swift test + web check + UI tests (xcodebuild test -scheme Zentic)
```

`swift run ZenticMac` stays the edit loop; the app compiles the same sources. Add
files under `Sources/ZenticMac` and both pick them up — never list sources in
`project.yml`. Build settings, Info.plist keys and entitlements go in `project.yml`
and `App/`.

When launching any build to try something, set `ZENTIC_DATA_DIR` to a fresh
directory so the user's real data is never read or written.

`zentic.js` is committed. Rebuild and commit it after changing `web/src`.

## Invariants

Each one has a test.

1. **Nothing a model writes can fetch.** Custom CSS is sanitised to a fixed point in
   Swift (`CSSSanitizer`, also on decode, so old stored versions are cleaned) and again
   in the page (`sanitize.ts`). Any remaining `url()` other than `data:`, `@import`,
   `image-set()`, `src()` or backslash escape rejects the whole sheet. Never let the
   two sanitizers depend on each other.
2. **A broken preview is never offered.** `DesignSession` measures visible text
   (`zentic.health()`) before and after a preview, and makes one repair call with a
   screenshot. If the page is still broken, it reverts.
3. **The page always becomes visible.** Minimal hides the document at document-start;
   the 1200 ms failsafe is armed before hiding.
4. **Modes switch live.** `apply()` is idempotent and fully reversible between any
   modes. Only a change in blocking (to or from Original) reloads.
5. **One source of truth.** `SiteBook` holds the user's choice; the tab's `previewing`
   holds an unkept preview. Nothing else stores either.
6. **Each tab has its own `WKUserContentController`**, popups included, because
   blockers and the message handler live on it.
7. **No telemetry.** The only outbound calls are the pages, favicons, filter lists
   (Safe Browsing's threat lists among them), (on request, or to learn the format of
   a source the user added, or to draw a new app's icon from its name and request) OpenAI, images a source's records point to (cached once,
   from hosts `MediaPolicy` allows), the pages of sources the user set to refresh in
   the background, (while tab sync
   is on) the user's own private CloudKit database, and (when update checks are on
   or requested) Sparkle's signed appcast and update archive from this repository's
   GitHub releases — never with a system profile (`SUEnableSystemProfiling`) and
   never from an isolated run. Safe Browsing downloads whole lists
   and matches on the Mac; never add a lookup service, which would send it every
   address. Tab sync sends only what `SyncedDevice.spaces(from:)` takes from the
   session — titles and addresses of ordinary windows' tabs — and other Macs' tabs
   never fetch an icon.
8. **A private window writes nothing to disk.** No session, history, favicon cache or
   tab state; its site choices and permission answers are in-memory overlays
   (`SiteBook.overlaying`, `PermissionScope`) and its
   cookies live in its own `WKWebsiteDataStore.nonPersistent()`. Every write path
   checks `isPrivate`; add the check to any new one.
9. **A session that can't be read is never overwritten.** `JSONFile` moves it aside,
   a newer `SessionSnapshot.version` refuses to decode, and tab-state files are pruned
   only against a session that was actually read.
10. **A page never gets a permission it was not given.** Every WebKit permission
    request and every Zentic-side gate (pop-ups, downloads, links that open another app)
    goes through
    `TabPermissions`, which answers from `PermissionBook` or asks. Queued questions are
    answered "no" when their document goes (`documentChanged`, `detach`), so a "yes"
    meant for one page never reaches the next. The prompt's Allow button arms only
    after 500 ms, and there is no Return shortcut for it, because a click or key press
    aimed at the page must never grant anything. A site's explicit decision is kept
    even when it equals the default (`PermissionBook` never prunes), so a later change
    of default can't turn on a camera the user said to ask about.
11. **A password is filled only on explicit choice, into the exact secure origin it was
    saved for.** Never silently, never into a frame, never over plain `http`.
    `PasswordPolicy.canFill` is checked before and after Touch ID, and the page's
    `fill` refuses unless `location.origin` still matches. Origins come from WebKit's
    `frameInfo.securityOrigin`, never from the page. A sign-in counts only if the person
    typed into its password field (trusted `input`; a page's `requestSubmit()` fires a
    trusted `submit`), and passwords live only in the Keychain (`PasswordKeychain`), read
    behind `Passwords.unlock`.
12. **A certificate is never trusted on Zentic's own judgement.** An exception exists only
    after "Visit This Site Anyway" on the error page, lives in memory until quit, and
    is for one certificate (SHA-256 of the leaf) on one host: a different certificate
    on the same host asks again. Revoked certificates get no exception.
    (`CertificateExceptions`, `CertificateTrust.respond`.)
13. **Re-checking never calls a model and never runs on the hot path.** `Rechecks`
    asks for `zentic.recheck()` after a Custom page's `didFinish`, in an idle callback,
    at most once per site per `Drift.checkInterval`. What it finds is only shown; the
    model is reached only through `DesignSession.repair`, from a button. A selector is
    judged only once a check has found it (the baseline is taken at Keep, later in the
    page's life than any check), and lost after `Drift.missesOnSameKind` misses on the kept kind of page
    (`CustomBaseline.isSameKind`) or `Drift.missesOnOtherPages` distinct other pages.
    Private windows are never checked (what is found outlives the window). A legacy version's baseline is adopted
    only from a page that `canBeBaseline` (never an error page).
14. **A problem report leaves the Mac only by the user's hand.** Copy, Save… and
    Email to Developer… in `ReportView`/`ReportActions` are the only exits, and the
    viewer shows the report's entire `text`, so what is sent is what was read. A
    `Breadcrumb` holds fixed phrases from the app and counts, never a URL, title or
    typed text, and private windows record none. `LaunchGuard.record` never
    recreates a removed marker, or a clean quit would be reported as a crash.

15. **Capture is opt-in, per site, and observes — it never asks.** Nothing is recorded
    on a site the user has not added as a source, and nothing in a private window or an
    app's tab. The page-world recorder (the one exception to "in-page code runs in the
    `zentic` world") only clones *successful* responses the page itself fetched and
    speaks over a random per-tab DOM event the page cannot name; Zentic never calls a
    site's API. Captures are filed under the sending frame's
    `frameInfo.securityOrigin`, never the payload's URL or the tab's current URL.
    By default a source updates only as the user browses it. Refreshing in the
    background is a per-source choice, never a default: signed out uses a
    non-persistent store; signed in (`.session`) uses the user's own, is switched on
    only past a warning about the account risk, is paced and capped by
    `RefreshSchedule` (tested), skips sources open in a tab, Low Power Mode and test
    runs, and only loads and scrolls — it never clicks, types or posts.
    Writes (reply, like) happen in the site's own UI, via links.
16. **An app can make no request the user did not click.** A generated app is
    model-written HTML, CSS and JS, so invariant 1's purpose is held by a box instead of
    a sanitizer: a CSP with `default-src 'none'` and nonce-only scripts, sent before any
    model byte (`AppSandbox.document`); a navigation policy where a link opens only if
    the app was *given* that URL (`LinkAllowance`) and anything else shows the user the
    whole URL first — a click is not proof of a user, WebKit reports a script's
    `a.click()` as a link activation; a scheme handler that scopes data by
    `mainDocumentURL` and answers only for the app's own sources; and an engine sealed
    by `AppEnvironment` — its own data store behind a dead proxy, no extensions, and
    `PeerConnectionEnabled` off, because WebRTC's STUN traffic is outside CSP. Images
    come only from `MediaCache`, fetched at capture time from hosts `MediaPolicy`
    allows — never because an app asked. Each has a test in `LibraryIntegrationTests`
    or `AppSandboxTests`; weakening one changes a test first.
17. **What the library sends a model is decided by two types.** Recipe inference sends a
    `ShapeSummary` only — structure, never values, not even the endpoint path
    (`ModelBoundaryTests`), capped per source per day, disclosed when a source is
    added. App generation sends an `AppBrief`, which includes a few sample records
    because the user chose that; the composer states what is sent before every
    generation, and if its sentence and `AppBrief` disagree the sentence is the bug.
    `Apps.generate` is the only path that sends a brief.

## Library

- `SourceRecord` is the API every generated app is written against. Adding a field is
  an API change for every app the user has prompted; decode new fields with defaults.
- Raw responses are kept (`LibraryBudget.rawResponsesPerSource`) so a fixed recipe
  re-maps history. A recipe that stops yielding is re-learned per endpoint; only the
  model's own `items: null` becomes a "no records here" verdict, and it expires.
- After changing `Tests/Fixtures/library/*` or a curated recipe, the X recipe tests are
  the check: an ad in someone's private front-end is the failure that matters.

## Conventions

- In-page code runs in the `zentic` `WKContentWorld`; page script cannot see it. The
  single exception is `zentic-recorder.js`, on library sources only (invariant 15).
- Don't use system shortcuts: ⌘E (Use Selection for Find) and ⌥⌘D (Dock) are taken.
- Menu commands act on `@FocusedValue(Browser.self)`; never reach for a global browser.
- The live-tab limit (`Windows.maxLiveTabs`) is app-wide, across windows and spaces.
- Liquid Glass cannot sample a web view. Surfaces over a page use `GlassSurface`
  (see `WindowChrome.swift`).
- Everything Zentic writes goes under `DataDirectory.root`; preferences go through
  `DataDirectory.defaults`, never `UserDefaults.standard`, web views use
  `WKWebsiteDataStore.zentic`, and stores that live elsewhere (Keychain) are keyed
  by `DataDirectory.isolationID` when isolated. Otherwise `ZENTIC_DATA_DIR` stops isolating.
- Bookmarks are hidden by default. Nothing may touch `BookmarkStore.shared` while
  `AppModel.showsBookmarks` is off — touching it reads the file.
- Links and files from other apps arrive as Apple Events taken by `OpenFromElsewhere`
  before SwiftUI sees them. Don't add `onOpenURL` or `application(_:open:)`: SwiftUI
  answers those by opening another window onto the same browser.
  Launched to open a link, AppKit opens no window, so `OpenFromElsewhere.didFinishLaunching`
  asks for one.
- Load addresses with `WKWebView.load(address:)`, which gives a file URL read access to
  its folder, so a saved page from Finder finds the images beside it.
- One `WKWebExtensionController` (`Extensions.shared.controller`) is set on every tab's
  configuration, private tabs included. WebKit keeps an extension out of any web view
  with a non-persistent data store unless its context has `hasAccessToPrivateData`, so
  a private tab must keep `WKWebsiteDataStore.nonPersistent()` (tested in
  `WebExtensionTests`). Extensions learn about tabs from `ExtensionEvents`, which
  watches the observable model: don't add per-call hooks for tab changes.
- WebKit forgets an extension's grants and storage identity on quit. `ExtensionRecord`
  holds both, and a record's `storageID` must never change, because the extension's
  data is filed under it.
- CloudKit is touched only after `TabSync.isSupported` (the entitlement check): an
  unentitled build (`swift run`) is killed by CloudKit otherwise. The iCloud
  entitlements live in `App/Zentic-iCloud.entitlements`, chosen by `ZENTIC_ICLOUD`
  in `project.yml`; keep it equal to `Zentic.entitlements` plus iCloud (tested).
- Sparkle is in the app target only (`project.yml`); code using it sits behind
  `#if canImport(Sparkle)` so `swift run` builds without it. An isolated run
  (`ZENTIC_DATA_DIR`) never starts the updater.
- A new app-level action worth knowing about after a crash gets a
  `Breadcrumbs.note("…", in: browser)` — a fixed phrase, never page data.
- Tests are written against real failure modes. If a test can't fail, delete it.
- A test run is isolated and offline by itself (`TestRun`: XCTest loaded, or the app
  launched with `--ui-testing`): its own data directory even without `ZENTIC_DATA_DIR`,
  the seed filter list only, no Safe Browsing download, no first page or default
  favourites. Anything new that fetches at launch must check `TestRun.isActive`.
  Pages for tests come from `Tests/Fixtures/Pages` via `FixtureServer`, never the web.
- Tests wait for conditions (`eventually`, `waitForExistence`, predicates), never a
  fixed time. `ZenticMacTests` suites nest under `AppIntegration`, which is
  `.serialized`: they share the app's singletons.
