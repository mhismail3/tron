import { ModuleHost, type GatewayHost, type ModuleDescriptor } from "../kernel/host/module-host.js";
import { workspaceModule } from "../workspace/workspace-module.js";

/** The Gateway's module composition (k0-kernel.md §3): one line per module,
 * started in this order and stopped in reverse. */
export const GATEWAY_MODULES: readonly ModuleDescriptor<unknown>[] = [
  workspaceModule,
];

/** Starts the composition for one Gateway (gateway-main, and test registries). */
export function startGatewayModules(platform: Omit<GatewayHost, "contract">): Promise<ModuleHost> {
  return ModuleHost.start(GATEWAY_MODULES, platform);
}
