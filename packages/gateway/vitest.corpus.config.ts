import { defineConfig } from "vitest/config";

/**
 * The persisted-state corpus recorder's configuration (#471).
 *
 * Recording rewrites committed fixtures, so it is never part of the default
 * run: `vitest.config.ts` includes only `src/**\/*.test.ts`, and the recorder
 * lives next to the corpus it writes. Run it with `npm run record:pi-corpus`.
 */
export default defineConfig({
  test: {
    include: ["test-fixtures/pi-sdk/record-corpus.test.ts"],
    environment: "node",
    // The recorder is a generator, not a timed test: it drives MCP servers, an
    // OAuth sign-in and two Gateway sessions, then reopens the corpus. Its
    // internal waits still use the shared hang bound.
    testTimeout: 180_000,
    setupFiles: ["test-support/network-isolation.ts", "test-support/tron-home-environment-guard.ts"],
  },
});
