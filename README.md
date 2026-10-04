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

### When the site changes

Sites redesign; a kept version doesn't. So when you keep one, Zentic notes what it did
to the page: how many elements each hidden selector found, how much of the text stayed
visible, whether the page scrolled sideways, and the page's rough shape (its header,
nav, main, article, sidebar and footer counts).

On later visits, once the page has loaded and the browser is idle, and at most once
per site every three minutes, it measures again on your Mac. If a hidden selector now
finds nothing, much more of the text is hidden, or the page has started scrolling
sideways, the version has *drifted*. A small amber dot appears on the site's mode
glyph, and the picker's Custom row says what changed (*2 of 3 changes no longer match
this site's layout*). From there:

- **Repair…** (`⇧⌥⌘E`) sends the model your current stylesheet, what broke and a
  screenshot, then previews the fix. Keep or Discard it, as with any other design.
- **Turn Off** shows the site in your version's base (Clean or Minimal) and keeps the
  version for later.

Nothing is ever sent to a model unless you choose Repair, and a check never holds up a
page. A front page that has no article sidebar is not taken as a sign of a redesign.
A selector counts as broken once it has been missing on two checks of the kind of page
you kept the version on, or on three different pages of other kinds; finding it
anywhere clears it. Error pages and bot challenges are never evidence, and private
windows are not checked.

Versions kept before re-checking existed are measured on their next visit, as long as
the page is a real one with something on it the version acts on. Turn it all off in
Settings › Intelligence.

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

Camera, microphone, location, pop-ups, auto-play, downloads and opening other apps are
decided per site:
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
- **Opening other apps** (`mailto:`, FaceTime, a meeting app, a file server) asks
  "wants to open “Zoom”" — and only right after a click or key press in the page itself,
  never from an embedded frame. A page can't launch an app at load or on a timer.

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

## History, downloads and bookmarks

**History** (`⌘Y`) is a window of every page you visited, by day, with search (`⌘F`).
Double-click or Return opens a page in the window in front, `⌘Return` in new tabs;
`⌫` deletes, and hovering a day offers to delete all of it. *History › Clear History…*
clears the last hour, today, today and yesterday, or everything, and the change is on
disk at once. *History › Recently Closed* reopens any of the window's last fifteen
closed tabs, or the last closed window. Private windows are never recorded.

**Downloads** land in `~/Downloads`. While one is running, or once one has finished
this session, a button appears at the end of the toolbar with a progress ring (a small
ring also sits on the folded toolbar's pill). It, or `⌥⌘L`, opens the list: progress,
size and time left, pause and resume (WebKit's resume data, so a paused download
carries on where it stopped), cancel (which removes the partial file), try again,
show in Finder, double-click to open, and drag a finished file out. The list is kept
across launches; a download interrupted by quitting can be tried again. A private
window's downloads are listed only in private windows and never saved.

**Bookmarks** are off until you turn on *Settings › General › Show Bookmarks*; until
then there is no bookmark menu, window or suggestion anywhere, and the file is never
read. On, there is a Bookmarks menu (`⇧⌘D` adds the page, `⌥⌘B` shows the list),
bookmarks in the address bar's suggestions, and a window with folders one level deep:
drag to reorder, Return or *Rename* to rename, *Move To* between folders, `⌫` to
delete. *Import Bookmarks…* reads the HTML file Safari, Chrome, Firefox and Edge
export; deeper folders are flattened into their top-level one, the bookmarks bar's
contents land at the top, and importing the same file twice adds nothing new.

Typing *history*, *downloads* or *bookmarks* in the address bar (`⌘T`, `⌘L`) offers
to show each.

## Your default browser

*Settings › General* says whether Zentic is your default browser, with a *Make Default*
button when it isn't; macOS asks you to confirm. Links clicked in other apps then open
as new tabs in the ordinary window in front (never a private one), or bring a window
back if none is open. Zentic also opens HTML files, web archives and saved links
(`.webloc`, `.url`) from Finder — *Open With › Zentic*, or drop them on the Dock icon.
A saved link may only point at a web address, never at a file or script.

The first launch shows a short welcome over the first window: what Zentic does, which
version new sites open in, making it the default browser, and an optional OpenAI key
for Custom. *Help › Welcome to Zentic* shows it again.

## Extensions

Zentic runs the Safari Web Extensions you already have. Any app you installed that
carries one (Bitwarden, AdBlock, and so on) shows up in *Settings › Extensions*; turn it
on there. Nothing runs until you do.

**Websites.** A new extension runs nowhere. Where it would like to run, its button
beside the address bar shows a small orange dot; click it and Zentic asks whether to
allow that site for a day or for good, then does what the button does. Settings lists
the sites you allowed, takes new ones, or opens it to every site it asks for. The API
permissions an extension declares (storage, tabs, menus) are accepted when you turn it
on, as in Safari; Settings spells out what each means.

**The toolbar.** Each extension gets a small glass button with its badge. The badge is
coloured until you open the popup, then grey. Past three, two stay and the rest fold
into a puzzle-piece menu. Right-click a button for the extension's own menu items,
this site's access, its options page, or to turn it off. Keyboard shortcuts work, but
when one matches a Zentic shortcut, Zentic's wins. The shortcuts are listed in
Settings.

**Private windows** get no extensions unless you switch on *Allow in Private Windows*
for one. Sites allowed from a private window last until you quit and are never saved.

**Developers:** *Load Unpacked Extension…* in Settings runs an extension straight
from its folder. Its details sheet has *Reload*, and pages, popups and background
pages can all be inspected in Safari's Web Inspector. `Tests/Fixtures/Extensions/marker`
is a minimal example.

*Remove from Zentic* turns an extension off and deletes what it stored in Zentic. The
app stays installed. Not supported yet: native messaging to an extension's own app
(Bitwarden's Touch ID unlock, for one). Safari routes it through private plumbing, so
features that depend on it don't work here.

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
## Updates and problem reports

**Updates.** *Zentic › Check for Updates…*, or let it check by itself (Settings ›
General › Software Update, where you can also have updates download and install
on their own). Updates come from this repository's GitHub releases through
[Sparkle](https://sparkle-project.org). Each one is signed with the developer's key
and checked against the key built into the app before it is unpacked, and the feed
listing them is signed too. A check fetches that feed and sends nothing else: no
system profile, no identifiers. Builds from `swift run` have no updater, and neither
does a copy running with `ZENTIC_DATA_DIR` (Sparkle keeps its settings with the app's
real preferences).

**Problem reports.** When Zentic crashes, hangs, or uses too much CPU or disk, macOS
hands the next launch a diagnostic (MetricKit), and Zentic keeps it in Settings ›
Diagnostics. After an unexpected quit, Zentic also writes its own report: the crash
log macOS saved (already symbolicated), and what the app was doing just before.
That's the number of windows and tabs and the last few actions, like *Closed a tab*
or *Switched space*. Never a page, address or title, and nothing from private
windows. The notice after a crash has a **Send Report…** button for that report.

Reports stay on your Mac, in `Diagnostics/` in the data folder, for 60 days and at
most 30. **Nothing is ever sent automatically.** Each report can be read in full,
copied, saved, deleted or emailed to the developer. Email opens a draft in your mail
app with the report attached, and you decide whether to send it. What the viewer
shows is exactly what gets sent.

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
| `⇧⌥⌘E` | repair a version the site has changed under |
| `⌘[` `⌘]` | back, forward |
| `⇧⌘[` `⇧⌘]`, `⌘1`–`⌘9` | switch tabs |
| `⌘F` `⌘G` | find |
| `⌘D` | add to favourites |
| `⇧⌘A` | AutoFill a saved password |
| `⌘Y` / `⌥⌘L` | history / downloads |
| `⇧⌘D` / `⌥⌘B` | add bookmark / show bookmarks (when turned on) |
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

### Releasing an update

Sparkle updates are signed with an Ed25519 key. Its public half is `SUPublicEDKey`
in `App/Info.plist`. Its private half lives in the release Mac's login keychain,
under Sparkle's account `zentic`, and never in the repo. Sparkle's tools are in
`build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/` once either script
has run.

1. **Once per Mac:** make sure the key is there: `generate_keys --account zentic -p`
   prints the public key, which must match Info.plist. Back it up somewhere safe
   with `generate_keys --account zentic -x zentic-sparkle.key`. On a new Mac,
   import that backup with `-f`. If the key is lost, installed copies can never
   update again.
2. Raise `MARKETING_VERSION` in `project.yml` and commit. The build number is the
   commit count, which Sparkle compares.
3. `scripts/release.sh`. It refuses a version that is already tagged, released or
   in the published appcast, checks that the keychain key matches Info.plist, then
   archives, notarizes and staples the app. It zips it, signs the zip with
   `sign_update`, downloads the published `appcast.xml` (so older releases stay
   listed) and runs `generate_appcast` to add this version and sign the feed.
   Both files end up in `build/release/updates/`.
4. Create a GitHub release tagged `v<version>` and upload **both**
   `Zentic-<version>.zip` and `appcast.xml`. The app reads
   `releases/latest/download/appcast.xml`, so publishing the release is what
   ships it. Never edit `appcast.xml` by hand: it is signed.

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
- Saved passwords stay in the login Keychain, are read only to fill, show or copy one
  after Touch ID or your password, and are filled only on explicit choice into the
  exact secure origin they belong to.
- No telemetry. Nothing about browsing leaves the Mac except the pages themselves.
- Update checks fetch one signed file from GitHub and send nothing about you. Problem
  reports never leave the Mac unless you copy, save or email one yourself.
- A custom version's stylesheet is sanitised twice, in Swift before it's stored and in
  the page before it's applied. Anything that could fetch a URL (`url()`, `@import`,
  `@font-face`, `image-set()`, CSS escapes) is removed, and a sheet that still could is
  rejected whole. A stored version can never become a tracking beacon.
- Safe Browsing downloads whole threat lists and checks addresses on the Mac; no
  address you visit is sent anywhere to be checked.
- Content blocking: EasyList, EasyPrivacy, cookie and annoyance lists compiled to
  Safari's `WKContentRuleList`. Cookie walls are answered by DuckDuckGo's autoconsent.
