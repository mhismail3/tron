import { RuntimeRegistry } from "../src/sessions/runtime-registry.js";
import { startGatewayModules } from "../src/main/modules.js";

/** One real registry fixture: the production composition, then the real registry.
 * Options remain the boundary's own inputs; no production overrides or test hooks. */
export async function createTestRegistry(options: Omit<ConstructorParameters<typeof RuntimeRegistry>[0], "modules">): Promise<RuntimeRegistry> {
  const modules = await startGatewayModules({ tronHome: options.tronHome, log: { log: () => {} } });
  return new RuntimeRegistry({ ...options, modules });
}
