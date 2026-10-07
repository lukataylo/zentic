import { post } from "./post";

// Sign-in forms: which fields they are, what was submitted, and filling an
// account the person picked. Runs in the `zentic` content world, main frame
// only, so the page can neither see these listeners nor call `fill`.
//
// Everything here reacts to the person: listeners do nothing until a login
// field is focused or a form is sent, and only trusted events count. A sign-in
// is reported only if the person typed into its password field, so a page
// that fills and sends a form itself cannot make Zentic offer anything.

export type Role = "username" | "password";

export interface LoginFields {
  username: HTMLInputElement | null;
  passwords: HTMLInputElement[];
}

export interface Submission {
  username: string;
  password: string;
}

/** Longer than any real credential; past this, the form has been misread. */
const MAX_LENGTH = 1024;
const TEXTUAL = new Set(["text", "email", "tel"]);
/** Keys that close the menu: the person is typing it themselves, or said no. */
const CLOSING_KEYS = new Set(["Backspace", "Delete", "Enter", "Escape"]);

function isInput(node: unknown): node is HTMLInputElement {
  return !!node && (node as Element).nodeType === 1 && (node as Element).tagName === "INPUT";
}

function tokens(input: HTMLInputElement): string[] {
  return (input.getAttribute("autocomplete") ?? "").toLowerCase().split(/\s+/);
}

function usable(input: HTMLInputElement): boolean {
  return !input.disabled && input.type !== "hidden" && !input.hidden;
}

function isNewPassword(input: HTMLInputElement): boolean {
  return tokens(input).includes("new-password");
}

/**
 * The element that holds one sign-in's fields: its form, or — for a form-less
 * sign-in, common in single-page apps — the nearest ancestor that also holds
 * a password field.
 */
export function scopeOf(element: Element): Element | null {
  const form = isInput(element) || element.tagName === "BUTTON" ? (element as HTMLInputElement).form : null;
  if (form) return form;
  let node = element.parentElement;
  for (let depth = 0; node && depth < 8; depth++, node = node.parentElement) {
    if (node.querySelector("input[type='password' i]")) return node;
  }
  return null;
}

/** The username and password fields of one sign-in, in document order. */
export function loginFields(scope: Element): LoginFields {
  const all =
    scope.tagName === "FORM"
      ? Array.from((scope as HTMLFormElement).elements).filter(isInput)
      : Array.from(scope.querySelectorAll("input"));
  const inputs = all.filter(usable);
  const passwords = inputs.filter((input) => input.type === "password");
  const named = inputs.find((input) => input.type !== "password" && tokens(input).includes("username"));
  if (named || passwords.length === 0) return { username: named ?? null, passwords };
  // Otherwise the text field nearest before the first password field: what
  // every sign-in form puts there, whatever it is called.
  const first = passwords[0]!;
  const before = inputs.filter(
    (input) =>
      TEXTUAL.has(input.type) && first.compareDocumentPosition(input) & Node.DOCUMENT_POSITION_PRECEDING,
  );
  return { username: before.at(-1) ?? null, passwords };
}

/** Whether `input` is a field AutoFill should offer accounts for, and which. */
export function roleOf(input: HTMLInputElement): Role | null {
  if (!usable(input)) return null;
  if (input.type === "password") return isNewPassword(input) ? null : "password";
  if (!TEXTUAL.has(input.type)) return null;
  const scope = scopeOf(input);
  if (scope) {
    const fields = loginFields(scope);
    // A sign-up form: every password on it is a new one, so there is no
    // saved account to suggest.
    if (fields.passwords.length > 0 && fields.passwords.every(isNewPassword)) return null;
    if (fields.username === input) return "username";
  }
  // The first step of a two-step sign-in names its field.
  return tokens(input).includes("username") ? "username" : null;
}

/**
 * What a sign-in sent, or null if it is not one Zentic should offer to save.
 *
 * One password is a sign-in. A new password (by `autocomplete`, or two
 * matching fields, or the second and third of three) is a sign-up or a
 * change, and the new one is what to keep. Anything else — two fields that
 * disagree with nothing to say which is which — is too ambiguous to save:
 * offering the wrong password is worse than offering none.
 *
 * @param remembered the username from an earlier step of a two-step sign-in.
 */
export function submission(fields: LoginFields, remembered = ""): Submission | null {
  const filled = fields.passwords.filter((input) => input.value !== "");
  if (filled.length === 0) return null;
  const fresh = filled.filter(isNewPassword).map((input) => input.value);
  const values = filled.map((input) => input.value);
  let password: string | undefined;
  if (fresh.length > 0) {
    password = fresh.every((value) => value === fresh[0]) ? fresh[0] : undefined;
  } else if (values.length === 1) {
    password = values[0];
  } else if (values.length === 2 && values[0] === values[1]) {
    password = values[1];
  } else if (values.length === 3 && values[1] === values[2]) {
    password = values[1];
  }
  const username = (fields.username?.value.trim() || remembered).trim();
  if (!password || password.length > MAX_LENGTH || username.length > MAX_LENGTH) return null;
  return { username, password };
}

/**
 * A field that holds a username: one `roleOf` names, or an email field. The
 * first step of a two-step sign-in is often a bare email field, with no
 * password beside it to say what it is.
 */
function holdsUsername(input: HTMLInputElement): boolean {
  return usable(input) && (input.type === "email" || tokens(input).includes("email") || roleOf(input) === "username");
}

/** Words that name a control as sending a sign-in, when nothing else does. */
const SIGN_IN_WORDS = /\b(log ?in|sign ?in|next|continue|submit)\b/;
/** Controls beside a sign-in that do not send it, whatever their type. */
const NOT_SIGN_IN_WORDS = /\b(show|hide|reveal|toggle|forgot|cancel|back|with)\b/;

function labelOf(control: Element): string {
  const value = control.tagName === "INPUT" ? (control as HTMLInputElement).value : "";
  return (control.getAttribute("aria-label") ?? (control.textContent?.trim() || value)).toLowerCase();
}

/**
 * Whether clicking `control` sends a sign-in: a form's submit button, or a
 * form-less control whose words say so. Not "Forgot password?", "Cancel",
 * "Sign in with Google" or the eye that shows the password — counting those
 * would offer to save a half-typed password before the sign-in happens.
 */
export function sendsSignIn(control: Element): boolean {
  const label = labelOf(control);
  if (NOT_SIGN_IN_WORDS.test(label)) return false;
  if (control.tagName === "INPUT") return (control as HTMLInputElement).type.toLowerCase() === "submit";
  const button = control.tagName === "BUTTON" ? (control as HTMLButtonElement) : null;
  if (button?.form && button.type === "submit") return true;
  // A form-less button's type means nothing, a [role=button] has none, and a
  // type=button in a form may still be what a script sends it with: words decide.
  return SIGN_IN_WORDS.test(label);
}

/** The first visible sign-in field on the page — where ⇧⌘A goes. */
export function firstLoginField(doc: Document): HTMLInputElement | null {
  const candidates: HTMLInputElement[] = [];
  for (const input of Array.from(doc.querySelectorAll<HTMLInputElement>("input[type='password' i]"))) {
    if (roleOf(input) !== "password") continue;
    const scope = scopeOf(input);
    const username = scope ? loginFields(scope).username : null;
    candidates.push(username && roleOf(username) === "username" ? username : input);
  }
  if (candidates.length === 0) {
    const named = doc.querySelector<HTMLInputElement>("input[autocomplete~='username' i]");
    if (named && roleOf(named)) candidates.push(named);
  }
  // Without layout (tests) nothing has client rects; take the first.
  return candidates.find((input) => input.getClientRects().length > 0) ?? candidates[0] ?? null;
}

/** Set a field the way typing would, so the page's own framework notices. */
function setValue(input: HTMLInputElement, value: string): void {
  // From this content world `value` is always the native setter: a page
  // framework's override on the element lives in the page's world. That is
  // what makes React and friends see the following `input` as a change.
  input.value = value;
  input.dispatchEvent(new Event("input", { bubbles: true }));
  input.dispatchEvent(new Event("change", { bubbles: true }));
}

/**
 * Where Swift's suggestion menu stands, as far as the page needs to know.
 * `shown` is anything on screen without accounts to pick (the http warning,
 * or a field just reported that Swift has not answered yet): it closes like
 * the menu but leaves the keys to the page.
 */
export type MenuState = "closed" | "shown" | "open" | "highlighted";

export interface Passwords {
  /** Fill one account into the sign-in last focused. Refuses unless the page is still `origin`. */
  fill(origin: string, username: string, password: string): boolean;
  /** Swift opened, highlighted in, or closed the suggestion menu. */
  menu(state: MenuState): void;
  /** Focus the page's sign-in field and say where it is, for ⇧⌘A. */
  locate(): { role: Role; rect: Rect } | null;
}

interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

function rectOf(input: HTMLInputElement): Rect {
  const r = input.getBoundingClientRect();
  return { x: r.x, y: r.y, width: r.width, height: r.height };
}

/**
 * @param trusted whether an event came from the person. A seam for tests:
 *   jsdom cannot make a trusted keyboard event, and WebKit's `isTrusted` is
 *   the whole defence against a page faking a sign-in.
 */
export function startPasswords(
  save: boolean,
  doc: Document = document,
  trusted: (event: Event) => boolean = (event) => event.isTrusted,
): Passwords {
  const win = doc.defaultView ?? window;
  let field: HTMLInputElement | null = null;
  let menu: MenuState = "closed";
  // A two-step sign-in asks for the username on one screen and the password
  // on the next, often without a navigation between.
  let remembered = "";
  // The username field the person last typed into, for a form-less first
  // step sent by a click: nothing else ties that click to the field.
  let nameField: HTMLInputElement | null = null;
  // A sign-in reported once is not reported again when the same click also
  // sends the form.
  let reported = "";
  // Password fields the person typed or pasted into. A page can set a value
  // and call `requestSubmit()`, whose `submit` WebKit marks trusted, so a
  // trusted submit alone would let a page put its own credentials in front
  // of the person — even as an "update" over their real password. Only
  // trusted `input` proves a person entered it.
  const typed = new WeakSet<HTMLInputElement>();
  // And not every trusted `input` is a person: a page's
  // `execCommand("insertText")` fires one too, with no key press behind it.
  // Typing, pasting and dropping each start with an event only a person can
  // cause, aimed at the field; this is the field the last one went to.
  let handled: EventTarget | null = null;
  const handle = (event: Event) => {
    if (trusted(event)) handled = event.target;
  };
  for (const type of ["keydown", "paste", "drop"]) doc.addEventListener(type, handle, true);

  const showFor = (input: HTMLInputElement, role: Role) => {
    field = input;
    // Until Swift answers, a dismissal must still reach it, or a menu it
    // is about to show would open under a field the person already left.
    if (menu === "closed") menu = "shown";
    post({ type: "login-field", role, rect: rectOf(input) });
  };

  const dismiss = () => {
    if (menu === "closed") return;
    menu = "closed";
    post({ type: "login-dismiss" });
  };

  const consider = (scope: Element | null, from?: HTMLInputElement | null) => {
    if (!save) return;
    // The first step of a two-step sign-in: keep the username for the next.
    const fromName = from?.isConnected && holdsUsername(from) ? from.value.trim() : "";
    if (!scope) {
      if (fromName) remembered = fromName;
      return;
    }
    const fields = loginFields(scope);
    if (fields.passwords.length === 0) {
      const name = fields.username?.value.trim() || fromName;
      if (name) remembered = name;
      return;
    }
    if (!fields.passwords.some((input) => typed.has(input))) return;
    const sent = submission(fields, remembered);
    if (!sent) return;
    const key = sent.username + "\n" + sent.password;
    if (key === reported) return;
    reported = key;
    post({ type: "login-submit", username: sent.username, password: sent.password });
  };

  doc.addEventListener(
    "input",
    (event) => {
      // Only what the person typed: a page typing through execCommand is not them.
      const target = event.target;
      if (!trusted(event) || target !== handled || !isInput(target)) return;
      if (target.type === "password") typed.add(target);
      // A username being typed anew: the one from an earlier step (or an
      // earlier fill) no longer stands for whoever signs in next.
      else if (holdsUsername(target)) {
        remembered = "";
        nameField = target;
      }
    },
    true,
  );

  doc.addEventListener(
    "focusin",
    (event) => {
      if (!trusted(event)) return;
      const target = event.target;
      const role = isInput(target) ? roleOf(target) : null;
      if (role) showFor(target as HTMLInputElement, role);
      else dismiss();
    },
    true,
  );

  doc.addEventListener(
    "click",
    (event) => {
      if (!trusted(event)) return;
      const target = event.target as Element | null;
      if (!target || target.nodeType !== 1) return;
      // A click on a field already focused: bring the menu back after Escape.
      if (isInput(target)) {
        const role = roleOf(target);
        if (role) return showFor(target, role);
      }
      // Many sign-ins are sent by a button's click handler, with no `submit`
      // to hear. When there is one as well, it reports nothing twice.
      const button = target.closest("button, input[type='submit' i], [role='button']");
      if (!button || !sendsSignIn(button)) return;
      consider(scopeOf(button), nameField?.isConnected ? nameField : field);
    },
    true,
  );

  doc.addEventListener(
    "submit",
    (event) => {
      if (trusted(event) && event.target && (event.target as Element).nodeType === 1) {
        consider(event.target as Element);
      }
    },
    true,
  );

  doc.addEventListener(
    "keydown",
    (event) => {
      if (!trusted(event)) return;
      const target = event.target;
      const picking = menu === "open" || menu === "highlighted";
      if (picking && target === field) {
        const key =
          event.key === "ArrowDown" ? "down"
          : event.key === "ArrowUp" ? "up"
          : event.key === "Escape" ? "escape"
          : event.key === "Enter" && menu === "highlighted" ? "enter"
          : null;
        if (key) {
          // Ours, not the page's: Enter on a highlighted account fills it
          // rather than sending a half-empty form.
          event.preventDefault();
          event.stopImmediatePropagation();
          if (key === "escape" || key === "enter") menu = "closed";
          post({ type: "login-key", key });
          return;
        }
      }
      // Not arrows, Tab or a shortcut (⇧⌘A itself comes through here first).
      const typing = !event.metaKey && !event.ctrlKey && (event.key.length === 1 || CLOSING_KEYS.has(event.key));
      if (target === field && typing) dismiss();
      if (event.key === "Enter" && !event.isComposing && isInput(target)) {
        // A form's Enter also fires `submit`; this catches form-less ones.
        if (!target.form) consider(scopeOf(target), target);
      }
    },
    true,
  );

  // Clicking elsewhere on the page moves focus to nothing, so no `focusin`
  // follows. Checked a turn later, when focus has settled: if it went to
  // another sign-in field, that field's report already replaced the menu;
  // if the whole web view lost focus (a click on the menu itself), the
  // document no longer has it and the menu stays.
  doc.addEventListener(
    "focusout",
    (event) => {
      if (event.target !== field || menu === "closed") return;
      win.setTimeout(() => {
        if (doc.hasFocus() && doc.activeElement !== field) dismiss();
      }, 0);
    },
    true,
  );

  // The menu stands where the field was; anything that moves the field closes
  // it. Only a scroll of something that holds the field: a carousel or a chat
  // log scrolling itself would otherwise close the menu as soon as it opened.
  doc.addEventListener(
    "scroll",
    (event) => {
      const target = event.target as Node | null;
      if (target === doc || (field && target?.nodeType === 1 && (target as Element).contains(field))) dismiss();
    },
    { capture: true, passive: true },
  );
  win.addEventListener("resize", dismiss, { passive: true });
  win.addEventListener("pagehide", dismiss);

  return {
    fill(origin, username, password) {
      if (win.location.origin !== origin) return false;
      const input = field?.isConnected ? field : firstLoginField(doc);
      if (!input) return false;
      const scope = scopeOf(input);
      const fields = scope ? loginFields(scope) : { username: input, passwords: [] };
      const target = fields.passwords.find((candidate) => !isNewPassword(candidate));
      if (username && fields.username) setValue(fields.username, username);
      if (target) setValue(target, password);
      if (!target && !(username && fields.username)) return false;
      remembered = username;
      // Sending the form just filled is not a new sign-in to offer to save.
      reported = username + "\n" + password;
      menu = "closed";
      return true;
    },
    menu(state) {
      menu = state;
    },
    locate() {
      const input = field?.isConnected ? field : firstLoginField(doc);
      const role = input ? roleOf(input) : null;
      if (!input || !role) return null;
      field = input;
      input.focus();
      return { role, rect: rectOf(input) };
    },
  };
}
