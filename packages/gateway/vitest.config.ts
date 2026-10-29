import { availableParallelism } from "node:os";
import { defineConfig } from "vitest/config";
import { macTerminalTestFiles } from "./vitest.mac-terminal.config.js";
import { nestedTestFiles } from "./vitest.nested.config.js";

const nativePublication = [
  "src/machine/native-app-metadata.integration.test.ts", "src/machine/native-directory-publish.integration.test.ts", "src/modules/apps/apps-publication.integration.test.ts",
  "src/modules/apps/apps-metadata.integration.test.ts", "src/modules/apps/apps-canonical-display.integration.test.ts", "src/modules/apps/apps-reference-publication.integration.test.ts",
  "src/display/display-image-lifetime.integration.test.ts", "src/kernel/projection/tool-result.integration.test.ts",
  "src/kernel/projection/codemode-nested-presentation.integration.test.ts",
  "src/workspace/tron-workspace.integration.test.ts", "src/sessions/runtime-registry.integration.test.ts",
];
const shared = {
  environment: "node" as const,
  testTimeout: 15_000,
  setupFiles: ["test-support/network-isolation.ts", "test-support/tron-home-environment-guard.ts"],
};

export default defineConfig({
  test: {
    // Durable filesystem/SQLite fixtures and SDK child processes share the
    // host. CPU-count fanout starves their owners; bound concurrency rather
    // than weakening assertions or extending the behavioral deadlines.
    maxWorkers: Math.min(4, availableParallelism()),
    projects: [
      { test: { ...shared, name: "gateway", include: ["src/**/*.test.ts"], exclude: [...nestedTestFiles, ...macTerminalTestFiles, ...nativePublication] } },
      { test: { ...shared, name: "native-publication", include: nativePublication, globalSetup: ["test-support/native-publication-global-setup.ts"], setupFiles: [...shared.setupFiles, "test-support/native-publication-runtime.ts"] } },
    ],
  },
});
