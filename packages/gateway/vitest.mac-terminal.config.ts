import { defineConfig } from "vitest/config";

export const macTerminalTestFiles = ["src/e2e/security/mac-terminal.e2e.test.ts", "src/security/mac-terminal-service.e2e.test.ts"];

export default defineConfig({
  test: {
    include: macTerminalTestFiles,
    environment: "node",
    fileParallelism: false,
    maxWorkers: 1,
    testTimeout: 180_000,
    setupFiles: ["test-support/network-isolation.ts", "test-support/tron-home-environment-guard.ts"],
  },
});
