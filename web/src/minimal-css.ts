// Zentic Minimal: one calm design system applied to the page's own live DOM.
//
// Every author stylesheet is off while this is on, so the selectors here are
// written against plain HTML semantics, not against any site. Everything is
// driven by custom properties on :root so a custom version on base "minimal"
// can restyle the whole page by overriding a handful of variables.

// The variables and what this sheet does are described to the model that
// writes custom versions in `OpenAIDesigner.minimalDescription` (Swift). Keep
// the two in step when a variable is added or renamed.

const GRID = [
  'ul:has(> li:nth-child(3)):has(> li > a img, > li > img, > li > figure, > li > article, > li > div img):not(nav ul, footer ul, [role="banner"] ul, table ul)',
  'ol:has(> li:nth-child(3)):has(> li > a img, > li > figure, > li > article):not(nav ol, footer ol, table ol)',
  ':is(div, section, main):has(> article + article + article)',
  ':is(div, section):has(> figure + figure + figure)',
].join(",\n");

export const MINIMAL_CSS = String.raw`
:root {
  --z-bg: #fbfbf9;
  --z-fg: #1c1c1e;
  --z-muted: #6e6e73;
  --z-accent: #0a64d6;
  --z-surface: #f1f1ee;
  --z-border: rgba(0, 0, 0, 0.09);
  --z-font: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", system-ui, sans-serif;
  --z-font-display: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", system-ui, sans-serif;
  --z-mono: ui-monospace, "SF Mono", Menlo, monospace;
  --z-measure: 46rem;
  --z-radius: 10px;
  --z-size: 17px;
  color-scheme: light dark;
}
@media (prefers-color-scheme: dark) {
  :root {
    --z-bg: #161617;
    --z-fg: #ececee;
    --z-muted: #9a9aa0;
    --z-accent: #6cabff;
    --z-surface: #222224;
    --z-border: rgba(255, 255, 255, 0.1);
  }
}

/* ---------- Things that must not show ---------- */
[data-zentic-hidden], [hidden], template, noscript, dialog:not([open]),
script, style, link, meta,
[class*="sr-only" i], [class*="visually-hidden" i], [class*="visuallyhidden" i],
[class*="screen-reader" i], [class*="screenreader" i], [class*="a11y-hidden" i],
[class*="skip-link" i], [class*="skiplink" i], [class*="skip-to" i], [class*="offscreen" i],
a[href^="#"][class*="skip" i], a[href="#main"], a[href="#content"], a[href="#main-content"],
img[width="1"], img[height="1"], img[width="0"], img[height="0"],
iframe[width="1"], iframe[height="1"], iframe[hidden],
[role="dialog"]:not([aria-modal="false"]), [aria-modal="true"],
[role="tooltip"], [role="menu"]:not(nav [role="menu"]),
[data-zentic-slide-hidden] {
  display: none !important;
}

/* ---------- Page ---------- */
*, *::before, *::after { box-sizing: border-box; }
html {
  background: var(--z-bg);
  color: var(--z-fg);
  font: 400 var(--z-size) / 1.6 var(--z-font);
  -webkit-font-smoothing: antialiased;
  text-rendering: optimizeLegibility;
  -webkit-text-size-adjust: 100%;
  scroll-behavior: smooth;
}
body {
  margin: 0 auto;
  padding: 2.25rem clamp(1.25rem, 5vw, 2.5rem) 5rem;
  max-width: calc(var(--z-measure) + 5rem);
  background: var(--z-bg);
  color: var(--z-fg);
  overflow-wrap: break-word;
}
::selection { background: color-mix(in srgb, var(--z-accent) 26%, transparent); }

main, article, section, center { display: block; }
section + section, article + article { margin-top: 2rem; }
aside {
  margin: 2rem 0;
  padding: 1rem 1.25rem;
  border-radius: var(--z-radius);
  background: var(--z-surface);
  font-size: 0.92em;
  color: var(--z-muted);
}
aside aside { padding: 0; background: none; margin: 1rem 0; }
aside:empty { display: none; }

/* ---------- Type ---------- */
h1, h2, h3, h4, h5, h6 {
  font-family: var(--z-font-display);
  color: var(--z-fg);
  line-height: 1.18;
  letter-spacing: -0.012em;
  margin: 2.2em 0 0.55em;
  font-weight: 650;
  text-wrap: balance;
}
h1 { font-size: clamp(1.9rem, 1.4rem + 1.9vw, 2.6rem); letter-spacing: -0.024em; font-weight: 700; margin-top: 1.2em; }
h2 { font-size: clamp(1.4rem, 1.2rem + 0.8vw, 1.75rem); letter-spacing: -0.018em; }
h3 { font-size: 1.22rem; }
h4 { font-size: 1.05rem; }
h5, h6 { font-size: 0.82rem; text-transform: uppercase; letter-spacing: 0.06em; color: var(--z-muted); }
h1 a, h2 a, h3 a, h4 a { color: inherit; text-decoration: none; }
h1 a:hover, h2 a:hover, h3 a:hover, h4 a:hover { color: var(--z-accent); }

p, ul, ol, dl, blockquote, pre, table, figure, form, fieldset, details, address {
  margin: 0 0 1.1em;
}
p { text-wrap: pretty; }
small, sub, sup, time { font-size: 0.82em; color: var(--z-muted); }
sub, sup { line-height: 0; }
strong, b { font-weight: 650; }
em, i, cite { font-style: italic; }
i:empty { display: none; }
mark { background: color-mix(in srgb, #ffd60a 45%, transparent); color: inherit; border-radius: 3px; padding: 0 0.15em; }
abbr[title] { text-decoration: underline dotted; text-underline-offset: 0.2em; }
hr {
  border: 0;
  height: 1px;
  background: var(--z-border);
  margin: 2.5rem 0;
}
address { font-style: normal; color: var(--z-muted); }

a {
  color: var(--z-accent);
  text-decoration: underline;
  text-decoration-color: color-mix(in srgb, var(--z-accent) 32%, transparent);
  text-decoration-thickness: 1px;
  text-underline-offset: 0.18em;
  border-radius: 3px;
}
a:hover { text-decoration-color: currentColor; }
/* Transitions only while interacting: switching stylesheets must not animate
   from the site's colours to ours. */
a:hover, button:hover, input:focus, select:focus, textarea:focus {
  transition: color 0.15s ease, background-color 0.15s ease, border-color 0.15s ease, box-shadow 0.15s ease, text-decoration-color 0.15s ease;
}
:focus-visible { outline: 2px solid var(--z-accent); outline-offset: 2px; }

ul, ol { padding-left: 1.4em; }
li { margin: 0.3em 0; }
li::marker { color: var(--z-muted); }
dt { font-weight: 600; margin-top: 0.75em; }
dd { margin: 0.2em 0 0 1.25em; color: var(--z-muted); }

blockquote {
  margin-left: 0;
  margin-right: 0;
  padding: 0.15em 0 0.15em 1.1em;
  border-left: 3px solid var(--z-border);
  color: var(--z-muted);
  font-size: 1.04em;
}
q { quotes: "“" "”" "‘" "’"; }

/* ---------- Code ---------- */
code, kbd, samp, tt, var {
  font-family: var(--z-mono);
  font-size: 0.86em;
}
:not(pre) > code, kbd {
  padding: 0.12em 0.36em;
  border-radius: 5px;
  background: var(--z-surface);
}
kbd { border: 1px solid var(--z-border); border-bottom-width: 2px; }
pre {
  padding: 1rem 1.15rem;
  border-radius: var(--z-radius);
  background: var(--z-surface);
  overflow-x: auto;
  line-height: 1.5;
  font-size: 0.9em;
  tab-size: 4;
}
pre code { padding: 0; background: none; font-size: inherit; }

/* ---------- Media ---------- */
img, picture, video, canvas {
  max-width: 100%;
  height: auto;
}
img, video { border-radius: calc(var(--z-radius) * 0.6); vertical-align: middle; }
img[src$=".svg" i], img[src*=".svg?" i] { border-radius: 0; }
figure { margin: 2rem 0; }
figure img, figure video, figure picture { display: block; margin: 0 auto; }
figcaption { margin-top: 0.6rem; font-size: 0.86em; color: var(--z-muted); line-height: 1.45; }
video { display: block; width: 100%; background: #000; }
audio { width: 100%; }

/* SVG: icons must stay icons once their sizing CSS is gone. */
svg { max-width: 100%; max-height: 60vh; vertical-align: -0.18em; fill: currentColor; }
svg:not([width]):not([height]) { width: 1.25em; height: 1.25em; }
svg[width][height] { max-height: 4rem; }
svg[width="100%"], svg[height="100%"] { width: 1.25em; height: 1.25em; }
a svg, button svg, li svg, label svg, p svg, span svg { max-width: 1.5em; max-height: 1.5em; }
:is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]) svg, nav svg, footer svg { max-height: 1.6rem; max-width: 9rem; }
/* Logos: height-led, so wordmarks keep their proportions. */
:is([class*="logo" i], [id*="logo" i], a[aria-label*="home" i], a[href="/"]) > svg,
svg:is([class*="logo" i], [aria-label*="logo" i]) {
  width: auto;
  height: 1.75rem;
  max-width: 12rem;
  max-height: none;
}
svg[aria-hidden="true"]:only-child { max-width: 1.25em; max-height: 1.25em; }

iframe {
  display: block;
  max-width: 100%;
  border: 0;
  border-radius: var(--z-radius);
  margin: 1.5rem 0;
}
iframe[src*="youtube" i], iframe[src*="youtube-nocookie" i], iframe[src*="vimeo" i],
iframe[src*="dailymotion" i], iframe[src*="player." i], iframe[data-zentic-video] {
  width: 100%;
  height: auto;
  aspect-ratio: 16 / 9;
}
iframe[data-zentic-ad] { display: none !important; }

/* ---------- Header, nav, footer ---------- */
:is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]) {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.5rem 1.25rem;
  margin: 0 0 2.25rem;
  padding: 0 0 1rem;
  border-bottom: 1px solid var(--z-border);
  font-size: 0.9rem;
}
:is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]) > * { margin: 0; }
:is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]) div { display: contents; }
:is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]) img, nav img { max-height: 2rem; width: auto; border-radius: 0; }
:is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]) :is(h1, h2, p) { font-size: 1rem; margin: 0; letter-spacing: 0; }
:is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]) form { margin: 0; display: flex; gap: 0.4rem; align-items: center; }

nav, [role="navigation"] { font-size: 0.9rem; margin: 0 0 1.25rem; }
:is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]) nav { margin: 0; }

/* Every nav is a quiet vertical list by default: tables of contents, side
   menus, "in this section" lists. */
nav ul, nav ol, [role="navigation"] ul {
  list-style: none;
  margin: 0;
  padding: 0;
}
nav :is(ul, ol) :is(ul, ol) { padding-left: 0.9rem; }
nav li { margin: 0; }
nav a, [role="navigation"] a {
  display: inline-block;
  padding: 0.2rem 0.5rem;
  margin-left: -0.5rem;
  border-radius: 7px;
  color: var(--z-fg);
  text-decoration: none;
  line-height: 1.4;
}
nav a:hover, [role="navigation"] a:hover { background: var(--z-surface); }
nav a[aria-current] { background: var(--z-surface); font-weight: 600; }
nav :is(ul, ol) :is(ul, ol) a { color: var(--z-muted); }

/* Only the site's top bars become horizontal rows. */
:is(:is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]) nav, :is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]), body > nav, body > div > nav, nav[aria-label*="main" i], nav[aria-label*="primary" i], nav[aria-label*="global" i]) :is(ul, ol), :is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]) :is(ul, ol), [role="menubar"] {
  display: flex;
  flex-wrap: wrap;
  gap: 0.15rem 0.35rem;
  list-style: none;
  margin: 0;
  padding: 0;
}
:is(:is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]) nav, :is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]), body > nav, body > div > nav, nav[aria-label*="main" i], nav[aria-label*="primary" i], nav[aria-label*="global" i]) :is(ul, ol) :is(ul, ol) { padding-left: 0; }
/* Wrapper divs inside bar items would stack each item; let links flow in the row. */
:is(:is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]) nav, :is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]), body > nav, body > div > nav, nav[aria-label*="main" i], nav[aria-label*="primary" i], nav[aria-label*="global" i]) li :is(div, span):not(:has(img, svg, input, button)), :is(:is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]) nav, :is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]), body > nav, body > div > nav, nav[aria-label*="main" i], nav[aria-label*="primary" i], nav[aria-label*="global" i]) li > div { display: contents; }
:is(:is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]) nav, :is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]), body > nav, body > div > nav, nav[aria-label*="main" i], nav[aria-label*="primary" i], nav[aria-label*="global" i]) li, :is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]) li, [role="menubar"] > * { margin: 0; }
:is(:is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]) nav, :is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]), body > nav, body > div > nav, nav[aria-label*="main" i], nav[aria-label*="primary" i], nav[aria-label*="global" i]) a, :is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]) a {
  display: inline-flex;
  align-items: center;
  gap: 0.35em;
  padding: 0.25rem 0.55rem;
  margin-left: 0;
  color: var(--z-fg);
}
nav button, :is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]) button {
  font-size: 0.85rem;
  padding: 0.25rem 0.5rem;
  background: none;
  border-color: transparent;
}
nav button:hover, :is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]) button:hover { background: var(--z-surface); }
nav h2, nav h3, nav h4 { font-size: 0.75rem; margin: 0.75rem 0 0.35rem; text-transform: uppercase; letter-spacing: 0.06em; color: var(--z-muted); }
/* Breadcrumbs */
nav[aria-label*="breadcrumb" i] :is(ol, ul) { display: flex; flex-wrap: wrap; gap: 0.1rem; font-size: 0.85rem; }
nav[aria-label*="breadcrumb" i] a { color: var(--z-muted); padding: 0.15rem 0.35rem; }

body > footer, [role="contentinfo"], body > div > footer, footer {
  display: block;
  margin-top: 4rem;
  padding-top: 1.5rem;
  border-top: 1px solid var(--z-border);
  font-size: 0.82rem;
  color: var(--z-muted);
}
footer footer { margin: 0; padding: 0; border: 0; }
footer h2, footer h3, footer h4, footer h5, footer h6 { font-size: 0.78rem; text-transform: uppercase; letter-spacing: 0.06em; margin: 1.25rem 0 0.4rem; color: var(--z-muted); }
footer ul, footer ol { display: flex; flex-wrap: wrap; gap: 0.2rem 1rem; list-style: none; padding: 0; margin: 0 0 0.75rem; }
footer li { margin: 0; }
footer a { color: var(--z-muted); text-decoration: none; }
footer a:hover { color: var(--z-fg); }
footer p { margin: 0.4rem 0; }

/* ---------- Collections become grids ----------
   Only real collections: at least three items, each carrying a picture or
   being an article. A list that merely contains an icon is not a gallery. */
:is(${GRID}) {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(min(100%, 13.5rem), 1fr));
  gap: 1.75rem 1.25rem;
  list-style: none;
  padding: 0;
  margin: 1.5rem 0 2.25rem;
}
:is(${GRID}) > * {
  display: flex;
  flex-direction: column;
  gap: 0.15rem;
  margin: 0;
}
:is(${GRID}) > * :is(div, a, span, picture, figure):has(img) { order: -1; }
:is(${GRID}) > * img:not([width="1"]) {
  width: 100%;
  aspect-ratio: 16 / 10;
  object-fit: cover;
}
:is(${GRID}) :is(h2, h3, h4) {
  font-size: 1.02rem;
  margin: 0.6rem 0 0.3rem;
  letter-spacing: -0.005em;
  color: var(--z-fg);
}
:is(${GRID}) p { font-size: 0.92em; color: var(--z-muted); margin: 0.25rem 0; }
:is(${GRID}) > * :is(ul, ol) {
  display: flex;
  flex-wrap: wrap;
  gap: 0 0.75rem;
  list-style: none;
  padding: 0;
  margin: 0.2rem 0 0;
  font-size: 0.82em;
  color: var(--z-muted);
}
:is(${GRID}) > * :is(ul, ol) li { margin: 0; }

/* ---------- Tables ---------- */
table {
  display: block;
  max-width: 100%;
  overflow-x: auto;
  border-collapse: collapse;
  font-size: 0.92em;
  font-variant-numeric: tabular-nums;
}
caption { text-align: left; font-weight: 600; padding: 0 0 0.5rem; }
th, td { padding: 0.5rem 0.75rem; border-bottom: 1px solid var(--z-border); text-align: left; vertical-align: top; }
thead th { font-weight: 600; font-size: 0.85em; color: var(--z-muted); border-bottom-color: color-mix(in srgb, var(--z-fg) 25%, transparent); }
tr:last-child > td { border-bottom: 0; }
/* Layout tables (presentational attributes, nested tables) are not data. */
table:is([cellpadding], [cellspacing], [border="0"]), table:has(table) { display: table; font-variant-numeric: normal; font-size: 1em; }
table:is([cellpadding], [cellspacing], [border="0"]) :is(td, th), table:has(table) > * > tr > :is(td, th) {
  border: 0;
  padding: 0.2rem 0.35rem;
}

/* ---------- Forms ---------- */
button, input, select, textarea {
  font: inherit;
  font-size: 0.95em;
  color: var(--z-fg);
  margin: 0;
}
button, input[type="submit"], input[type="button"], input[type="reset"], a[role="button"] {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 0.4em;
  padding: 0.45rem 0.95rem;
  border: 1px solid var(--z-border);
  border-radius: 999px;
  background: var(--z-surface);
  color: var(--z-fg);
  font-weight: 550;
  line-height: 1.2;
  cursor: pointer;
  text-decoration: none;
}
button:hover, input[type="submit"]:hover, input[type="button"]:hover, a[role="button"]:hover {
  border-color: color-mix(in srgb, var(--z-fg) 22%, transparent);
}
button:active, input[type="submit"]:active { transform: scale(0.98); }
button[type="submit"], input[type="submit"] {
  background: var(--z-accent);
  border-color: transparent;
  color: #fff;
}
button:disabled, input:disabled { opacity: 0.45; cursor: default; }
button:empty, a[role="button"]:empty { display: none; }
input:not([type="checkbox"], [type="radio"], [type="range"], [type="color"], [type="file"], [type="submit"], [type="button"], [type="reset"], [type="image"]),
select, textarea {
  padding: 0.5rem 0.75rem;
  border: 1px solid var(--z-border);
  border-radius: calc(var(--z-radius) * 0.8);
  background: var(--z-bg);
  min-width: 0;
  max-width: 100%;
}
input:focus, select:focus, textarea:focus {
  outline: none;
  border-color: var(--z-accent);
  box-shadow: 0 0 0 3px color-mix(in srgb, var(--z-accent) 22%, transparent);
}
input[type="checkbox"], input[type="radio"], input[type="range"], progress { accent-color: var(--z-accent); }
input[type="hidden"] { display: none !important; }
textarea { width: 100%; min-height: 6rem; resize: vertical; }
label { font-size: 0.92em; }
fieldset { border: 1px solid var(--z-border); border-radius: var(--z-radius); padding: 1rem 1.25rem; }
legend { padding: 0 0.4rem; font-weight: 600; font-size: 0.9em; }
form { display: block; }
form > * + * { margin-top: 0.5rem; }

details {
  border: 1px solid var(--z-border);
  border-radius: var(--z-radius);
  padding: 0.65rem 1rem;
}
summary { cursor: pointer; font-weight: 600; }
details[open] > summary { margin-bottom: 0.5rem; }

/* ---------- Content blocks that read better as cards ---------- */
[role="alert"], [role="status"]:not(:empty) {
  display: block;
  padding: 0.75rem 1rem;
  border-radius: var(--z-radius);
  background: var(--z-surface);
}

@media (max-width: 600px) {
  body { padding-top: 1.25rem; }
  :is(header:not(main header, article header, section header, aside header, footer header), [role="banner"]) { gap: 0.4rem 0.75rem; }
}
@media (prefers-reduced-motion: reduce) {
  html { scroll-behavior: auto; }
  * { transition: none !important; }
}
`;
