import { defineConfig } from "vitest/config";

export const nestedTestFiles = [
  "src/e2e/modules/home/home-task-subagents-controls.e2e.test.ts",
  "src/lifecycle/exit-after-shutdown.e2e.test.ts",
  "src/e2e/transport/gateway-process-prompt.e2e.test.ts",
  "src/e2e/transport/gateway-process-restart.e2e.test.ts",
  "src/e2e/automations/automation-home-process.e2e.test.ts",
  "src/e2e/kernel/delegation/delegation-process.e2e.test.ts",
  "src/e2e/kernel/delegation/managed-subagents-warm-process.e2e.test.ts",
  "src/e2e/admin/settings-process.e2e.test.ts",
  "src/e2e/admin/native-change-process.e2e.test.ts",
  "src/e2e/workspace/web-research-child.integration.test.ts",
  "src/e2e/kernel/delegation/child-browser.integration.test.ts",
  "src/e2e/workspace/web-research-resume.integration.test.ts",
  "src/e2e/kernel/delegation/managed-subagents.rollback.integration.test.ts",
  "src/kernel/delegation/managed-subagents.install.integration.test.ts",
  "src/e2e/sessions/runtime-terminal-notifications.integration.test.ts",
  "src/e2e/kernel/delegation/delegation.lock.integration.test.ts",
  "src/e2e/kernel/delegation/process-transcript-stop.integration.test.ts",
  "src/e2e/kernel/delegation/managed-run-stop-drain.e2e.test.ts",
];

export default defineConfig({
  test: {
    include: nestedTestFiles,
    environment: "node",
    fileParallelism: false,
    maxWorkers: 1,
    testTimeout: 300_000,
    env: { TRON_TEST_WAIT_HANG_BOUND_MS: "240000" },
    setupFiles: ["test-support/network-isolation.ts", "test-support/tron-home-environment-guard.ts"],
  },
});
