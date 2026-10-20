import type { ModuleHost } from "../src/kernel/host/module-host.js";
import { startGatewayModules } from "../src/main/modules.js";

/** The production module composition (`main/modules.ts`) started for one test
 * Gateway's Tron home, so a test registry is composed exactly as gateway-main's.
 * Module log lines are dropped, as a test registry's diagnostics are. */
export function startTestModules(tronHome: string): Promise<ModuleHost> {
  return startGatewayModules({ tronHome, log: { log: () => {} } });
}
