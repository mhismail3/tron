import { ModuleHost, type GatewayHost, type ModuleDescriptor } from "../kernel/host/module-host.js";
import { settlementModule } from "../kernel/host/settlement-module.js";
import { contextWindowModule } from "../providers/context-window-policy.js";
import { compactionPolicyModule } from "../runtime/compaction-policy.js";
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

type ModuleOwners = Pick<RuntimeRegistry, "coreModuleServices" | "displayModuleServices" | "scheduleModuleOperations" | "notifyModuleServices" | "homeModuleServices">;

/** One production composition. Callbacks may close over the not-yet-constructed
 * registry: start only captures them; extension assembly resolves the live owner. */
export function gatewayModules(registry: () => ModuleOwners): readonly ModuleDescriptor<unknown>[] {
  return [
    workspaceModule,
    settlementModule,
    contextWindowModule,
    compactionPolicyModule,
    createCoreModule(() => registry().coreModuleServices()),
    settingsModule,
    askUserModule,
    createDisplayModule(() => registry().displayModuleServices()),
    appsModule,
    createNativeCaptureModule(() => registry().displayModuleServices()),
    computerModule,
    createScheduleModule(() => registry().scheduleModuleOperations()),
    createNotifyModule(() => registry().notifyModuleServices()),
    createHomeModule(() => registry().homeModuleServices()),
    createHomeResearchModule(() => registry().homeModuleServices()),
  ];
}

/** Pi's process-global theme must precede every extension resource load. */
export function startGatewayModules(platform: Omit<GatewayHost, "contract">, registry: () => ModuleOwners): Promise<ModuleHost> {
  initTheme();
  return ModuleHost.start(gatewayModules(registry), platform);
}
