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

Arc-style tinted glass sidebar (tint and translucency in Settings), favourites grid,
drag-to-reorder tabs. The page sits on a rounded card with a floating glass toolbar.
Scroll down and the toolbar folds into a small pill naming the site. Scroll up, hover
the top edge or click the pill, and it opens again. The toolbar follows the page's own
light or dark. Hide the sidebar (`⌃⌘S`) and resting the pointer on the window's left
edge slides it back in.

## Keyboard

| | |
|---|---|
| `⌘T` / `⌘L` | new tab / go to address (search, open tabs, history) |
| `⌘W` / `⇧⌘T` | close tab / reopen it |
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
swift run ZenticMac                  # run it
cd web && npm install && npm run check   # in-page script: typecheck, tests, build
```

The in-page script (`web/`) builds to `Sources/ZenticKit/Resources/zentic.js`, which is
committed so a Swift build never needs Node. After changing `web/src`, run
`npm run build` and commit the result.

## Privacy

- No telemetry. Nothing about browsing leaves the Mac except the pages themselves.
- A custom version's stylesheet is sanitised twice, in Swift before it's stored and in
  the page before it's applied. Anything that could fetch a URL (`url()`, `@import`,
  `@font-face`, `image-set()`, CSS escapes) is removed, and a sheet that still could is
  rejected whole. A stored version can never become a tracking beacon.
- Content blocking: EasyList, EasyPrivacy, cookie and annoyance lists compiled to
  Safari's `WKContentRuleList`. Cookie walls are answered by DuckDuckGo's autoconsent.
