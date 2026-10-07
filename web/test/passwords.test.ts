import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { firstLoginField, loginFields, roleOf, scopeOf, startPasswords, submission } from "../src/passwords";

function page(html: string): void {
  document.body.innerHTML = html;
}

function $(selector: string): HTMLInputElement {
  return document.querySelector(selector) as HTMLInputElement;
}

function fieldsOf(selector: string) {
  return loginFields(scopeOf($(selector))!);
}

function type(selector: string, value: string): void {
  $(selector).value = value;
}

describe("form classification", () => {
  it("takes the text field before the password as the username, whatever it is called", () => {
    page(`<form><input name="q" type="search"><input name="login_id"><input type="password"></form>`);
    expect(fieldsOf("input[type=password]").username).toBe($("[name=login_id]"));
    expect(roleOf($("[name=login_id]"))).toBe("username");
    expect(roleOf($("[name=q]"))).toBeNull();
  });

  it("prefers a field marked autocomplete=username, even after the password", () => {
    page(`<form><input type="password"><input id="u" type="email" autocomplete="username"></form>`);
    expect(fieldsOf("#u").username).toBe($("#u"));
  });

  it("finds a form-less sign-in through a shared ancestor", () => {
    page(`<div><div><input id="u" type="email"></div><div><input id="p" type="password"></div><div role="button">Sign in</div></div>`);
    expect(roleOf($("#u"))).toBe("username");
    expect(roleOf($("#p"))).toBe("password");
  });

  it("offers nothing on a sign-up form or a newsletter box", () => {
    page(`<form id="signup"><input id="u"><input id="p" type="password" autocomplete="new-password"></form>
          <form><input id="news" type="email"><button>Subscribe</button></form>`);
    expect(roleOf($("#u"))).toBeNull();
    expect(roleOf($("#p"))).toBeNull();
    expect(roleOf($("#news"))).toBeNull();
  });

  it("recognises the first step of a two-step sign-in by its autocomplete", () => {
    page(`<form><input id="u" type="email" autocomplete="username webauthn"></form>`);
    expect(roleOf($("#u"))).toBe("username");
  });

  it("ignores hidden and disabled fields", () => {
    page(`<form><input id="u"><input type="hidden" value="csrf"><input id="p" type="password" disabled></form>`);
    expect(fieldsOf("#u").passwords).toEqual([]);
  });
});

describe("what a sign-in sent", () => {
  it("reports a sign-in", () => {
    page(`<form><input id="u"><input id="p" type="password"></form>`);
    type("#u", "  ada@example.com ");
    type("#p", "hunter2");
    expect(submission(fieldsOf("#p"))).toEqual({ username: "ada@example.com", password: "hunter2" });
  });

  it("keeps the new password of a change form, not the current one", () => {
    page(`<form><input id="a" type="password"><input id="b" type="password"><input id="c" type="password"></form>`);
    type("#a", "old");
    type("#b", "new");
    type("#c", "new");
    expect(submission(fieldsOf("#a"), "ada")).toEqual({ username: "ada", password: "new" });
  });

  it("trusts autocomplete=new-password over field order", () => {
    page(`<form><input id="u"><input id="n" type="password" autocomplete="new-password"><input id="c" type="password" autocomplete="current-password"></form>`);
    type("#u", "ada");
    type("#n", "new");
    type("#c", "old");
    expect(submission(fieldsOf("#n"))?.password).toBe("new");
  });

  it("refuses to guess between two passwords that disagree", () => {
    // A mistyped confirmation: saving either would save the wrong one half the time.
    page(`<form><input id="u"><input id="a" type="password"><input id="b" type="password"></form>`);
    type("#u", "ada");
    type("#a", "correct horse");
    type("#b", "correct hrose");
    expect(submission(fieldsOf("#a"))).toBeNull();
  });

  it("reports nothing for an empty password", () => {
    page(`<form><input id="u"><input id="p" type="password"></form>`);
    type("#u", "ada");
    expect(submission(fieldsOf("#p"))).toBeNull();
  });
});

describe("the page side of AutoFill", () => {
  let posted: unknown[];

  beforeEach(() => {
    posted = [];
    (window as unknown as { webkit: unknown }).webkit = {
      messageHandlers: { zentic: { postMessage: (message: unknown) => posted.push(message) } },
    };
  });

  afterEach(() => {
    delete (window as unknown as { webkit?: unknown }).webkit;
    vi.restoreAllMocks();
  });

  function freshDocument(html: string): Document {
    const doc = document.implementation.createHTMLDocument("t");
    doc.body.innerHTML = html;
    return doc;
  }

  // jsdom cannot make a trusted event, so these tests stand in for WebKit's flag;
  // the first test keeps the real check.
  const trusted = <E extends Event>(event: E): E => event;
  const start = (save: boolean, doc: Document) => startPasswords(save, doc, () => true);
  /** The person typing into a field (its value is already set): a key, then its input. */
  const typeInto = (doc: Document, id: string) => {
    const field = doc.getElementById(id)!;
    field.dispatchEvent(trusted(new KeyboardEvent("keydown", { key: "a", bubbles: true })));
    field.dispatchEvent(trusted(new Event("input", { bubbles: true })));
  };

  it("ignores events the page made up", () => {
    const doc = freshDocument(`<form><input id="u" value="ada"><input id="p" type="password" value="pw"></form>`);
    startPasswords(true, doc);
    doc.querySelector("form")!.dispatchEvent(new Event("submit", { bubbles: true }));
    doc.getElementById("u")!.dispatchEvent(new FocusEvent("focusin", { bubbles: true }));
    expect(posted).toEqual([]);
  });

  it("reports a trusted submission once, however many events announce it", () => {
    const doc = freshDocument(`<form><input id="u" value="ada"><input id="p" type="password" value="pw"><button id="go">Sign in</button></form>`);
    start(true, doc);
    typeInto(doc, "p");
    doc.getElementById("go")!.dispatchEvent(trusted(new MouseEvent("click", { bubbles: true })));
    doc.querySelector("form")!.dispatchEvent(trusted(new Event("submit", { bubbles: true })));
    expect(posted).toEqual([{ type: "login-submit", username: "ada", password: "pw" }]);
  });

  it("ignores a sign-in the page filled in and sent itself", () => {
    // `requestSubmit()` fires a submit WebKit marks trusted; nobody typed the password.
    const doc = freshDocument(`<form><input id="u" value="attacker"><input id="p" type="password" value="chosen"></form>`);
    start(true, doc);
    doc.querySelector("form")!.dispatchEvent(trusted(new Event("submit", { bubbles: true })));
    expect(posted).toEqual([]);
  });

  it("ignores a password the page typed through the editor", () => {
    // `execCommand("insertText")` fires an input WebKit marks trusted, with no
    // key press behind it (WebKit itself is checked in ZenticMacTests).
    const doc = freshDocument(`<form><input id="u" value="attacker"><input id="p" type="password" value="chosen"></form>`);
    start(true, doc);
    doc.getElementById("u")!.dispatchEvent(trusted(new KeyboardEvent("keydown", { key: "a", bubbles: true })));
    doc.getElementById("p")!.dispatchEvent(trusted(new Event("input", { bubbles: true })));
    doc.querySelector("form")!.dispatchEvent(trusted(new Event("submit", { bubbles: true })));
    expect(posted).toEqual([]);
  });

  it("counts a pasted password as the person's", () => {
    const doc = freshDocument(`<form><input id="u" value="ada"><input id="p" type="password" value="pw"></form>`);
    start(true, doc);
    const field = doc.getElementById("p")!;
    field.dispatchEvent(trusted(new Event("paste", { bubbles: true })));
    field.dispatchEvent(trusted(new Event("input", { bubbles: true })));
    doc.querySelector("form")!.dispatchEvent(trusted(new Event("submit", { bubbles: true })));
    expect(posted).toEqual([{ type: "login-submit", username: "ada", password: "pw" }]);
  });

  it("does not take the show-password button for a sign-in", () => {
    const doc = freshDocument(`<form><input id="u" value="ada"><input id="p" type="password" value="pw"><button type="button" aria-label="Show password">👁</button></form>`);
    start(true, doc);
    typeInto(doc, "p");
    doc.querySelector("button")!.dispatchEvent(trusted(new MouseEvent("click", { bubbles: true })));
    expect(posted).toEqual([]);
  });

  it("never reports a sign-in when saving is off (a private window)", () => {
    const doc = freshDocument(`<form><input id="u" value="ada"><input id="p" type="password" value="pw"></form>`);
    start(false, doc);
    typeInto(doc, "p");
    doc.querySelector("form")!.dispatchEvent(trusted(new Event("submit", { bubbles: true })));
    expect(posted).toEqual([]);
  });

  it("carries the username across a two-step sign-in", () => {
    const doc = freshDocument(`<form id="one"><input id="u" autocomplete="username" value="ada"></form>`);
    start(true, doc);
    doc.getElementById("one")!.dispatchEvent(trusted(new Event("submit", { bubbles: true })));
    doc.body.innerHTML = `<form id="two"><input id="p" type="password" value="pw"></form>`;
    typeInto(doc, "p");
    doc.getElementById("two")!.dispatchEvent(trusted(new Event("submit", { bubbles: true })));
    expect(posted).toEqual([{ type: "login-submit", username: "ada", password: "pw" }]);
  });

  it("fills the focused sign-in only while the page is still the expected origin", () => {
    const doc = freshDocument(`<form><input id="u"><input id="p" type="password"></form>`);
    const passwords = start(true, doc);
    const seen: string[] = [];
    doc.getElementById("u")!.addEventListener("input", () => seen.push("input"));
    doc.getElementById("p")!.dispatchEvent(trusted(new FocusEvent("focusin", { bubbles: true })));

    expect(passwords.fill("https://evil.example", "ada", "pw")).toBe(false);
    expect((doc.getElementById("p") as HTMLInputElement).value).toBe("");

    expect(passwords.fill(window.location.origin, "ada", "pw")).toBe(true);
    expect((doc.getElementById("u") as HTMLInputElement).value).toBe("ada");
    expect((doc.getElementById("p") as HTMLInputElement).value).toBe("pw");
    expect(seen).toEqual(["input"]);
  });

  it("does not offer to save what it just filled", () => {
    const doc = freshDocument(`<form><input id="u"><input id="p" type="password"></form>`);
    const passwords = start(true, doc);
    passwords.fill(window.location.origin, "ada", "pw");
    doc.querySelector("form")!.dispatchEvent(trusted(new Event("submit", { bubbles: true })));
    expect(posted).toEqual([]);
  });

  it("never fills a new-password field", () => {
    const doc = freshDocument(`<form><input id="u"><input id="cur" type="password"><input id="new" type="password" autocomplete="new-password"></form>`);
    const passwords = start(true, doc);
    passwords.fill(window.location.origin, "ada", "pw");
    expect((doc.getElementById("cur") as HTMLInputElement).value).toBe("pw");
    expect((doc.getElementById("new") as HTMLInputElement).value).toBe("");
  });

  it("keeps arrow keys and Escape for the menu only while it is open", () => {
    const doc = freshDocument(`<form><input id="u"><input id="p" type="password"></form>`);
    const passwords = start(true, doc);
    const field = doc.getElementById("u")!;
    field.dispatchEvent(trusted(new FocusEvent("focusin", { bubbles: true })));
    posted = [];

    const down = trusted(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true, cancelable: true }));
    field.dispatchEvent(down);
    expect(down.defaultPrevented).toBe(false);

    passwords.menu("open");
    const again = trusted(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true, cancelable: true }));
    field.dispatchEvent(again);
    expect(again.defaultPrevented).toBe(true);
    expect(posted).toEqual([{ type: "login-key", key: "down" }]);

    // Nothing highlighted: Enter still sends the page's form, and closes the menu.
    const enter = trusted(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    field.dispatchEvent(enter);
    expect(enter.defaultPrevented).toBe(false);
    expect(posted.at(-1)).toEqual({ type: "login-dismiss" });

    passwords.menu("highlighted");
    const choose = trusted(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    field.dispatchEvent(choose);
    expect(choose.defaultPrevented).toBe(true);
    expect(posted.at(-1)).toEqual({ type: "login-key", key: "enter" });
  });

  it("closes a menu Swift is still preparing when the person moves on", () => {
    // The account list loads asynchronously; leaving the field before it
    // arrives must still reach Swift, or the menu opens under a field left behind.
    const doc = freshDocument(`<form><input id="u"><input id="p" type="password"></form><input id="search" type="search">`);
    start(true, doc);
    doc.getElementById("u")!.dispatchEvent(trusted(new FocusEvent("focusin", { bubbles: true })));
    doc.getElementById("search")!.dispatchEvent(trusted(new FocusEvent("focusin", { bubbles: true })));
    expect(posted.at(-1)).toEqual({ type: "login-dismiss" });
  });

  it("lets the person close a menu with nothing to pick, keeping the keys for the page", () => {
    // The http warning: shown, but arrows still belong to the field.
    const doc = freshDocument(`<form><input id="u"><input id="p" type="password"></form>`);
    const passwords = start(true, doc);
    const field = doc.getElementById("u")!;
    field.dispatchEvent(trusted(new FocusEvent("focusin", { bubbles: true })));
    passwords.menu("shown");
    posted = [];

    const down = trusted(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true, cancelable: true }));
    field.dispatchEvent(down);
    expect(down.defaultPrevented).toBe(false);
    expect(posted).toEqual([]);

    field.dispatchEvent(trusted(new KeyboardEvent("keydown", { key: "x", bubbles: true, cancelable: true })));
    expect(posted).toEqual([{ type: "login-dismiss" }]);
  });

  it("closes the menu when focus leaves for nowhere, but not when the web view loses focus", () => {
    vi.useFakeTimers();
    try {
      const doc = freshDocument(`<form><input id="u"><input id="p" type="password"></form>`);
      start(true, doc);
      const field = doc.getElementById("u")!;
      field.dispatchEvent(trusted(new FocusEvent("focusin", { bubbles: true })));
      posted = [];

      // A click on the menu itself: the whole document loses focus.
      const hasFocus = vi.spyOn(doc, "hasFocus").mockReturnValue(false);
      field.dispatchEvent(new FocusEvent("focusout", { bubbles: true }));
      vi.runAllTimers();
      expect(posted).toEqual([]);

      // A click on the page's background: the document keeps focus, the field doesn't.
      hasFocus.mockReturnValue(true);
      field.dispatchEvent(new FocusEvent("focusout", { bubbles: true }));
      vi.runAllTimers();
      expect(posted).toEqual([{ type: "login-dismiss" }]);
    } finally {
      vi.useRealTimers();
    }
  });

  it("locates the first sign-in on the page for the menu command", () => {
    const doc = freshDocument(`<form><input type="search"></form><form><input id="u"><input id="p" type="password"></form>`);
    expect(firstLoginField(doc)?.id).toBe("u");
  });
});
