import { createTestRegistry } from "../../../test-support/gateway-registry.js";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { TrustService } from "../resources/trust-service.js";

import { initializeRegistry, temporaryRoot } from "../../../test-support/runtime-registry-fixture.js";
import { waitFor } from "../../../test-support/wait-for.js";

// Port: the Pi seam's process-global theme (kernel/pi `initTheme`, K-0 §4).
// Invariant: a Gateway composition pins Pi's global theme before any runtime exists, so a
// runtime extension that reads it through Pi's public helpers renders instead of throwing
// "Theme not initialized".
describe("gateway/pi process-global theme", () => {
  it("is initialized for runtime extensions that read it through Pi's public helpers", async () => {
    const root = await temporaryRoot("tron-pi-theme-");
    const agentDir = join(root, "agent");
    const cwd = join(root, "workspace");
    const extensionDir = join(cwd, ".pi", "extensions");
    await mkdir(extensionDir, { recursive: true });
    await writeFile(join(extensionDir, "global-theme.ts"), `import { getMarkdownTheme } from "@earendil-works/pi-coding-agent";
export default function (pi) {
  pi.on("session_start", (_event, ctx) => {
    let outcome;
    try {
      outcome = getMarkdownTheme().heading("Heading").includes("Heading") ? "rendered" : "empty";
    } catch (error) {
      outcome = "threw: " + (error instanceof Error ? error.message : String(error));
    }
    ctx.ui.setStatus("global-theme", outcome);
  });
}\n`);
    const trust = new TrustService(agentDir);
    await trust.set(cwd, true);
    const registry = await createTestRegistry({
      agentDir, tronHome: join(root, "tron"), idleRuntimeMs: 60_000, trust,
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    try {
      await initializeRegistry(registry);
      const slot = await registry.create(cwd);
      const status = () => slot.snapshot().extensionPresentation.semanticState.statuses["global-theme"];
      await waitFor(() => status() !== undefined, "the extension's theme status");
      expect(status()).toBe("rendered");
    } finally {
      await registry.dispose();
    }
  });
});
