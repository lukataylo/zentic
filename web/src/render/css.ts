// The reader's structural stylesheet.
//
// Every value that a theme can influence is a custom property from
// `compileTheme`, so restyling replaces only that sheet and this one never
// changes. Nothing here is generated from page content, and there is no `url()`
// anywhere — a page read must not cause a network request that the page itself
// did not already make.
//
// Lives inside a closed shadow root, so selectors can be short and unqualified:
// the site's CSS cannot reach in and this cannot leak out. That isolation is why
// the reader needs no specificity war and no `!important` except on the host.

export const BASE_CSS = `
:host {
  display: block;
  all: initial;
  font-family: var(--z-font-body);
  color: var(--z-text);
}

*, *::before, *::after { box-sizing: border-box; }

.viewport {
  min-height: 100%;
  background: var(--z-bg);
  color: var(--z-text);
  font-family: var(--z-font-body);
  font-size: var(--z-size-base);
  line-height: var(--z-line-height);
  letter-spacing: var(--z-letter-spacing);
  -webkit-text-size-adjust: 100%;
  -webkit-font-smoothing: antialiased;
  padding: var(--z-space-5) var(--z-space-3);
}

::selection { background: var(--z-selection); }

.layout {
  margin: 0 auto;
  max-width: var(--z-measure);
}

/* Docs get a table of contents beside the prose. Below the breakpoint it
   collapses to a disclosure above the article, because a sticky sidebar on a
   phone is just a wall between the reader and the text. */
.layout[data-archetype="docs"] {
  max-width: calc(var(--z-measure) + 22ch);
  display: grid;
  grid-template-columns: minmax(0, 1fr) 18ch;
  gap: var(--z-space-4);
  align-items: start;
}

@media (max-width: 900px) {
  .layout[data-archetype="docs"] { display: block; }
  .toc { position: static; margin-bottom: var(--z-space-4); }
}

.toc {
  position: sticky;
  top: var(--z-space-3);
  font-size: var(--z-size-small);
  border-inline-start: var(--z-border-width) solid var(--z-border);
  padding-inline-start: var(--z-space-2);
  max-height: 80vh;
  overflow-y: auto;
}
.toc ol { list-style: none; margin: 0; padding: 0; }
.toc li { margin: 0 0 0.35em 0; }
.toc li[data-level="3"] { padding-inline-start: 1.2ch; }
.toc li[data-level="4"], .toc li[data-level="5"], .toc li[data-level="6"] { padding-inline-start: 2.4ch; }
.toc a { color: var(--z-text-muted); text-decoration: none; }
.toc a:hover { color: var(--z-accent); }

/* MARK: header */

.masthead { margin-bottom: var(--z-space-4); }
.masthead h1 {
  font-family: var(--z-font-heading);
  font-size: var(--z-size-h1);
  line-height: 1.12;
  margin: 0 0 var(--z-space-1) 0;
  text-transform: var(--z-heading-transform);
  font-variant-caps: var(--z-heading-variant);
  text-wrap: balance;
}
.byline {
  color: var(--z-text-muted);
  font-size: var(--z-size-small);
  display: flex;
  flex-wrap: wrap;
  gap: 0 1ch;
  margin: 0;
}
.byline > * + *::before { content: "·"; margin-inline-end: 1ch; }
.masthead::after {
  content: "";
  display: block;
  border-top: var(--z-rule-width) var(--z-rule-style) var(--z-border);
  margin-top: var(--z-space-2);
}

/* MARK: prose */

.body > * { margin: 0 0 var(--z-space-2) 0; }
.body > * + * { margin-top: 0; }

p {
  text-align: var(--z-text-align);
  hyphens: var(--z-hyphens);
  -webkit-hyphens: var(--z-hyphens);
  overflow-wrap: break-word;
}

/* Drop cap. With the ornament off, the custom properties resolve to
   float:none at the body size, so the rule has no visible effect and needs
   no conditional stylesheet. */
.body > p[data-lead]::first-letter {
  float: var(--z-dropcap-float);
  font-family: var(--z-font-heading);
  font-size: var(--z-dropcap-size);
  line-height: var(--z-dropcap-line);
  margin: var(--z-dropcap-margin);
}

h1, h2, h3, h4, h5, h6 {
  font-family: var(--z-font-heading);
  line-height: 1.2;
  margin: var(--z-space-4) 0 var(--z-space-1) 0;
  text-transform: var(--z-heading-transform);
  font-variant-caps: var(--z-heading-variant);
  scroll-margin-top: var(--z-space-3);
}
h1 { font-size: var(--z-size-h1); }
h2 { font-size: var(--z-size-h2); }
h3 { font-size: var(--z-size-h3); }
h4 { font-size: var(--z-size-h4); }
h5 { font-size: var(--z-size-h5); }
h6 { font-size: var(--z-size-h6); }

a {
  color: var(--z-accent);
  text-decoration-line: var(--z-link-line);
  text-decoration-style: var(--z-link-style);
  text-decoration-thickness: var(--z-link-thickness);
  text-underline-offset: 0.15em;
  background: var(--z-link-highlight);
}
a:visited { color: var(--z-visited); }

strong, b { font-weight: 650; }
em, i { font-style: italic; }
mark { background: var(--z-link-highlight); color: inherit; }
abbr[title] { text-decoration: underline dotted; }
small { font-size: var(--z-size-small); }
sup, sub { font-size: 0.75em; line-height: 0; }

hr {
  border: 0;
  border-top: var(--z-rule-width) var(--z-rule-style) var(--z-border);
  margin: var(--z-space-4) 0;
}

ul, ol { padding-inline-start: 3ch; }
ul { list-style-type: var(--z-list-style); }
li { margin-bottom: 0.35em; }
/* \`normal\` restores the engine's own bullet, so disc/circle/square keep
   working through the same property that dash/arrow override. */
ul > li::marker { content: var(--z-marker-content); color: var(--z-text-muted); }
dl { margin: 0 0 var(--z-space-2) 0; }
dt { font-weight: 650; }
dd { margin: 0 0 var(--z-space-1) 3ch; }

blockquote {
  margin: var(--z-space-2) 0;
  padding: var(--z-space-1) var(--z-space-2);
  border-inline-start: 3px solid var(--z-border);
  color: var(--z-text-muted);
  background: var(--z-surface);
  border-radius: var(--z-radius);
}
blockquote p:last-child { margin-bottom: 0; }

/* MARK: code */

code, kbd, samp, var {
  font-family: var(--z-font-mono);
  font-size: 0.9em;
  font-style: normal;
}
:not(pre) > code {
  background: var(--z-code-bg);
  border-radius: calc(var(--z-radius) * 0.4);
  padding: 0.1em 0.35em;
}

/* Code must not reflow: a wrapped shell command is a different command. So the
   block scrolls horizontally rather than wrapping, and the language label is
   the extractor's hint rather than anything we guessed. */
figure.code { margin: var(--z-space-2) 0; position: relative; }
figure.code > pre {
  margin: 0;
  overflow-x: auto;
  background: var(--z-code-bg);
  border: var(--z-border-width) solid var(--z-border);
  border-radius: var(--z-radius);
  box-shadow: var(--z-elevation);
  padding: var(--z-space-2);
  line-height: 1.45;
  -webkit-overflow-scrolling: touch;
}
figure.code > pre > code { white-space: pre; display: block; }
figure.code > figcaption {
  font-family: var(--z-font-mono);
  font-size: 0.72em;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--z-text-muted);
  padding: 0 0 0.3em 0;
}

/* MARK: tables */

.table-scroll {
  overflow-x: auto;
  margin: var(--z-space-2) 0;
  -webkit-overflow-scrolling: touch;
}
table {
  border-collapse: collapse;
  width: 100%;
  font-size: var(--z-size-small);
  background: var(--z-surface);
  border-radius: var(--z-radius);
  box-shadow: var(--z-elevation);
}
caption {
  caption-side: top;
  text-align: start;
  color: var(--z-text-muted);
  font-size: var(--z-size-small);
  padding-bottom: 0.4em;
}
th, td {
  border: var(--z-border-width) solid var(--z-border);
  padding: 0.45em 0.7em;
  text-align: start;
  vertical-align: top;
}
th { background: var(--z-code-bg); font-weight: 650; }

/* MARK: media */

figure { margin: var(--z-space-3) 0; }
figure > img, figure > picture > img { display: block; }
img {
  max-width: 100%;
  height: auto;
  border-radius: var(--z-radius);
  box-shadow: var(--z-elevation);
}
figcaption {
  color: var(--z-text-muted);
  font-size: var(--z-size-small);
  margin-top: 0.5em;
  text-align: start;
}

/* 16:9 is the fallback only — an embed with real dimensions keeps them, so the
   box is reserved before the frame loads and nothing shifts. */
.embed {
  position: relative;
  margin: var(--z-space-3) 0;
  aspect-ratio: var(--z-embed-ratio, 16 / 9);
  background: var(--z-surface);
  border-radius: var(--z-radius);
  overflow: hidden;
}
.embed > iframe {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  border: 0;
}

/* MARK: math */

.math-block {
  display: block;
  overflow-x: auto;
  margin: var(--z-space-2) 0;
  text-align: center;
  font-size: 1.05em;
}
.math-inline { display: inline; }
/* Marks prose replaced by the rewrite layer. Unstyled on purpose in M3 — the
   AI badge is chrome, and chrome is the app's job, not the page's. */
.rewritten { display: block; }
math { font-size: 1.05em; }
.math-error {
  font-family: var(--z-font-mono);
  color: var(--z-text-muted);
  border-bottom: 1px dotted var(--z-text-muted);
}

/* MARK: footnotes */

.footnotes {
  margin-top: var(--z-space-5);
  padding-top: var(--z-space-2);
  border-top: var(--z-rule-width) var(--z-rule-style) var(--z-border);
  font-size: var(--z-size-small);
  color: var(--z-text-muted);
}
.footnotes ol { padding-inline-start: 3ch; }
.footnotes li { margin-bottom: 0.6em; }
/* \`:target\` never matches inside a shadow root, so the "you landed here"
   highlight is driven by an attribute the view sets on click instead. */
[data-zentic-target] { background: var(--z-link-highlight); }
a.footnote-ref { text-decoration: none; }
a.footnote-backref { text-decoration: none; margin-inline-start: 0.4ch; }

/* MARK: badges */

.notice {
  font-size: var(--z-size-small);
  color: var(--z-text-muted);
  border: var(--z-border-width) solid var(--z-border);
  border-radius: var(--z-radius);
  padding: var(--z-space-1) var(--z-space-2);
  margin-bottom: var(--z-space-3);
  background: var(--z-surface);
  box-shadow: var(--z-elevation);
}
`;
