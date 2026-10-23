import { ModuleHost, type GatewayHost, type ModuleDescriptor } from "../kernel/host/module-host.js";
import { settlementModule } from "../kernel/host/settlement-module.js";
import { contextWindowModule } from "../providers/context-window-policy.js";
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
import { createHomeModule, createHomeResearchModule } from "../home/home-module.js";
import type { RuntimeRegistry } from "../sessions/runtime-registry.js";
import type { ConnectionOwner } from "../integrations/connection-owner.js";
import type { ScheduleToolOperations } from "../automations/tron-schedule-extension.js";

/** The owners modules read per runtime: the registry's own services and the
 * composition's, which never pass through the registry. */
export interface ModuleOwners {
  registry: Pick<RuntimeRegistry, "knowledge" | "displayModuleServices" | "notifyModuleServices" | "homeModuleServices">;
  connections?: ConnectionOwner | undefined;
  scheduleToolOperations?: ScheduleToolOperations | undefined;
}

/** One production composition. Callbacks may close over the not-yet-constructed
 * registry: start only captures them; extension assembly resolves the live owner. */
export function gatewayModules(owners: () => ModuleOwners): readonly ModuleDescriptor<unknown>[] {
  const registry = () => owners().registry;
  return [
    workspaceModule,
    settlementModule,
    contextWindowModule,
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
    createHomeModule(() => registry().homeModuleServices()),
    createHomeResearchModule(() => registry().homeModuleServices()),
  ];
}

/** Pi's process-global theme must precede every extension resource load. */
export function startGatewayModules(platform: Omit<GatewayHost, "contract">, owners: () => ModuleOwners): Promise<ModuleHost> {
  initTheme();
  return ModuleHost.start(gatewayModules(owners), platform);
}
