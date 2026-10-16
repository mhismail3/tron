import { randomUUID } from "node:crypto";
import { createQueueSummarizer } from "../src/episodic/episodic-compactor.js";
import { ModelQueueOwner } from "../src/providers/model-queue.js";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { SettingsChangePath, SettingsModel } from "../src/admin/settings-model.js";
import { SettingsChangeRecord } from "../src/admin/settings-record.js";
import { SettingsApprovals } from "../src/admin/settings-approvals.js";
import type { TrustService } from "../src/admin/trust-service.js";
import type { HomeOwner } from "../src/home/home-owner.js";
import { HomeProfileItems } from "../src/home/home-profile.js";
import type { KnowledgeService } from "../src/knowledge/knowledge-service.js";

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
}): { settingsModel: SettingsModel; settingsChanges: SettingsChangePath } {
  const settingsModel = new SettingsModel({
    agentDir: input.agentDir, tronHome: input.tronHome, trust: input.trust, modelRuntime: input.modelRuntime,
  });
  const settingsChanges = new SettingsChangePath(settingsModel, new SettingsChangeRecord(input.tronHome), new SettingsApprovals(input.tronHome), {
    setTrust: async (project, decision) => {
      return input.trust.setAndApply(project, decision,
        async (inspection) => { await input.sessions?.reloadProject(inspection.cwd, inspection.effectiveDecision === true, false); },
        async (inspection) => { await input.sessions?.commitProjectReload(inspection.cwd); });
    },
    ...(input.knowledge ? { profile: new HomeProfileItems(input.knowledge) } : {}),
  }, input.agentDir, input.now);
  input.registry?.setSettings(settingsModel, settingsChanges);
  return { settingsModel, settingsChanges };
}

/** Sets a model queue through the one settings change path, as the iPhone's
 * Manage Home does (docs/settings-model.md 6.3), installing the settings owners
 * on the registry first when the fixture has none. Home's memory and Knowledge
 * run on the background queue. */
export async function setModelQueue(input: {
  registry: { setSettings(model: SettingsModel, changes: SettingsChangePath): void; homeOwner(): HomeOwner };
  agentDir: string; tronHome: string; trust: TrustService; modelRuntime: ModelRuntime;
}, role: "worker" | "subagent" | "background", models: readonly (string | { provider: string; id: string })[]): Promise<void> {
  const installed = (input.registry as unknown as { settingsOwners?: { changes: SettingsChangePath } }).settingsOwners;
  const changes = installed?.changes ?? settingsDependencies({ ...input, home: () => input.registry.homeOwner() }).settingsChanges;
  const value = models.map(model => typeof model === "string" ? model : `${model.provider}/${model.id}`);
  await changes.change({ kind: "home" }, [{ key: `model.queue[role=${role}]`, layer: "profile", op: "set", value }],
    { actor: { kind: "ui", id: "fixture" }, commandId: randomUUID() });
}

/** Home memory's models, set the way the iPhone sets them: the background model
 * queue through the settings change path, on a registry built with a Gateway model runtime. */
export async function setHomeMemoryModels(registry: { setSettings(model: SettingsModel, changes: SettingsChangePath): void; homeOwner(): HomeOwner },
  models: readonly (string | { provider: string; id: string })[]): Promise<void> {
  const options = (registry as unknown as { options: { agentDir: string; tronHome: string; trust: TrustService; gatewayModelRuntime?: ModelRuntime } }).options;
  if (!options.gatewayModelRuntime) throw new Error("Home memory models need a registry with a Gateway model runtime");
  await setModelQueue({ registry, agentDir: options.agentDir, tronHome: options.tronHome, trust: options.trust, modelRuntime: options.gatewayModelRuntime },
    "background", models);
}

/** The production background-queue summarizer over one fixed model, for episodic
 * cases that exercise the compactor's own request against a real provider. */
export function singleModelSummarizer(runtime: ModelRuntime, model: { provider: string; id: string }) {
  return createQueueSummarizer(new ModelQueueOwner({ runtime, usage: { read: async () => ({ providers: [] }) }, queue: async () => [`${model.provider}/${model.id}`] }));
}
