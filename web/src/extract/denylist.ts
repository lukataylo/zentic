// Hosts that are never restructured.
//
// Heuristics carry the general case; this list exists for the sites where being
// wrong is unacceptable and where waiting for a heuristic to fire is a risk not
// worth taking. Mangling someone's mail, their bank, or the document they are
// mid-sentence in is not a bug they forgive.
//
// Two categories, and it is worth keeping them straight:
//
//  1. **Applications.** Not documents at all. There is nothing to extract.
//  2. **Feeds and threads.** Real content, but `feed` and `thread` land in M4.
//     Until then the honest answer is to pass them through rather than flatten a
//     conversation into an article.
//
// `ReaderConfiguration.passthroughOrigins` is the user-visible version of this
// and takes effect earlier (before the page is even hidden). This list is the
// bundle's own backstop for when the app ships no origins — and, unlike a list
// of origins, it matches subdomains.

/** Matched as an exact hostname or as a suffix (`.` boundary only). */
const APPS = [
  // Mail, calendar, chat
  "mail.google.com",
  "calendar.google.com",
  "contacts.google.com",
  "chat.google.com",
  "meet.google.com",
  "keep.google.com",
  "mail.proton.me",
  "calendar.proton.me",
  "outlook.office.com",
  "outlook.office365.com",
  "outlook.live.com",
  "mail.yahoo.com",
  "mail.zoho.com",
  "app.fastmail.com",
  "hey.com",
  "superhuman.com",
  "teams.microsoft.com",
  "app.slack.com",
  "discord.com",
  "web.whatsapp.com",
  "web.telegram.org",
  "messenger.com",
  "web.skype.com",
  "app.zoom.us",
  "zoom.us",

  // Documents and design
  "docs.google.com",
  "sheets.google.com",
  "slides.google.com",
  "drive.google.com",
  "script.google.com",
  "colab.research.google.com",
  "notion.so",
  "coda.io",
  "airtable.com",
  "figma.com",
  "www.canva.com",
  "excalidraw.com",
  "app.diagrams.net",
  "miro.com",
  "tldraw.com",
  "whimsical.com",
  "photopea.com",
  "overleaf.com",
  "office.com",
  "onedrive.live.com",
  "sharepoint.com",
  "dropbox.com",
  "www.icloud.com",
  "icloud.com",

  // Project tooling
  "app.asana.com",
  "trello.com",
  "linear.app",
  "app.clickup.com",
  "monday.com",
  "atlassian.net",
  "app.shortcut.com",
  "height.app",

  // Code editors in the browser
  "github.dev",
  "vscode.dev",
  "codesandbox.io",
  "stackblitz.com",
  "replit.com",
  "jsfiddle.net",
  "glitch.com",
  "observablehq.com",

  // Money. The most expensive place to be wrong.
  "chase.com",
  "bankofamerica.com",
  "wellsfargo.com",
  "citi.com",
  "citibank.com",
  "capitalone.com",
  "usbank.com",
  "pnc.com",
  "ally.com",
  "amex.com",
  "americanexpress.com",
  "discover.com",
  "schwab.com",
  "fidelity.com",
  "vanguard.com",
  "etrade.com",
  "interactivebrokers.com",
  "robinhood.com",
  "coinbase.com",
  "kraken.com",
  "binance.com",
  "paypal.com",
  "wise.com",
  "revolut.com",
  "monzo.com",
  "starlingbank.com",
  "hsbc.co.uk",
  "barclays.co.uk",
  "lloydsbank.com",
  "halifax.co.uk",
  "natwest.com",
  "santander.co.uk",
  "nationwide.co.uk",
  "dashboard.stripe.com",
  "tradingview.com",

  // Media players and maps: interactive surfaces with no prose to recover.
  "netflix.com",
  "music.youtube.com",
  "open.spotify.com",
  "maps.google.com",
  "maps.apple.com",
  "waze.com",
];

/** Real content, but `feed`/`thread` layouts are M4. Until then, pass through. */
const FEEDS_AND_THREADS = [
  "x.com",
  "twitter.com",
  "facebook.com",
  "instagram.com",
  "linkedin.com",
  "tiktok.com",
  "pinterest.com",
  "threads.net",
  "threads.com",
  "bsky.app",
  "mastodon.social",
  "reddit.com",
  "news.ycombinator.com",
  "lobste.rs",
  "quora.com",
  "youtube.com",
  "twitch.tv",
];

const DENIED = new Set([...APPS, ...FEEDS_AND_THREADS]);

/**
 * Whether this hostname is never restructured.
 *
 * Suffix matching is on label boundaries, so `notion.so` covers
 * `www.notion.so` and `foo.notion.so` but a lookalike like `notnotion.so`
 * does not match.
 */
export function isDeniedHost(hostname: string): boolean {
  const host = hostname.toLowerCase().replace(/\.$/, "");
  if (DENIED.has(host)) return true;

  for (const denied of DENIED) {
    if (host.endsWith(`.${denied}`)) return true;
  }
  return false;
}

export const DENYLIST_SIZE = DENIED.size;
