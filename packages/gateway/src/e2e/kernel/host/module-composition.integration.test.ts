import { mkdtemp, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { TrustService } from "../../../kernel/resources/trust-service.js";
import { TEST_SETTINGS_SCHEMA } from "../../../../test-support/settings-schema.js";
import { DisplayOwner } from "../../../display/display-modules.js";
import { DisplayArtifactStore } from "../../../display/display-artifact-store.js";
import { RuntimeRegistry } from "../../../kernel/session/runtime-registry.js";
import { workspaceModule } from "../../../workspace/workspace-module.js";
import { OpenAIModelEligibility } from "../../../providers/openai-model-eligibility.js";
import { createProviderModelRuntime } from "../../../providers/provider-runtime.js";
import { gatewayModules } from "../../../main/modules.js";
import { ModuleHost } from "../../../kernel/host/module-host.js";

/** The production module composition under a real `RuntimeRegistry` (kernel.md §2.1):
 * the kernel's resource root is the workspace module's own contract, one authority. */

const log = { log: () => {} };
const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });

describe("kernel/host production composition", () => {
  it("composes the production modules into a registry with one workspace authority", async () => {
    const root = await realpath(await mkdtemp(join(tmpdir(), "tron-module-host-")));
    roots.push(root);
    const tronHome = join(root, "tron");
    const trust = new TrustService(join(root, "agent"));
    const openAIModelEligibility = new OpenAIModelEligibility();
    const display = new DisplayOwner(new DisplayArtifactStore(tronHome), undefined, () => registry);
    const composition = gatewayModules(() => ({ registry, display, openAIModelEligibility, home: { tronHome, agentDir: join(root, "agent"), trust, knowledge: () => undefined, settings: () => undefined } }));
    const modules = await ModuleHost.start(composition.modules, { tronHome, log }, composition.runtimeOrder);
    const registry = new RuntimeRegistry({
      settingsSchema: TEST_SETTINGS_SCHEMA,
      modules, agentDir: join(root, "agent"), tronHome, idleRuntimeMs: 60_000, trust,
      beforeSessionRekey: (previousId, nextId, runtime) => display.grantReferences(previousId, nextId, runtime),
      createModelRuntime: () => createProviderModelRuntime(join(root, "agent")),
      broadcast: () => {}, sessionSummaryChanged: () => {}, sessionListChanged: () => {},
    });
    try {
      const workspace = modules.policy("resourceRoot")!();
      expect(workspace).toBe(modules.contract(workspaceModule));
      expect((await workspace.describe()).root).toBe(join(tronHome, "workspace"));
    } finally {
      await registry.dispose();
      await modules.stop();
    }
  });
});
