import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    globalSetup: "./global-setup.ts",
    testTimeout: 30_000,
    hookTimeout: 30_000,
    // Run test files sequentially — each file truncates + re-seeds the shared
    // SQLite database, so parallel file execution causes race conditions.
    fileParallelism: false,
    // Within each file, tests also run sequentially (default, but explicit).
    sequence: { concurrent: false },
  },
});
