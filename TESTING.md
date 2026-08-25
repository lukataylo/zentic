# Zentic — what to try

The app is running. Two lenses are already saved so the feature is visible
without spending a model call.

## The two controls are different questions

- **The dots rail** (toolbar) — *how much* is this browser changing the page.
  Five ordered stops: Original → Clean → Calm → Reader → Rewritten. Each does
  everything the stop below it does and one thing more.
- **The lens button** (beside it) — *what shape* is this particular site.
  Per-site, and most useful exactly where the reader must never run.

They are deliberately independent. A lens is not "more transformation than
Rewritten", so it is not a sixth stop.

## 1. A lens on an app (the case the reader cannot serve)

Open the **YouTube** tab. A lens called **Focus** is saved for `/watch`.

- The suggestions rail and the comments are gone. The video player is the real
  player — that is the whole point of remodelling rather than restructuring.
- The lens badge reads **2/3**, and the third op is *deliberately* aimed at an
  element that does not exist so you can see honest drift. Click the badge: the
  drift group names it, shows the anchor it tried, and offers **Re-fit**.
- Watch the badge for a few seconds on load. It starts at 0/3 and corrects to
  2/3 — YouTube renders its rail after first paint, and the report re-checks on
  a backoff out to 8 seconds rather than reporting a lens dead while it works.
- Press **⌘\** — the untouched page comes back. Nothing was destroyed.

## 2. A lens on an article, and why it goes quiet

Open a **Wikipedia** tab. A lens called **No rails** is saved for the origin.

- At **Reader** on the rail, the lens reports *not on screen* — neutral, not a
  failure. The reader is showing its own render, so a lens over the site's DOM
  has nothing visible to act on, and the badge says so rather than claiming an
  effect you cannot see.
- Step the rail down to **Calm** or **Clean**. The site's own page returns and
  the lens applies to it.

## 3. Write one yourself

**⌥⌘L** on any page. Region outlines appear over the live page.

- Click a box, or type what you want ("hide the sidebar", "drop anything about
  crypto"). The model answers by **highlighting the regions it picked** — it
  does not apply anything. Nothing enters the draft until you press Apply.
- Chips are the ops in your own words; remove any one.
- The scope control binds it: this page / pages like this / whole site.
- Save. Revisit the site — it is there, with no model call.
- Your OpenAI key is already in the Keychain, so this path works.

## 4. Transparency

The page and sidebar are glass by default. `Glass.pageFill` is the dial
(0.55 light / 0.66 dark). It only shows where nothing paints over it — a site
with its own background still wins, which is correct: we do not repaint other
people's pages.

## What is NOT done — do not report these as surprises

- **`scoreFingerprint`** is exported with no production caller. Wire it or delete
  it; by the project's own rule an unread export is unwired.
- **The `ZenticMac` test target has one test**, which only proves linking the app
  into a test bundle does not start it. The connective layer it exists to cover —
  TabController, LensController, the popover — is still only covered by a
  source-scan floor test.
- **Twitter/X cannot be lensed logged out** — it redirects to a login wall. Its
  timeline is addressed almost entirely by `[data-testid]`, which the selector
  tiers now prefer, but the case is untested end to end.
- **`harvest`/`insert`** (a custom sidebar built from the page's own rows) is
  reachable now that the model is told `itemFields` exists, but it has never been
  exercised against a real site.
- The popover has not been seen in **dark mode**, and its scroll feel inside the
  popover is unverified.
