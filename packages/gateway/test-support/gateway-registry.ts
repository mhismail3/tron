import { RuntimeRegistry } from "../src/sessions/runtime-registry.js";
import { startGatewayModules, type ModuleOwners } from "../src/main/modules.js";
import type { SessionSearchService } from "../src/sessions/session-search-service.js";
import type { HomeComposition } from "../src/home/home-module.js";
import type { HomeOwner } from "../src/home/home-owner.js";

type RegistryOptions = Omit<ConstructorParameters<typeof RuntimeRegistry>[0], "modules">;
/** Home's composition inputs a test may supply; the rest are the registry's own. */
type HomeTestOptions = Omit<HomeComposition, "tronHome" | "agentDir" | "trust" | "notifications" | "machineId" | "homeTaskDiagnostic">;

const homes = new WeakMap<RuntimeRegistry, () => HomeOwner>();

/** The Home owner the composition built for this registry. */
export function homeOwnerOf(registry: RuntimeRegistry): HomeOwner {
  const home = homes.get(registry);
  if (!home) throw new Error("This registry was not built by createTestRegistry");
  return home();
}

/** One real registry fixture: the production composition, then the real registry.
 * Options remain the boundary's own inputs; no production overrides or test hooks. */
export async function createTestRegistry(options: RegistryOptions & HomeTestOptions & Omit<ModuleOwners, "registry" | "sessionSearch" | "home"> & { sessionSearch?: () => SessionSearchService | undefined }): Promise<RuntimeRegistry> {
  const { connections, scheduleToolOperations, sessionSearch, homeDiagnostic, homeMemoryDiagnostic, homeRequestDiagnostic, homeMemorySummarizer, homeWebTransport, ...registryOptions } = options;
  const home: HomeComposition = {
    tronHome: options.tronHome, agentDir: options.agentDir, trust: options.trust, notifications: options.notifications, machineId: options.machineId,
    homeTaskDiagnostic: options.homeTaskDiagnostic, homeDiagnostic, homeMemoryDiagnostic, homeRequestDiagnostic, homeMemorySummarizer, homeWebTransport,
  };
  const { modules, home: owner } = await startGatewayModules({ tronHome: options.tronHome, log: { log: () => {} } },
    () => ({ registry, home, connections, scheduleToolOperations, sessionSearch: sessionSearch?.() }));
  const registry = new RuntimeRegistry({ ...registryOptions, modules });
  homes.set(registry, owner);
  return registry;
}
