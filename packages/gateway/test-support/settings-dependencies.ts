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
    homeMemoryModel: async () => (await input.home?.()?.memoryStatus())?.model,
  });
  const settingsChanges = new SettingsChangePath(settingsModel, new SettingsChangeRecord(input.tronHome), new SettingsApprovals(input.tronHome), {
    setTrust: async (project, decision) => {
      return input.trust.setAndApply(project, decision,
        async (inspection) => { await input.sessions?.reloadProject(inspection.cwd, inspection.effectiveDecision === true, false); },
        async (inspection) => { await input.sessions?.commitProjectReload(inspection.cwd); });
    },
    configureHomeMemory: async (model) => {
      const home = input.home?.();
      if (!home) throw new Error("Home is not available in this fixture");
      await home.configureMemory({ model });
    },
    ...(input.knowledge ? { profile: new HomeProfileItems(input.knowledge) } : {}),
  }, input.agentDir, input.now);
  input.registry?.setSettings(settingsModel, settingsChanges);
  return { settingsModel, settingsChanges };
}
