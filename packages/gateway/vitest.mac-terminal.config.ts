import { defineConfig } from "vitest/config";

/** Mac Terminal's journey (README "Mac Terminal") drives a real sshd on this
 * Mac's Tailscale address with the iPhone app's Swift SSH client, so it needs
 * the host on its tailnet and a Swift 6.2 toolchain. It runs on request
 * (`npm run test:mac-terminal`, and `work land --tests` for changes to it),
 * not in the hosted `npm test` pass, whose runners have neither. */
export const macTerminalTestFiles = ["src/security/mac-terminal.e2e.test.ts"];

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
