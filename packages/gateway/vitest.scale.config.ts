import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["src/**/*.scale.test.ts"],
    environment: "node",
    pool: "forks",
    isolate: true,
    testTimeout: 60_000,
  },
});
