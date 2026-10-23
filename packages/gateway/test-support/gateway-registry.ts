import { RuntimeRegistry } from "../src/sessions/runtime-registry.js";
import { startGatewayModules, type ModuleOwners } from "../src/main/modules.js";
import type { SessionSearchService } from "../src/sessions/session-search-service.js";

/** One real registry fixture: the production composition, then the real registry.
 * Options remain the boundary's own inputs; no production overrides or test hooks. */
export async function createTestRegistry(options: Omit<ConstructorParameters<typeof RuntimeRegistry>[0], "modules"> & Omit<ModuleOwners, "registry" | "sessionSearch"> & { sessionSearch?: () => SessionSearchService | undefined }): Promise<RuntimeRegistry> {
  const { connections, scheduleToolOperations, sessionSearch, ...registryOptions } = options;
  const modules = await startGatewayModules({ tronHome: options.tronHome, log: { log: () => {} } },
    () => ({ registry, connections, scheduleToolOperations, sessionSearch: sessionSearch?.() }));
  const registry = new RuntimeRegistry({ ...registryOptions, modules });
  return registry;
}
