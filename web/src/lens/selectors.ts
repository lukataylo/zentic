// The selector gate: what a lens is allowed to name, and how.
//
// Its own module because three callers need it and one of them is upstream of
// the others. `ops.ts` checks every selector it compiles into the stylesheet or
// runs an item op against, and `harvest.ts` checks the ones it reads fields with
// — and `ops.ts` already imports `harvest.ts`, so a shared gate living in
// `ops.ts` would be an import cycle. One module, imported by both, and the check
// stays at the point of use where no unusual path into the engine can skip it.

/**
 * Substrings that would let a selector escape the rule it is written into.
 *
 * The same list as Swift's `LensToken.forbidden`, and it is duplicated on purpose
 * rather than shipped down the wire: a lens can reach this side through a
 * bootstrap configuration, and then this is the only gate there was. Anything
 * that reaches the stylesheet compiler is checked here, at the point of use,
 * where the check cannot be bypassed by an unusual path into the engine.
 *
 * `>` is absent deliberately — it is the child combinator, and our own item
 * selectors are `:scope >` paths. `,` is absent too, and that is A2.0: a selector
 * list is a breadth problem rather than an escaping one, so it belongs with the
 * rest of the breadth ban in `safeRegionSelector`. A harvest field is read with
 * `querySelector` *inside one item*, where `h3, .title` means "whichever of these
 * this card uses" — which is how a real feed is marked up, and which the shared
 * list was rejecting, leaving the field to harvest an empty string in silence.
 *
 * `\` used to be here and should not have been: a blanket ban rejects every
 * escaped utility class (`.md\:flex`, `.w-1\/2`, `.text-\[13px\]`), which is a
 * large fraction of the modern web. Escapes are checked by shape below instead.
 */
const FORBIDDEN_IN_SELECTOR = ["url(", ";", "/*", "*/", "{", "}", "<", "@"];

/** `expression(` is the IE-era arbitrary-JavaScript hole. Banned as a function
 * call rather than as a substring, so the legitimate `.expression-editor` is
 * still addressable. */
const EXPRESSION_CALL = /expression\s*\(/;

/** Selectors that plainly *are* the whole page. `hide` on `html` is otherwise a
 * perfectly legal lens that blanks every visit to a site — §1's no-flash promise
 * inverted into a permanent one. A lens names a *part* of a page; if it cannot,
 * there is nothing for it to be reversible about.
 *
 * A port of `LensToken.pageRoots` in `LensValidation.swift`, written out
 * literally on both sides. See `coversPageByShape` for why that is enough. */
const PAGE_ROOTS = new Set(["*", "html", "body", ":root", ":scope"]);

/** A `*` at the start of the string or straight after a combinator — so the
 * subject is "anything", and `body > *` and `body *:not(script)` are rules
 * against every box the page has. */
const UNIVERSAL_PART = /(^|[\s>+~])\*/;

/** The parent `keepRule` synthesises, with a bare tag name inside it. */
const SYNTHESISED_BARE_PARENT = /^:has\(>\s*[a-z][a-z0-9-]*\)$/;

/** A `\` may only introduce a literal escape — one punctuation character CSS
 * would otherwise read as syntax. A `\` before a hex digit is a *unicode*
 * escape, which is how `\75 rl(` reconstructs `url(` past a literal search. */
const LITERAL_ESCAPE = /\\(.|$)/g;

const MAX_SELECTOR_LENGTH = 240;

/**
 * Control characters, which have no business in a selector or in a label and are
 * the classic way to smuggle a line break past a substring check.
 *
 * One definition, reached through the two functions below rather than shared as
 * a regex. `ops.ts` needs a global one to strip a label with and this file needs
 * a predicate, and a `/g` regex carries `lastIndex` between `test()` calls — so
 * the two spellings that used to sit in the two modules were one merge away from
 * becoming one spelling with an intermittent bug in it.
 */
const CONTROL_CHARS = /[\u0000-\u001f\u007f]/g;

export function hasControlChars(value: string): boolean {
  CONTROL_CHARS.lastIndex = 0;
  return CONTROL_CHARS.test(value);
}

/** The same characters replaced by spaces, for prose we are about to put into a
 * page and must not let disturb the layout it is labelling. */
export function withoutControlChars(value: string): string {
  return value.replace(CONTROL_CHARS, " ");
}

/**
 * A selector that cannot break out of the rule or the `<style>` around it.
 *
 * The *shape* gate, applied to every selector a lens carries. It says nothing
 * about breadth — see `safeRegionSelector` — because an item or field selector
 * is matched inside one element rather than against the document, and the
 * catalog's own item selectors are `:scope > article.card`.
 */
export function safeSelector(value: string | undefined | null): string | undefined {
  if (typeof value !== "string") return undefined;

  const held = decided.get(value);
  if (held !== undefined || decided.has(value)) return held;

  const answer = decide(value);
  decided.set(value, answer);
  return answer;
}

/**
 * One answer per selector string, for the life of the page.
 *
 * Every candidate of every region of every op goes through the gate on every
 * compile, and the gate ends in `document.querySelector` — a whole-document call
 * per candidate. A `hide` set at the op cap is 480 ops of 8 candidates across two
 * compiles: 7,680 queries, and at `document-start` every one of them runs against
 * a document that has nothing in it yet and can therefore tell us nothing we did
 * not already know.
 *
 * Safe to cache because the answer is a fact about the *string*. The shape checks
 * are pure, and `querySelector` throws for a syntax error and for nothing else —
 * a selector that parses now parses on the same engine in a second's time,
 * however much the page has changed underneath it.
 *
 * Bounded by what a lens can carry rather than by anything the page controls:
 * the only strings that reach here come from a stored lens's regions and ops.
 */
const decided = new Map<string, string | undefined>();

function decide(value: string): string | undefined {
  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.length > MAX_SELECTOR_LENGTH) return undefined;
  if (hasControlChars(trimmed)) return undefined;

  const lowered = trimmed.toLowerCase();
  for (const needle of FORBIDDEN_IN_SELECTOR) {
    if (lowered.includes(needle)) return undefined;
  }

  if (!escapesAreLiteral(trimmed)) return undefined;
  if (!isBalanced(trimmed)) return undefined;

  // Checked with the escapes resolved as well as without. `expression\(` is not a
  // function call — CSS reads the escape as a literal character, which is why it
  // was never exploitable in selector position — but a check that one backslash
  // steps around is a check nobody can reason about, and the Swift gate this
  // mirrors makes the same pair of passes.
  for (const form of [lowered, unescaped(lowered)]) {
    if (EXPRESSION_CALL.test(form)) return undefined;
  }

  if (!selectorParses(trimmed)) return undefined;
  return trimmed;
}

/** The string with its literal escapes resolved. Only meaningful once
 * `escapesAreLiteral` has agreed every `\` is followed by exactly one character. */
function unescaped(value: string): string {
  let result = "";
  let escaped = false;
  for (const character of value) {
    if (escaped) {
      result += character;
      escaped = false;
      continue;
    }
    if (character === "\\") {
      escaped = true;
      continue;
    }
    result += character;
  }
  return result;
}

/**
 * A selector naming a *region* — something a rule in our stylesheet is written
 * against, at document scope.
 *
 * The shape gate plus the breadth limit, and the breadth limit lives here alone.
 * `hide` on `html` would otherwise be a legal lens that blanks every visit to a
 * site. Item and field selectors must not come through here: banning `:scope`
 * at that level disables every `filter`, `reorder` and `harvest` op, because
 * `:scope > …` is precisely what the region catalog generates for a feed's rows.
 */
export function safeRegionSelector(value: string | undefined | null): string | undefined {
  const safe = safeSelector(value);
  if (safe === undefined) return undefined;
  // A region is one thing. A selector list is a way to smuggle a second, broader
  // subject into a rule authored for the first — `#feed, body` is the whole attack
  // in five characters — so the comma is banned here with the rest of the breadth
  // rules rather than in the shared shape gate.
  if (safe.includes(",")) return undefined;
  return coversPageByShape(safe) ? undefined : safe;
}

/**
 * Does this selector cover the whole page, judged with no DOM to ask?
 *
 * **The real answer comes from the platform.** `RegionResolver` already holds the
 * elements every candidate resolves to, so it rejects any whose match set
 * contains `<html>` or `<body>` — `Element.matches()`, exactly, for free. That is
 * stronger than any parser in the direction that matters: it sees
 * `keepRule(":is(body)")` synthesising `:has(> :is(body)) > *:not(:is(body))`
 * against `<html>`, which no parser of the *argument* can, and it is the reason
 * the bare-tag special case that used to sit inside `keepRule` is gone.
 *
 * This is what stands in for it at `document-start`, where `body` is null and
 * nothing resolves at all. It is deliberately literal. There used to be a
 * 233-line subject parser here that broke a compound into simple selectors and
 * decided whether anything in it *narrowed*, so that `:is(body)`, `body.dark` and
 * `body:not(#nope)` were all caught as the page-blankers they are. Every one of
 * those is still caught — by the DOM, a hundred milliseconds later, which is
 * before any of them can be authored in the first place: a region selector now
 * comes from the region catalog or from a file the user saved themselves, and no
 * real page offers `:is(body)` as an anchor. Keeping a parser that agrees with
 * the browser about what `.text-\[13px\]` means, in order to re-check something
 * the catalog already refuses, is weight nobody is carrying.
 *
 * So: the literal spellings — which is what a typo or an old build produces, and
 * a port of Swift's `pageRoots` — plus two shapes that are unbounded on
 * essentially every page and would otherwise blank it for the length of one
 * paint. Swift has no twin for the second of those, because Swift never builds a
 * keep rule.
 */
export function coversPageByShape(value: string): boolean {
  const trimmed = value.trim().toLowerCase();
  if (PAGE_ROOTS.has(trimmed)) return true;
  if (UNIVERSAL_PART.test(trimmed)) return true;
  return SYNTHESISED_BARE_PARENT.test(trimmed);
}

/**
 * A selector naming *one repeated item* inside a region.
 *
 * The shape gate, plus a comma ban that is here for a different reason than the
 * one in `safeRegionSelector`: not breadth, but the runner's failure mode.
 * `itemRun` falls back to the region's own element children when this returns
 * nothing, so a `drop` filter written as "the cards matching X" would quietly
 * become "everything directly inside this region" — the exact A1.2 degradation.
 * Handing the runner a list is handing it a selector it will silently not use.
 *
 * No breadth ban: an item selector is matched inside one element rather than
 * against the document, so `:scope > article.card` — which is what the region
 * catalog generates for a feed's rows — is the narrowest thing there is here.
 */
export function safeItemSelector(value: string | undefined | null): string | undefined {
  const safe = safeSelector(value);
  if (safe === undefined || safe.includes(",")) return undefined;
  return safe;
}

function escapesAreLiteral(value: string): boolean {
  for (const match of value.matchAll(LITERAL_ESCAPE)) {
    const next = match[1];
    // A trailing `\`, a `\` before whitespace, or a `\` before a hex digit: all
    // three are the start of a unicode escape rather than an escaped character.
    if (!next || /[0-9a-fA-F]/.test(next) || /\s/.test(next)) return false;
    if (/[A-Za-z0-9]/.test(next)) return false;
  }
  return true;
}

/**
 * Do `()`, `[]` and quotes close?
 *
 * The one check that matters most here. `#secondary:has(` passes every substring
 * test above and compiles to `#secondary:has( { display:none }`; per CSS Syntax
 * §5.4.8 the unclosed block swallows every rule after it to the end of the
 * sheet. So one stale op silently disables every later CSS op in the whole
 * stylesheet, while the structural pass still resolves their selectors and
 * reports them `applied` — the drift badge says the lens fits and the page says
 * otherwise, which breaks the promise that ops fail independently.
 */
function isBalanced(value: string): boolean {
  let parens = 0;
  let brackets = 0;
  let quote: string | undefined;
  let escaped = false;

  for (const character of value) {
    if (escaped) {
      escaped = false;
      continue;
    }
    if (character === "\\") {
      escaped = true;
      continue;
    }
    if (quote) {
      if (character === quote) quote = undefined;
      continue;
    }

    if (character === '"' || character === "'") quote = character;
    else if (character === "(") parens += 1;
    else if (character === ")" && (parens -= 1) < 0) return false;
    else if (character === "[") brackets += 1;
    else if (character === "]" && (brackets -= 1) < 0) return false;
  }

  return parens === 0 && brackets === 0 && quote === undefined && !escaped;
}

/**
 * Does the engine that will run this selector accept it?
 *
 * The balance scan catches the shapes that swallow a stylesheet, but only the
 * engine knows the rest — an unknown pseudo-class, a malformed `nth` argument.
 * This runs in the same engine that will match the selector, so an answer here
 * is the real answer rather than an approximation of one. Absent a document
 * (compile-time unit tests, a worker) the earlier shape checks stand alone.
 */
function selectorParses(selector: string): boolean {
  if (typeof document === "undefined") return true;
  try {
    document.querySelector(selector);
    return true;
  } catch {
    return false;
  }
}
