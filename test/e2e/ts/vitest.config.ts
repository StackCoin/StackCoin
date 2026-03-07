import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    globalSetup: "./global-setup.ts",
    testTimeout: 30_000,
    hookTimeout: 30_000,
  },
});
