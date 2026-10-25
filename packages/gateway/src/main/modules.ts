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
import { computerModule } from "../display/computer-module.js";
import { appsModule } from "../modules/apps/module.js";
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

/** The owners modules read per runtime: the registry's own services and the
 * composition's, which never pass through the registry. */
export interface ModuleOwners extends RecentModelSignals {
  registry: RuntimeRegistry;
  home: HomeComposition;
  display: DisplayOwner;
  openAIModelEligibility: OpenAIModelEligibility;
  connections?: ConnectionOwner | undefined;
  scheduleToolOperations?: ScheduleToolOperations | undefined;
  sessionSearch?: SessionSearchService | undefined;
}

/** One production composition. Callbacks may close over the not-yet-constructed
 * registry: start only captures them; extension assembly resolves the live owner. */
export function gatewayModules(owners: () => ModuleOwners) {
  const registry = () => owners().registry;
  const home = createHomeModules(() => ({ composition: owners().home, sessions: registry(), search: () => {
    const owner = owners().sessionSearch;
    return owner ? (request: Parameters<SessionSearchService["search"]>[0], signal?: AbortSignal) => owner.search(request, signal) : undefined;
  } }));
  const providers = createContextWindowModule(() => owners().openAIModelEligibility, owners, () => owners().home.modelQueue);
  return { home: home.owner, providers, runtimeOrder: ORDINARY_MODULE_NAMES, modules: [
    workspaceModule,
    settlementModule,
    providers,
    compactionPolicyModule,
    createCoreModule(() => ({ knowledge: owners().home.knowledge(), connections: owners().connections })),
    createWebResearchModule(() => owners().home.homeWebTransport),
    settingsModule,
    askUserModule,
    createDisplayModule(() => owners().display),
    appsModule,
    createNativeCaptureModule(() => owners().display),
    computerModule,
    createScheduleModule(() => owners().scheduleToolOperations),
    createNotifyModule(() => ({ notifications: owners().home.notifications, machineId: owners().home.machineId })),
    home.home,
    home.research,
  ] };
}

/** Pi's process-global theme must precede every extension resource load. */
export async function startGatewayModules(platform: Omit<GatewayHost, "contract">, owners: () => ModuleOwners) {
  initTheme();
  const composition = gatewayModules(owners);
  const modules = await ModuleHost.start(composition.modules, platform, composition.runtimeOrder);
  return { modules, home: composition.home, recentModels: modules.contract(composition.providers) };
}
