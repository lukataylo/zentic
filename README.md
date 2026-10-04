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

## Passwords

Sign in to a site and Zentic offers to save the password, in a small card that hangs
from the toolbar: **Save**, **Not Now**, or **Never for This Site**. Change a password
and it offers to update the saved one instead. Private windows never offer.

Passwords live in your **login Keychain**, as ordinary web-form passwords, so Keychain
Access shows them too. Nothing else is written anywhere: no file, no preferences. A
password is held in memory only while it is being offered, filled or shown. The list of sites you said never to save for is a plain file of host
names.

**AutoFill** (on by default, Settings › Passwords) shows your saved accounts under a
sign-in field when you click into it. Arrow keys move through them, Return picks one.
Nothing is filled until you choose, and only:

- into the page itself, never a frame inside it,
- on the exact origin the password was saved for (`accounts.example.com` is not
  `example.com`), checked again after you choose,
- over an encrypted connection. On a plain `http://` page the menu warns instead.

Filling, showing or copying a password asks for Touch ID or your login password, and
that covers the next two minutes, until the Mac sleeps or its screen locks. `⇧⌘A`
offers your accounts on the page's sign-in form even with AutoFill off.

Settings › Passwords lists every account by site, with search, show, copy (taken off
the clipboard again after a minute), edit and delete, and the sites never saved for.

## Site permissions

Camera, microphone, location, pop-ups, auto-play and downloads are decided per site:
**Ask**, **Allow** or **Deny**. When a page asks, a small glass card hangs from the
site control at the left of the address bar. It names the site and what it wants,
and offers *Allow* / *Don't Allow* with *Remember for this site* ticked. *Allow* wakes
half a second after the card appears, so a click aimed at the page can't land on it.
Questions queue one at a time. A page that navigates away takes its questions with it,
unanswered, and a tab waiting on one shows a raised hand in the sidebar.

- **Camera and microphone.** While either is in use, a red camera or orange microphone
  sits next to the address bar, and on the folded pill and the tab's row too. Click it
  to pause, resume or stop. It follows WebKit's capture state as it changes; nothing
  polls.
- **Location** asks through the same card on macOS 27 and later, the first release
  where WebKit lets the browser answer.
- **Pop-ups.** One opened by a click always opens. Ones a page opens by itself are
  *blocked and notified* by default. The card says where it was going and opens it
  in a tab if you want it. Only a click or key press that went to the page, after it
  loaded, counts, and it opens one pop-up. Return in the address bar or ⌘R doesn't.
- **Auto-play**, as in Safari: *Allow All*, *Stop Media with Sound* (the default) or
  *Never*. WebKit fixes it when a tab's web view is made, so going to a site set
  differently re-makes the web view, back/forward list and all. Going *back* to such a
  site keeps the web view it has.
- **Downloads** ask the site of the page you're on, not the server the file comes from.

Change a site from the version picker (`⌥⌘0` › *Permissions*, or *Page › Site
Permissions…*). See every decision in **Settings › Permissions**, with search, removal
and a default for other websites. Decisions are saved in `permissions.json`. A private
window starts from them, but keeps its own answers in memory and forgets them with the
window. Nothing about any of this leaves the Mac.

## Safe Browsing and certificate warnings

**Dangerous sites.** Zentic keeps two public lists of phishing and malware hosts on
your Mac and checks every page you open against them before it loads. Nothing is
looked up online: the lists are downloaded whole, once a day (with `If-None-Match`, so
an unchanged list costs a few hundred bytes), and matching is a handful of binary
searches over hashed hosts. A listed host gets a full red warning page in place of the
site; *Show Details* says which list and entry matched, and holds *Visit This Site
Anyway*, which lasts until you quit. Other pages also can't load scripts, frames or
downloads from listed hosts: the lists are compiled into a WebKit content blocker for
third-party loads, whatever the site's version.

The lists come from [malware-filter](https://gitlab.com/malware-filter): the
[URLhaus filter](https://gitlab.com/malware-filter/urlhaus-filter) (abuse.ch URLhaus,
CC0; hosts currently serving malware) and the
[phishing filter](https://gitlab.com/malware-filter/phishing-filter) (OpenPhish,
PhishTank and IPThreat; CC BY-SA 4.0). Both drop hosts on the Tranco and Umbrella
popularity lists, so one bad page on a big shared host can't flag the whole host.
Phishing Army was ruled out by its non-commercial licence, OpenPhish's own feed by its
terms, and Google Safe Browsing because it is a lookup service. Turn it off, see when
the lists were last checked, or update now in *Settings › Security*.

**Certificate errors** get their own page saying what is actually wrong, in plain
words — expired, not valid yet (usually the Mac's clock), issued for a different site,
self-signed, or from an authority your Mac doesn't trust — with *Show Certificate*
(the system's certificate sheet) and, behind *Show Details*, *Visit This Site Anyway*.
That trusts exactly that certificate on that host until you quit; a different
certificate is asked about again, and a revoked one can't be bypassed. *Page › Show
Certificate…* works on any HTTPS page.

**Not secure.** A plain `http:` page shows an open lock in the address bar; one with a
password or card field says *Not Secure*. Either explains itself when clicked and
offers to try HTTPS.

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
| `⇧⌘A` | AutoFill a saved password |
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

- No telemetry. Nothing about browsing leaves the Mac except the pages themselves.
- Saved passwords stay in the login Keychain, are read only to fill, show or copy one
  after Touch ID or your password, and are filled only on explicit choice into the
  exact secure origin they belong to.
- A custom version's stylesheet is sanitised twice, in Swift before it's stored and in
  the page before it's applied. Anything that could fetch a URL (`url()`, `@import`,
  `@font-face`, `image-set()`, CSS escapes) is removed, and a sheet that still could is
  rejected whole. A stored version can never become a tracking beacon.
- Safe Browsing downloads whole threat lists and checks addresses on the Mac; no
  address you visit is sent anywhere to be checked.
- Content blocking: EasyList, EasyPrivacy, cookie and annoyance lists compiled to
  Safari's `WKContentRuleList`. Cookie walls are answered by DuckDuckGo's autoconsent.
