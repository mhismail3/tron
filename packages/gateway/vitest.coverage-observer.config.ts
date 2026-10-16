import { defineConfig } from "vitest/config";
import base from "./vitest.config.js";

const setupFiles = Array.isArray(base.test?.setupFiles) ? base.test.setupFiles : [];

// This config is only for explicit no-skip coverage observations. Preserve the
// default config's pool, timeout, global setup and existing setup hooks.
export default defineConfig({
  ...base,
  test: {
    ...base.test,
    setupFiles: [...setupFiles, "test-support/gate-coverage-flush.ts"],
  },
});
