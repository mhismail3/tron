import { defineConfig } from "vitest/config";

/** Test files that run nested vitest or real pi children. Each child boots its own
 * runtime under execFile or detached-process bounds, and under the parallel pass
 * those children starve and miss their bounds (#655). They run one file at a time
 * in their own pass after the parallel suite; the main config excludes this list. */
export const nestedTestFiles = [
  "src/sessions/managed-attribution.integration.test.ts",
  "src/sessions/managed-subagents.invalid-entry.test.ts",
  "src/sessions/managed-subagents.rollback.test.ts",
  "src/sessions/managed-subagents.test.ts",
  "src/sessions/runtime-terminal-notifications.integration.test.ts",
  "src/sessions/subagent-parity.integration.test.ts",
];

export default defineConfig({
  test: {
    include: nestedTestFiles,
    environment: "node",
    fileParallelism: false,
    maxWorkers: 1,
    // Same as vitest.config.ts; the two configs must not drift on the test environment.
    testTimeout: 15_000,
    setupFiles: ["test-support/network-isolation.ts", "test-support/tron-home-environment-guard.ts"],
  },
});
