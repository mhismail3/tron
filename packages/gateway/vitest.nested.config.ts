import { defineConfig } from "vitest/config";

/** Test files that run nested vitest or real pi children, or activate the real
 * managed pi-subagents install offline. Each boots its own runtime or install under
 * execFile, detached-process or wait bounds, and under the parallel pass they starve
 * and miss those bounds (#655, #707). They run one file at a time
 * in their own pass after the parallel suite; the main config excludes this list. */
export const nestedTestFiles = [
  "src/sessions/managed-attribution.integration.test.ts",
  "src/sessions/managed-subagents.integration.test.ts",
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
    // run one file at a time on a shared host; their waits and test timeouts are hang
    // bounds (test-support/wait-for.ts), never speed budgets, so this pass declares
    // them once: 240 s waits under a 300 s test timeout. A clean run takes ~20 s; the
    // bounds only turn a genuine hang into a named failure. The main pass keeps 12 s/15 s.
    testTimeout: 300_000,
    env: { TRON_TEST_WAIT_HANG_BOUND_MS: "240000" },
    setupFiles: ["test-support/network-isolation.ts", "test-support/tron-home-environment-guard.ts"],
  },
});
