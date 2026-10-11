import { availableParallelism } from "node:os";
import { defineConfig } from "vitest/config";
import { nestedTestFiles } from "./vitest.nested.config.js";

// `work verify` runs heavy checks in host-wide slots and gives each one its CPU
// share, so concurrent verifies cannot each fan out to the whole host.
const verifyCpuShare = Number(process.env.VERIFY_CPU_SHARE);

export default defineConfig({
  test: {
    include: ["src/**/*.test.ts"],
    exclude: nestedTestFiles,
    environment: "node",
    // Durable filesystem/SQLite fixtures and SDK child processes share the
    // host. CPU-count fanout starves their owners; bound concurrency rather
    // than weakening assertions or extending the behavioral deadlines.
    // A verify slot's CPU share can only lower this bound, never widen it.
    maxWorkers: Math.min(4, availableParallelism(),
      Number.isInteger(verifyCpuShare) && verifyCpuShare > 0 ? verifyCpuShare : Infinity),
    testTimeout: 15_000,
    setupFiles: ["test-support/network-isolation.ts", "test-support/tron-home-environment-guard.ts"],
  },
});
