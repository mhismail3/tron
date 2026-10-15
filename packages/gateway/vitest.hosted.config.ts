import { defineConfig } from "vitest/config";
import base from "./vitest.config.js";
import { nestedTestFiles } from "./vitest.nested.config.js";

/** Hosted CI's Gateway tests (`scripts/tron ci gateway.integration`, #1026).
 *
 * Hosted runners are small shared VMs, so CI runs only the integration files whose
 * outcome does not depend on how fast the host is. Every E2E journey, the nested
 * SDK pass and the files below stay in the local landing gate (`npm test`), which
 * runs them on every Gateway change; they are not skipped, only not run here.
 *
 * A file joins this list only with the hosted failure that proves its timing
 * dependence. Keep the reason next to it. */
export const hostedTimingSensitiveFiles = [
  // MCP stdio reaper and codemode live projection race the runner's scheduler:
  // "Invalid owned MCP fixture PID", nested-call order (CI runs 38423418437 and later).
  "src/sessions/runtime-registry.integration.test.ts",
  // F9 delegates a Home worker and expects it running, not queued for a slot
  // ("Task admitted and queued at position 1"), on three hosted runs since 2026-10-10.
  "src/sessions/home-profile.integration.test.ts",
];

// The main config's workers, timeout and setup; only the file set differs.
export default defineConfig({
  test: {
    ...base.test,
    include: ["src/**/*.integration.test.ts"],
    exclude: [...nestedTestFiles, ...hostedTimingSensitiveFiles],
  },
});
