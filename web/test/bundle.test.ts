// @vitest-environment node
//
// Node, not jsdom: esbuild refuses to run against jsdom's `TextEncoder`, and
// nothing here needs a DOM.

import { build, type BuildOptions } from "esbuild";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

// What a page costs that asks for nothing.
//
// Every assertion here is about the same thing: the bundle injected at
// `document-start` into every page in every tab must carry only what a page that
// never enters lens mode actually runs. Both halves regress silently — a stray
// `import` re-inlines 36KB of editor into every pageview and every test still
// passes, and a lens engine started on a page with no lenses shows up as nothing
// worse than a `<style>` nobody looks at.

const here = dirname(fileURLToPath(import.meta.url));

/** Build one of the real bundles, in memory. The configuration comes from
 * `build.mjs` itself rather than a copy of it: a copy would keep passing after
 * the build stopped matching it. The specifier is computed so TypeScript does
 * not try to resolve types for a `.mjs` build script. */
async function bundled(name: string): Promise<string> {
  const config = (await import(new URL("../build.mjs", import.meta.url).href)) as {
    bundles: BuildOptions[];
  };
  const options = config.bundles.find((entry) => (entry.outfile ?? "").endsWith(name));
  expect(options, `build.mjs builds ${name}`).toBeDefined();

  const result = await build({ ...options, write: false, logLevel: "silent" });
  return (result.outputFiles ?? []).map((file) => file.text).join("");
}

/** Two strings that exist only in `lens/editor.ts`: the overlay's host id, and
 * the name an unnamed lens gets. Either one in the document-start bundle means
 * the editor is back in it. */
const EDITOR_ONLY = ["zentic-lens-editor", "New Lens"];

describe("the document-start bundle", () => {
  it("does not carry the lens editor", async () => {
    const js = await bundled("zentic.js");
    for (const marker of EDITOR_ONLY) expect(js).not.toContain(marker);
  }, 30_000);

  it("builds the editor as a second bundle that publishes itself", async () => {
    const js = await bundled("zentic-lens-editor.js");
    for (const marker of EDITOR_ONLY) expect(js).toContain(marker);
    // The whole contract between the two bundles. `main.ts` reads this property
    // and nothing else; if the entry point stopped writing it, ⌥⌘L would report a
    // failure on every page.
    expect(js).toContain("__zenticLensEditor");
  }, 30_000);

  it("imports the editor for its type only", () => {
    const main = readFileSync(join(here, "..", "src", "main.ts"), "utf8");
    const imports = main.match(/^import[^;]*from "\.\/lens\/editor\.js";$/gm) ?? [];
    expect(imports).toHaveLength(1);
    // `import type` is erased by esbuild. A value import of the same module is a
    // one-character edit away and costs 36KB on every page load.
    expect(imports[0]).toMatch(/^import type /);
  });

  it("keeps every identifier through minification", async () => {
    const js = await bundled("zentic.js");
    // `minifyWhitespace` rather than `minify`: names are what makes a Web
    // Inspector stack trace legible, and they are what we are paying for by
    // giving up line numbers.
    expect(js).toContain("VisibilityController");
    expect(js).toContain("LensEngine");
    expect(js).toContain("runPass");
  }, 30_000);
});

