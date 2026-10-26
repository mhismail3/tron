import { TEST_SETTINGS_SCHEMA } from "./settings-schema.js";
import { randomUUID } from "node:crypto";
import { createQueueSummarizer } from "../src/episodic/episodic-compactor.js";
import { ModelQueueOwner } from "../src/providers/model-queue.js";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { SettingsStoreAdapter } from "../src/admin/settings-model.js";
import { SettingsChangePath, type ExpiryScheduler } from "../src/kernel/settings/settings-change.js";
import { SettingsModel } from "../src/kernel/settings/settings-model.js";
import { SettingsChangeRecord } from "../src/kernel/settings/settings-record.js";
import { SettingsApprovals } from "../src/kernel/settings/settings-approvals.js";
import type { TrustService } from "../src/kernel/resources/trust-service.js";
import type { HomeOwner } from "../src/modules/home/home-owner.js";
import type { RuntimeRegistry } from "../src/kernel/session/runtime-registry.js";
import { HomeProfileItems } from "../src/modules/home/home-profile.js";
import type { KnowledgeService } from "../src/knowledge/knowledge-service.js";
import { homeOwnerOf } from "./gateway-registry.js";

/** The real settings model and change path a fixture Gateway needs, wired the
 * way gateway-main wires them (docs/settings-model.md). */
export function settingsDependencies(input: {
  agentDir: string;
  tronHome: string;
  trust: TrustService;
  modelRuntime: ModelRuntime;
  sessions?: { reloadProject(cwd: string, trusted: boolean, force: boolean): Promise<unknown>; commitProjectReload(cwd: string): Promise<unknown> | unknown };
  home?: () => HomeOwner | undefined;
  /** The learned profile's Knowledge owner, for Home's `profile` tool (doc 6.4). */
  knowledge?: () => KnowledgeService | undefined;
  /** Installs them for the `settings` tool, as gateway-main does. */
  registry?: { setSettings(model: SettingsModel, changes: SettingsChangePath): void };
  /** The change path's clock; a fixture advances it to test expiry. */
  now?: () => Date;
  /** The pending-approval deadline scheduler; a fixture fires it after advancing the clock. */
  schedule?: ExpiryScheduler;
  /** Option catalog for `catalog.tools` keys, wired as gateway-main wires it. */
  toolCatalog?: ConstructorParameters<typeof SettingsStoreAdapter>[0]["toolCatalog"];
}): { settingsModel: SettingsModel<SettingsStoreAdapter>; settingsChanges: SettingsChangePath } {
  const settingsModel = new SettingsModel(new SettingsStoreAdapter({ schema: TEST_SETTINGS_SCHEMA,
    agentDir: input.agentDir, tronHome: input.tronHome, trust: input.trust, modelRuntime: input.modelRuntime,
    ...(input.toolCatalog ? { toolCatalog: input.toolCatalog } : {}),
  }));
  const settingsChanges: SettingsChangePath = new SettingsChangePath(settingsModel, new SettingsChangeRecord(input.tronHome), new SettingsApprovals(input.tronHome), {
    setTrust: async (project, decision) => {
      return input.trust.setAndApply(project, decision,
        async (inspection) => { await input.sessions?.reloadProject(inspection.cwd, inspection.effectiveDecision === true, false); },
        async (inspection) => { await input.sessions?.commitProjectReload(inspection.cwd); });
    },
    ...(input.knowledge ? { undoSubject: (entry, context) => new HomeProfileItems(() => input.knowledge?.()).undo(settingsChanges, entry, context) } : {}),
  }, input.now, input.schedule);
  input.registry?.setSettings(settingsModel, settingsChanges);
  return { settingsModel, settingsChanges };
}

/** Sets a model queue through the one settings change path, as the iPhone's
 * Manage Home does (docs/settings-model.md 6.3), installing the settings owners
 * on the registry first when the fixture has none. Home's memory and Knowledge
 * run on the background queue. */
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

/** Home memory's models, set the way the iPhone sets them: the background model
 * queue through the settings change path, on a registry built with a Gateway model runtime. */
export async function setHomeMemoryModels(registry: RuntimeRegistry,
  models: readonly (string | { provider: string; id: string })[]): Promise<void> {
  const internals = registry as unknown as {
    options: { agentDir: string; tronHome: string; trust: TrustService; gatewayModelRuntime?: ModelRuntime };
    dependencies(): { createModelRuntime(): Promise<ModelRuntime> };
  };
  const options = internals.options;
  // A registry without a Gateway runtime admits through its own runtime factory.
  const modelRuntime = options.gatewayModelRuntime ?? await internals.dependencies().createModelRuntime();
  await setModelQueue({ registry, agentDir: options.agentDir, tronHome: options.tronHome, trust: options.trust, modelRuntime }, "background", models);
}

/** The production background-queue summarizer over one fixed model, for episodic
 * cases that exercise the compactor's own request against a real provider. */
export function singleModelSummarizer(runtime: ModelRuntime, model: { provider: string; id: string }) {
  return createQueueSummarizer(new ModelQueueOwner({ runtime, usage: { read: async () => ({ providers: [] }) }, queue: async () => [`${model.provider}/${model.id}`] }));
}
