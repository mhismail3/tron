import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test-fixtures/pi-sdk/record-corpus.integration.test.ts", "test-fixtures/tron-corpus/record-tron-corpus.integration.test.ts"],
    environment: "node",
    testTimeout: 180_000,
    setupFiles: ["test-support/network-isolation.ts", "test-support/tron-home-environment-guard.ts"],
  },
});
