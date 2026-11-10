import { availableParallelism } from "node:os";
import { defineConfig } from "vitest/config";
import { macTerminalTestFiles } from "./vitest.mac-terminal.config.js";
import { nestedTestFiles } from "./vitest.nested.config.js";

export default defineConfig({
  test: {
    include: ["src/**/*.test.ts"],
    exclude: [...nestedTestFiles, ...macTerminalTestFiles],
    environment: "node",
    maxWorkers: Math.min(4, availableParallelism()),
    testTimeout: 15_000,
    setupFiles: ["test-support/network-isolation.ts", "test-support/tron-home-environment-guard.ts"],
  },
});
