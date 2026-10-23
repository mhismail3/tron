import { ModuleHost, type GatewayHost, type ModuleDescriptor } from "../kernel/host/module-host.js";
import { settlementModule } from "../kernel/host/settlement-module.js";
import { createContextWindowModule } from "../providers/context-window-policy.js";
import type { OpenAIModelEligibility } from "../providers/openai-model-eligibility.js";
import { compactionPolicyModule } from "../kernel/run/compaction-policy.js";
import { initTheme } from "../kernel/pi/adapters.js";
import { settingsModule } from "../admin/settings-module.js";
import { askUserModule } from "../extensions/ask-user-module.js";
import { computerModule } from "../display/computer-module.js";
import { appsModule } from "../modules/apps/module.js";
import { workspaceModule } from "../workspace/workspace-module.js";
import { createCoreModule } from "../workspace/core-module.js";
import { createDisplayModule, createNativeCaptureModule } from "../display/display-modules.js";
import { createScheduleModule } from "../automations/schedule-module.js";
import { createNotifyModule } from "../notifications/notify-module.js";
import { createHomeModules, type HomeComposition } from "../modules/home/home-module.js";
import type { HomeOwner } from "../modules/home/home-owner.js";
import type { RuntimeRegistry } from "../sessions/runtime-registry.js";
import type { ConnectionOwner } from "../integrations/connection-owner.js";
import type { ScheduleToolOperations } from "../automations/tron-schedule-extension.js";
import type { SessionSearchService } from "../sessions/session-search-service.js";

/** The owners modules read per runtime: the registry's own services and the
 * composition's, which never pass through the registry. */
export interface ModuleOwners {
  registry: Pick<RuntimeRegistry, "knowledge" | "displayModuleServices" | "notifyModuleServices" | "homeKernel">;
  home: HomeComposition;
  openAIModelEligibility: OpenAIModelEligibility;
  connections?: ConnectionOwner | undefined;
  scheduleToolOperations?: ScheduleToolOperations | undefined;
  sessionSearch?: SessionSearchService | undefined;
}

/** One production composition. Callbacks may close over the not-yet-constructed
 * registry: start only captures them; extension assembly resolves the live owner. */
export function gatewayModules(owners: () => ModuleOwners): { modules: readonly ModuleDescriptor<unknown>[]; home: () => HomeOwner } {
  const registry = () => owners().registry;
  const home = createHomeModules(() => ({ composition: owners().home, kernel: () => registry().homeKernel(), search: () => {
    const owner = owners().sessionSearch;
    return owner ? (request: Parameters<SessionSearchService["search"]>[0], signal?: AbortSignal) => owner.search(request, signal) : undefined;
  } }));
  return { home: home.owner, modules: [
    workspaceModule,
    settlementModule,
    createContextWindowModule(() => owners().openAIModelEligibility),
    compactionPolicyModule,
    createCoreModule(() => ({ knowledge: registry().knowledge, connections: owners().connections })),
    settingsModule,
    askUserModule,
    createDisplayModule(() => registry().displayModuleServices()),
    appsModule,
    createNativeCaptureModule(() => registry().displayModuleServices()),
    computerModule,
    createScheduleModule(() => owners().scheduleToolOperations),
    createNotifyModule(() => registry().notifyModuleServices()),
    home.home,
    home.research,
  ] };
}

/** Pi's process-global theme must precede every extension resource load. */
export async function startGatewayModules(platform: Omit<GatewayHost, "contract">, owners: () => ModuleOwners): Promise<{ modules: ModuleHost; home: () => HomeOwner }> {
  initTheme();
  const composition = gatewayModules(owners);
  return { modules: await ModuleHost.start(composition.modules, platform), home: composition.home };
}
