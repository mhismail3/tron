import { availableParallelism } from "node:os";
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["src/**/*.test.ts"],
    exclude: ["src/**/*.scale.test.ts"],
    environment: "node",
    // Durable filesystem/SQLite fixtures and SDK child processes share the
    // host. CPU-count fanout starves their owners; bound concurrency rather
    // than weakening assertions or extending the behavioral deadlines.
    maxWorkers: Math.min(4, availableParallelism()),
    testTimeout: 15_000,
    setupFiles: ["test-support/agent-dir-isolation.ts", "test-support/network-isolation.ts"],
  },
});
