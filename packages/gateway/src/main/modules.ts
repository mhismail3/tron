import { ProjectLifecycle } from "../modules/projects/project-lifecycle.js";
import { projectsModule } from "../modules/projects/module.js";
import { projectRuntimePort } from "../modules/projects/runtime-admission.js";
import { createWebResearchModule } from "../workspace/web-research-module.js";
import { ORDINARY_MODULE_NAMES } from "../extensions/tron-modules.js";
import { ModuleHost, type GatewayHost } from "../kernel/host/module-host.js";
import { settlementModule } from "../kernel/host/settlement-module.js";
import { createContextWindowModule } from "../providers/context-window-policy.js";
import type { RecentModelSignals } from "../providers/recent-models.js";
import type { OpenAIModelEligibility } from "../providers/openai-model-eligibility.js";
import { compactionPolicyModule } from "../kernel/run/compaction-policy.js";
import { initTheme } from "../kernel/pi/adapters.js";
import { settingsModule } from "../admin/settings-module.js";
import { askUserModule } from "../extensions/ask-user-module.js";
import { randomUUID } from "node:crypto";
import { createComputerModule } from "../display/computer-module.js";
import { ConsoleGate } from "../machine/console-probe.js";
import { createAppsModule } from "../modules/apps/module.js";
import { workspaceModule } from "../workspace/workspace-module.js";
import { createCoreModule } from "../workspace/core-module.js";
import { createDisplayModule, createNativeCaptureModule, type DisplayOwner } from "../display/display-modules.js";
import { createScheduleModule } from "../automations/schedule-module.js";
import { createNotifyModule } from "../notifications/notify-module.js";
import { createHomeModules, type HomeComposition } from "../modules/home/home-module.js";
import type { RuntimeRegistry } from "../kernel/session/runtime-registry.js";
import type { ConnectionOwner } from "../integrations/connection-owner.js";
import type { ScheduleToolOperations } from "../automations/tron-schedule-extension.js";
import type { SessionSearchService } from "../sessions/session-search-service.js";
import { sessionImportModule } from "../modules/session-import/session-import-module.js";

export interface ModuleOwners extends RecentModelSignals {
  registry: RuntimeRegistry;
  home: HomeComposition;
  display: DisplayOwner;
  openAIModelEligibility: OpenAIModelEligibility;
  connections?: ConnectionOwner | undefined;
  scheduleToolOperations?: ScheduleToolOperations | undefined;
  sessionSearch?: SessionSearchService | undefined;
  maxUploadBytes: number;
}

export function gatewayModules(owners: () => ModuleOwners, projectOptions?: ConstructorParameters<typeof ProjectLifecycle>[2]) {
  const registry = () => owners().registry;
  const home = createHomeModules(() => ({ composition: owners().home, sessions: registry(), search: () => {
    const owner = owners().sessionSearch;
    return owner ? (request: Parameters<SessionSearchService["search"]>[0], signal?: AbortSignal) => owner.search(request, signal) : undefined;
  } }));
  const projects = projectsModule(new ProjectLifecycle(() => owners().home.trust, projectRuntimePort(registry, () => home.owner().activeTaskTargets()), projectOptions));
  const gate = new ConsoleGate(async (sessionId, cause) => {
    const { notifications, machineId } = owners().home;
    await notifications?.enqueue({ sessionId, sourceId: `${cause}-${randomUUID()}`, kind: "explicit", title: cause === "mac_locked" ? "Mac locked" : "Mac display asleep",
      message: `Tron paused desktop work because the Mac ${cause === "mac_locked" ? "is locked. Unlock it" : "display is asleep. Wake it"} to continue; browser work is unaffected.`,
      ...(machineId ? { route: { sessionId, machineId } } : {}) });
  });
  const providers = createContextWindowModule(() => owners().openAIModelEligibility, owners, () => owners().home.modelQueue);
  return { home: home.owner, projects, providers, runtimeOrder: ORDINARY_MODULE_NAMES, modules: [
    workspaceModule,
    settlementModule,
    providers,
    compactionPolicyModule,
    createCoreModule(() => ({ knowledge: owners().home.knowledge(), connections: owners().connections })),
    createWebResearchModule(() => owners().home.homeWebTransport),
    settingsModule,
    sessionImportModule(() => ({ registry: registry(), maxBytes: owners().maxUploadBytes })),
    projects,
    askUserModule,
    createDisplayModule(() => owners().display),
    createAppsModule(() => owners().display),
    createNativeCaptureModule(() => owners().display, gate),
    createComputerModule(gate),
    createScheduleModule(() => owners().scheduleToolOperations),
    createNotifyModule(() => ({ notifications: owners().home.notifications, machineId: owners().home.machineId })),
    home.home,
    home.research,
  ] };
}

export async function startGatewayModules(platform: Omit<GatewayHost, "contract">, owners: () => ModuleOwners, projectOptions?: ConstructorParameters<typeof ProjectLifecycle>[2]) {
  initTheme();
  const composition = gatewayModules(owners, projectOptions);
  const modules = await ModuleHost.start(composition.modules, platform, composition.runtimeOrder);
  return { modules, home: composition.home, projects: modules.contract(composition.projects), recentModels: modules.contract(composition.providers) };
}
