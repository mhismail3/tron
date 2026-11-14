import type { ManagedSubagents } from "../kernel/delegation/managed-subagents.js";
import { basename } from "node:path";
import { projectHookRegistrations, type HookRegistrationProjection } from "../kernel/projection/hook-projection.js";
import type { GatewayWorkRegistry } from "../kernel/run/gateway-work-registry.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { loadSessionFreeExtensions } from "./session-free-extensions.js";
import type { TrustService } from "../kernel/resources/trust-service.js";

export class HookResources {
  private readonly mutex = new AsyncMutex();

  constructor(
    private readonly agentDir: string,
    private readonly trust: TrustService,
    private readonly workRegistry?: GatewayWorkRegistry,
    private readonly managedSubagents?: ManagedSubagents,
  ) {}

  async list(cwd?: string): Promise<HookRegistrationProjection> {
    const work = this.workRegistry?.begin({
      kind: "administrative-provider-package-operation",
      hostEpoch: this.workRegistry.runtimeEpoch,
    });
    try {
      return await this.mutex.run(async () => {
        const loaded = await loadSessionFreeExtensions(this.agentDir, this.trust, cwd, this.managedSubagents);
        return projectHookRegistrations(loaded.extensions.map((extension) => ({
          name: basename(extension.path),
          path: extension.path,
          resolvedPath: extension.resolvedPath,
          scope: extension.sourceInfo.scope,
          source: extension.sourceInfo.source,
          origin: extension.sourceInfo.origin,
          tools: extension.tools.keys(),
          commands: extension.commands.keys(),
          handlers: extension.handlers,
        })), loaded.errors, loaded.warnings);
      });
    } finally {
      work?.settle();
    }
  }
}
