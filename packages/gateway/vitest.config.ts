import { availableParallelism } from "node:os";
import { defineConfig } from "vitest/config";
import { macTerminalTestFiles } from "./vitest.mac-terminal.config.js";
import { nestedTestFiles } from "./vitest.nested.config.js";

export default defineConfig({
  test: {
    include: ["src/**/*.test.ts"],
    exclude: [...nestedTestFiles, ...macTerminalTestFiles],
    environment: "node",
    // Durable filesystem/SQLite fixtures and SDK child processes share the
    // host. CPU-count fanout starves their owners; bound concurrency rather
    // than weakening assertions or extending the behavioral deadlines. Under a
    // heavy-queue grant (TRON_HEAVY_CORES) the workers match the cores admitted.
    maxWorkers: Math.min(4, Number(process.env.TRON_HEAVY_CORES) || availableParallelism()),
    globalSetup: ["test-support/heavy-lease.ts"],
    testTimeout: 15_000,
    setupFiles: ["test-support/network-isolation.ts", "test-support/tron-home-environment-guard.ts"],
  },
});
