import type { ModuleDescriptor } from "../kernel/host/module-host.js";
import { createTronCoreExtension, tronContext } from "./tron-core-extension.js";
import { workspaceModule } from "./workspace-module.js";
import { JevDecisionClient } from "../knowledge/jev-client.js";
import type { KnowledgeService } from "../knowledge/knowledge-service.js";
import type { ConnectionOwner } from "../integrations/connection-owner.js";

export interface CoreModuleServices { knowledge: KnowledgeService | undefined; connections: ConnectionOwner | undefined }

/** Gateway owners are resolved when the runtime assembles its extension, not at start. */
export function createCoreModule(services: () => CoreModuleServices): ModuleDescriptor {
  return {
    name: "tron-core",
    purpose: "Adds Tron's operating context and the knowledge, connections and Jev tools.",
    tools: ["knowledge", "connections", "jev"], commands: [], dependsOn: [workspaceModule],
    start: host => {
      const workspace = host.contract(workspaceModule);
      return { hooks: { operatingContext: tronContext }, extension: session => {
        const owners = services();
        return createTronCoreExtension(workspace, owners.knowledge, new JevDecisionClient(session.modelRuntime), owners.connections);
      } };
    },
  };
}
