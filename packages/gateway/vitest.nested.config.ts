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
    // Every file here waits on real pi/SDK/vitest children, which start in seconds and
    // run one file at a time; their waits are hang bounds (test-support/wait-for.ts),
    // so this pass declares its own: 45 s waits under a 60 s test timeout, which most
    // of these files already set per test. The main pass keeps 12 s under 15 s.
    testTimeout: 60_000,
    env: { TRON_TEST_WAIT_HANG_BOUND_MS: "45000" },
    setupFiles: ["test-support/network-isolation.ts", "test-support/tron-home-environment-guard.ts"],
  },
});
