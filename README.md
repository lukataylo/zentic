# Zentic

A Mac browser where every site looks the way you want it to, and keeps looking that way.

Pick one of four versions of any site from the control at the left of the address bar.
Zentic remembers your choice for that site.

| | What you get | Cost |
|---|---|---|
| **Original** | The site exactly as it ships | — |
| **Clean** | No ads, trackers or cookie banners; the site's own design | Nothing: WebKit applies the rules as the page loads |
| **Minimal** | The site's styling replaced by Zentic's calm design. Every link, image, form and video is kept and still works | Nothing: no model, runs on-device |
| **Custom** | Your own version, described in words ("dark, bigger text, hide the sidebar", "newspaper layout") | One model call per instruction with your own OpenAI key. **None** on later visits |

Clean, Minimal and Custom switch live, with no reload. Only crossing to or from Original
reloads, because content blocking is decided as a page loads; the picker says so.

## Custom versions

Press `⌥⌘E` (or choose Custom) and describe the site you want. Zentic sends the model
a structural outline of the page and a screenshot. The model sends back a stylesheet and
a list of elements to hide, and you see the result live on the page before deciding.

Before you're asked to keep it, Zentic checks the result. If the content vanished or the
layout broke, it shows the model what went wrong and asks for one repair. If that also
fails, the page is put back and you're told. A broken site is never offered.

Keep it, and that's the site from now on, replayed on every visit with no model call.
Refine it later with further instructions, or remove it from the picker or from
Settings › Sites.

Your key lives in the macOS Keychain and is sent only to OpenAI, only when you design.

## The window

Arc-style tinted glass sidebar (translucency in Settings), favourites grid,
drag-to-reorder tabs. The page sits on a rounded card with a floating glass toolbar.
Scroll down and the toolbar folds into a small pill naming the site. Scroll up, hover
the top edge or click the pill, and it opens again. The toolbar follows the page's own
light or dark. Hide the sidebar (`⌃⌘S`) and resting the pointer on the window's left
edge slides it back in.

## Windows, spaces and pinned tabs

**Windows.** `⌘N` opens another window with its own tabs; menus act on the window in
front. Close the last one and Zentic keeps running; click the Dock icon or press `⌘N`
and it comes back as you left it. Close one of several by mistake and *File ›
Reopen Closed Window* brings it back, spaces and all. Any tab can move to a new window
from its menu.

**Spaces.** Each window has spaces: a name, an icon (a symbol or an emoji) and a
colour, each with its own pinned and open tabs. Switch with the icons at the bottom of
the sidebar, a two-finger swipe across the sidebar, or `⌃1`–`⌃9`. Right-click a space
to edit, reorder or delete it. Favourites belong to every space. The address bar
(`⌘T`, `⌘L`) finds open tabs in any space of the window.

**Pinned tabs** sit above *New Tab*. They are places rather than pages: `⌘W` on one
unloads it and puts it back on its pinned address instead of closing it. Pin by
dragging a tab onto the space's name or from the tab's menu; removing a pinned tab
asks first.

**Private windows** (`⇧⌘N`) wear a deep graphite-indigo frame and an eye-slash mark.
Each has its own in-memory cookie and cache store. Nothing from one is written to
disk — no history, no saved tabs, no icon cache — and a site version chosen there
applies to that window only. Content blocking works as usual. They are not restored.

**Crash-safe sessions.** Every ordinary window, space, pinned and open tab is saved as
you go, and each tab's back/forward list and scroll position is kept in its own small
file, so a relaunch puts pages back where they were. If Zentic quits unexpectedly it
says so, once, and restores everything; if it crashes twice in a row within 30 seconds
of launching, it restores the tabs without loading the selected one until you click
it. A session file it cannot read is set aside, never overwritten.

## iCloud tab sync

Your other Macs' tabs appear at the bottom of the sidebar under **Other Devices**,
each Mac with its name, and its tabs grouped by space. Click one to open it here;
right-click a Mac for **Open All in New Space**. `⌘T` finds them too, and the History
menu lists them. Turn it off in Settings › General › iCloud, which also shows when
it last synced, or why it can't.

What syncs is one small record per Mac in your private iCloud database: the names of
its spaces, and the title and address of each pinned and open tab in its ordinary
windows. Never private windows, history, site settings or passwords. A Mac sends at
most every 30 seconds, only when something changed, and once more as it quits; it
learns of the others' changes by push, not polling. Without an iCloud account the
section is simply absent. Turning sync off removes this Mac from the others' lists.

**Setting it up** (once): the iCloud entitlements need a provisioning profile, and
Xcode can make one only with an Apple account. Until then the app builds without
them and the feature hides itself.

1. Xcode › Settings › Accounts › **+** › Apple ID; sign in with the account for team
   `5QC5886P5V`.
2. `scripts/build-app.sh --icloud`. Automatic signing registers the
   `iCloud.com.lukadadiani.Zentic` container and the push capability for
   `com.lukadadiani.Zentic`. If it says the container is missing, create it in the
   developer portal (Certificates, IDs & Profiles › Identifiers › iCloud Containers)
   and enable iCloud › CloudKit on the App ID with that container ticked, then build again.
3. Once that works, set `ZENTIC_ICLOUD: YES` in `project.yml` so every build has it.
4. Before shipping a Release build: in the CloudKit Console, **Deploy Schema
   Changes** to Production (the `Device` record type is created in Development on
   first use), and give `release.sh` a Developer ID provisioning profile that
   includes the container — manual signing does not make one.

`ZENTIC_SYNC_FIXTURE=devices.json` (Debug builds only) shows a JSON list of
`SyncedDevice`s instead of syncing, for working on the interface without CloudKit.
An isolated run (`ZENTIC_DATA_DIR`) syncs in a zone of its own, so it never appears
on your real Macs.

## Keyboard

| | |
|---|---|
| `⌘N` / `⇧⌘N` | new window / new private window |
| `⌘T` / `⌘L` | new tab / go to address (search, open tabs, history) |
| `⌘W` / `⇧⌘T` | close tab (unload a pinned one) / reopen it |
| `⌃1`–`⌃9` | switch space |
| `⌥⌘1`–`⌥⌘4` | Original, Clean, Minimal, Custom |
| `⌥⌘0` | the site's version picker |
| `⌥⌘E` | design or refine your version of this site |
| `⌘[` `⌘]` | back, forward |
| `⇧⌘[` `⇧⌘]`, `⌘1`–`⌘9` | switch tabs |
| `⌘F` `⌘G` | find |
| `⌘D` | add to favourites |
| `⌃⌘S` | sidebar |

## Build

```sh
swift build && swift test            # Swift
swift run ZenticMac                  # run it — the quick edit loop
cd web && npm install && npm run check   # in-page script: typecheck, tests, build
```

The in-page script (`web/`) builds to `Sources/ZenticKit/Resources/zentic.js`, which is
committed so a Swift build never needs Node. After changing `web/src`, run
`npm run build` and commit the result.

### The app

`swift run` gives you a bare executable. The real app — signed, with its icon,
entitlements and bundle identifier, which the default-browser setting, iCloud and
UI tests all need — comes from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). It compiles the same `Sources/ZenticMac` and takes
`ZenticKit` from the Swift package, so the two never drift.

```sh
scripts/build-app.sh                 # Debug, "Apple Development" → build/Zentic.app
scripts/build-app.sh --release       # Release, "Developer ID Application"
scripts/release.sh                   # archive, notarize, staple, zip → build/release/
open Zentic.xcodeproj                # generated by either script, or by `xcodegen generate`
```

`Zentic.xcodeproj` is generated and not committed; edit `project.yml`. The icon is
drawn in code: change `scripts/render-icon.swift`, run it, commit the PNGs.

`release.sh` notarizes with a `notarytool` keychain profile named `zentic-notary`
and stops with instructions if there isn't one. Credentials live in your keychain,
never in the repo.

Zentic is not sandboxed — no browser outside the App Store is, because a browser
reads and writes wherever you point it. Web content still runs in WebKit's own
sandboxed processes; the app itself runs under the Hardened Runtime and is notarized.
`App/Zentic.entitlements` says more.

### Keeping test runs away from your data

```sh
ZENTIC_DATA_DIR=/tmp/zentic-try swift run ZenticMac
ZENTIC_DATA_DIR=/tmp/zentic-try build/Zentic.app/Contents/MacOS/Zentic
```

Everything Zentic writes then goes there instead: site choices, history, session,
favicons, the blocker cache and its compiled lists, preferences, downloads, and
cookies and site storage (a WebKit store of its own). API keys go to a Keychain
entry of their own, so a test run never sees or deletes your real one. The one
exception is AppKit's own window position, which goes to the app's normal preferences.

## Privacy

- No telemetry. Nothing about browsing leaves the Mac except the pages themselves —
  and, if you leave iCloud tab sync on, your open tabs' titles and addresses, to your
  own private iCloud database.
- A custom version's stylesheet is sanitised twice, in Swift before it's stored and in
  the page before it's applied. Anything that could fetch a URL (`url()`, `@import`,
  `@font-face`, `image-set()`, CSS escapes) is removed, and a sheet that still could is
  rejected whole. A stored version can never become a tracking beacon.
- Content blocking: EasyList, EasyPrivacy, cookie and annoyance lists compiled to
  Safari's `WKContentRuleList`. Cookie walls are answered by DuckDuckGo's autoconsent.
