import { ModuleHost, type GatewayHost, type ModuleDescriptor } from "../kernel/host/module-host.js";
import { initTheme } from "../kernel/pi/adapters.js";
import { appsModule } from "../modules/apps/module.js";
import { workspaceModule } from "../workspace/workspace-module.js";

/** The Gateway's module composition (k0-kernel.md §3): one line per module,
 * started in this order and stopped in reverse. */
export const GATEWAY_MODULES: readonly ModuleDescriptor<unknown>[] = [
  workspaceModule,
  appsModule,
];

/** Starts the composition for one Gateway (gateway-main, before anything loads an
 * extension, and test registries): Pi's process-global theme first, then the modules. */
export function startGatewayModules(platform: Omit<GatewayHost, "contract">): Promise<ModuleHost> {
  initTheme();
  return ModuleHost.start(GATEWAY_MODULES, platform);
}
