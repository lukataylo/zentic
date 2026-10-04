import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "jsdom",
    globals: true,
    include: ["test/**/*.test.ts"],
    pool: "forks",
  },
  define: {
    __ZENTIC_VERSION__: JSON.stringify("0.0.0-test"),
  },
});
