import { TEST_SETTINGS_SCHEMA } from "./settings-schema.js";
import { randomUUID } from "node:crypto";
import { createQueueSummarizer } from "../src/episodic/episodic-compactor.js";
import { ModelQueueOwner } from "../src/providers/model-queue.js";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { SettingsStoreAdapter } from "../src/admin/settings-model.js";
import { SettingsChangePath } from "../src/kernel/settings/settings-change.js";
import { SettingsModel } from "../src/kernel/settings/settings-model.js";
import { SettingsChangeRecord } from "../src/kernel/settings/settings-record.js";
import type { TrustService } from "../src/kernel/resources/trust-service.js";
import type { HomeOwner } from "../src/modules/home/home-owner.js";
import type { RuntimeRegistry } from "../src/kernel/session/runtime-registry.js";
import { HomeProfileItems } from "../src/modules/home/home-profile.js";
import type { ProfileStore } from "../src/modules/home/profile-store.js";
import { homeOwnerOf, projectsOwnerOf } from "./gateway-registry.js";
import { HookResources } from "../src/admin/hook-resources.js";
import { PackageService } from "../src/admin/package-service.js";
import { McpAdminService } from "../src/admin/mcp-admin-service.js";
import { SettingsInventoryReader } from "../src/admin/settings-inventory.js";
import type { SettingsInventorySource } from "../src/kernel/settings/tool-contract.js";
import type { ModuleHost } from "../src/kernel/host/module-host.js";
import { piCliBundle } from "../src/kernel/pi/packages.js";

export function settingsInventorySource(input: { agentDir: string; trust: TrustService; modules: ModuleHost; mcp: McpAdminService }): SettingsInventorySource {
  return new SettingsInventoryReader(new HookResources(input.agentDir, input.trust), new PackageService(input.agentDir, input.trust, () => {}), input.mcp, input.trust, input.modules);
}

export function settingsDependencies(input: {
  agentDir: string;
  tronHome: string;
  trust: TrustService;
  modelRuntime: ModelRuntime;
  sessions?: { reloadProject(cwd: string, trusted: boolean, force: boolean): Promise<unknown>; commitProjectReload(cwd: string): Promise<unknown> | unknown; abortProjectReload(cwd: string): Promise<unknown> | unknown };
  home?: () => HomeOwner | undefined;
  knowledge?: () => ProfileStore | undefined;
  registry?: { setSettings(model: SettingsModel, changes: SettingsChangePath, inventory: SettingsInventorySource): void; moduleHost: ModuleHost };
  now?: () => Date;
  toolCatalog?: ConstructorParameters<typeof SettingsStoreAdapter>[0]["toolCatalog"];
}): { settingsModel: SettingsModel<SettingsStoreAdapter>; settingsChanges: SettingsChangePath } {
  const settingsModel = new SettingsModel(new SettingsStoreAdapter({ schema: TEST_SETTINGS_SCHEMA,
    agentDir: input.agentDir, tronHome: input.tronHome, trust: input.trust, modelRuntime: input.modelRuntime,
    ...(input.toolCatalog ? { toolCatalog: input.toolCatalog } : {}),
  }));
  const settingsChanges: SettingsChangePath = new SettingsChangePath(settingsModel, new SettingsChangeRecord(input.tronHome), {
    setTrust: async (project, decision) => {
      return input.trust.setAndApply(project, decision,
        async (inspection) => { await input.sessions?.reloadProject(inspection.cwd, inspection.effectiveDecision === true, false); },
        async (inspection) => { await input.sessions?.commitProjectReload(inspection.cwd); },
        async (inspection) => { await input.sessions?.abortProjectReload(inspection.cwd); });
    },
    ...(input.knowledge ? { undoSubject: (entry, context) => new HomeProfileItems(() => input.knowledge?.()).undo(settingsChanges, entry, context) } : {}),
  }, input.now);
  if (input.registry) {
    input.registry.setSettings(settingsModel, settingsChanges, settingsInventorySource({ agentDir: input.agentDir, trust: input.trust, modules: input.registry.moduleHost, mcp: new McpAdminService(input.agentDir, piCliBundle()) }));
    projectsOwnerOf(input.registry)?.register(settingsChanges);
  }
  return { settingsModel, settingsChanges };
}

export async function setModelQueue(input: {
  registry: RuntimeRegistry;
  agentDir: string; tronHome: string; trust: TrustService; modelRuntime: ModelRuntime;
}, role: "worker" | "subagent" | "background", models: readonly (string | { provider: string; id: string })[]): Promise<void> {
  const installed = (input.registry as unknown as { settingsOwners?: { changes: SettingsChangePath } }).settingsOwners;
  const changes = installed?.changes ?? settingsDependencies({ ...input, home: () => homeOwnerOf(input.registry) }).settingsChanges;
  const value = models.map(model => typeof model === "string" ? model : `${model.provider}/${model.id}`);
  await changes.change({ kind: "home" }, [{ key: `model.queue[role=${role}]`, layer: "session", op: "set", value }],
    { actor: { kind: "ui", id: "fixture" }, commandId: randomUUID() });
}

export async function setHomeMemoryModels(registry: RuntimeRegistry,
  models: readonly (string | { provider: string; id: string })[]): Promise<void> {
  const internals = registry as unknown as {
    options: { agentDir: string; tronHome: string; trust: TrustService; gatewayModelRuntime?: ModelRuntime };
    dependencies(): { createModelRuntime(): Promise<ModelRuntime> };
  };
  const options = internals.options;
  const modelRuntime = options.gatewayModelRuntime ?? await internals.dependencies().createModelRuntime();
  await setModelQueue({ registry, agentDir: options.agentDir, tronHome: options.tronHome, trust: options.trust, modelRuntime }, "background", models);
}

export function singleModelSummarizer(runtime: ModelRuntime, model: { provider: string; id: string }, tronHome: string) {
  return createQueueSummarizer(new ModelQueueOwner({ tronHome, runtime, usage: { read: async () => ({ providers: [] }) }, queue: async () => [`${model.provider}/${model.id}`] }));
}
