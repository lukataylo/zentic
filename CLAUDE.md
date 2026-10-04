# Zentic

A macOS browser (Swift, SwiftUI, WKWebView) where each site has one of four versions,
remembered per site: **Original**, **Clean** (content blocking + cookie walls),
**Minimal** (site CSS off, Zentic's stylesheet over the live DOM, every element kept),
**Custom** (a stylesheet + hide list an OpenAI model writes from the user's words with
their own key; previewed, verified, kept, replayed with no further calls).

## Layout

| Path | What |
|---|---|
| `Sources/ZenticKit/Sites/` | `SiteMode`, `CustomVersion`, `SiteBook` (per-site choices), `PermissionBook` (per-site permissions), `CSSSanitizer`, `JSONFile`, `DataDirectory` |
| `Sources/ZenticKit/Web/` | `InPageScript` (bootstrap + bundle injection), `URLGuess` |
| `Sources/ZenticKit/Intelligence/` | `OpenAIDesigner` (prompt, schema, parsing), `APIKeyStore` (Keychain) |
| `Sources/ZenticKit/Passwords/` | `LoginOrigin`, `PasswordPolicy` (what to offer, where to fill), `PasswordKeychain`, the sign-in script |
| `Sources/ZenticKit/Blocking/` | Filter lists → `WKContentRuleList` compiler and cache |
| `Sources/ZenticKit/Safety/` | `ThreatFeed` (the two host lists, parsing), `ThreatSet` (hashed matching), `ThreatLists` (download, ETag, on-disk copies), `ThreatRules` (subresource blocker), `CertificateCheck` (why a certificate failed), `CertificateExceptions` |
| `Sources/ZenticKit/Session/` | `SessionSnapshot` (versioned), `LaunchGuard` (unclean-exit marker), `TabStateStore` (per-tab interaction state), `SpaceSwipe` |
| `Sources/ZenticMac/Model/` | `AppModel` (global state, persistence), `Browser` (one window: spaces, tabs), `Tab` (one web view), `DesignSession` |
| `Sources/ZenticMac/Features/` | `Windows/` (`Windows`: every browser, the session, crash recovery, app-wide tab suspension), `Spaces/`, `PrivateBrowsing/`, `Sessions/`, `Passwords/` (`Passwords`: accounts, never-save list, Touch ID; `TabPasswords`: one tab's menu and save prompt), `Permissions/` (store, per-tab requests, prompt, capture light, Settings pane), `Safety/` (Safe Browsing, certificate and threat warning pages, the address bar's Not Secure badge) |
| `Sources/ZenticMac/Views/` | SwiftUI: sidebar, card, floating toolbar, mode picker, composer, command bar, settings |
| `App/` | The app bundle's `Info.plist`, entitlements and icon (rendered by `scripts/render-icon.swift`) |
| `project.yml` | XcodeGen spec for `Zentic.app`; `Zentic.xcodeproj` is generated, never committed |
| `scripts/` | `build-app.sh` (→ `build/Zentic.app`), `release.sh` (archive, notarize, staple, zip) |
| `web/src/` | The in-page script: `modes.ts` (the one switch), `minimal*.ts`, `custom.ts`, `sanitize.ts`, `snapshot.ts`, `health.ts`, `scroll.ts`; `passwords.ts` (its own bundle, `zentic-passwords.js`) |

## Build

```sh
swift build && swift test
cd web && npm run check     # typecheck + tests + build into Sources/ZenticKit/Resources/zentic.js
```

```sh
scripts/build-app.sh          # the signed app → build/Zentic.app (needs xcodegen)
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
   (Safe Browsing's threat lists among them) and (on request) OpenAI. Safe Browsing
   downloads whole lists and matches on the Mac; never add a lookup service, which
   would send it every address.
8. **A private window writes nothing to disk.** No session, history, favicon cache or
   tab state; its site choices and permission answers are in-memory overlays
   (`SiteBook.overlaying`, `PermissionScope`) and its
   cookies live in its own `WKWebsiteDataStore.nonPersistent()`. Every write path
   checks `isPrivate`; add the check to any new one.
9. **A session that can't be read is never overwritten.** `JSONFile` moves it aside,
   a newer `SessionSnapshot.version` refuses to decode, and tab-state files are pruned
   only against a session that was actually read.
10. **A page never gets a permission it was not given.** Every WebKit permission
    request and every Zentic-side gate (pop-ups, downloads) goes through
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

## Conventions

- In-page code runs in the `zentic` `WKContentWorld`; page script cannot see it.
- Don't use system shortcuts: ⌘E (Use Selection for Find) and ⌥⌘D (Dock) are taken.
- Menu commands act on `@FocusedValue(Browser.self)`; never reach for a global browser.
- The live-tab limit (`Windows.maxLiveTabs`) is app-wide, across windows and spaces.
- Liquid Glass cannot sample a web view. Surfaces over a page use `GlassSurface`
  (see `WindowChrome.swift`).
- Everything Zentic writes goes under `DataDirectory.root`; preferences go through
  `DataDirectory.defaults`, never `UserDefaults.standard`, web views use
  `WKWebsiteDataStore.zentic`, and stores that live elsewhere (Keychain) are keyed
  by `DataDirectory.isolationID` when isolated. Otherwise `ZENTIC_DATA_DIR` stops isolating.
- Tests are written against real failure modes. If a test can't fail, delete it.
