import { basename } from "node:path";
import { projectHookRegistrations, type HookRegistrationProjection } from "../sessions/hook-projection.js";
import type { GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";
import { AsyncMutex } from "../util/async-mutex.js";
import { loadSessionFreeExtensions } from "./session-free-extensions.js";
import type { TrustService } from "./trust-service.js";

export const HOOKS_CAPABILITY = "hooks.v1";

/** Session-free hooks for one scope (Global, or one project folder).
 *
 * Pi exposes handler registrations only by loading extension modules; that load
 * is shared with `packages.list` (`loadSessionFreeExtensions`) and never opens a
 * session. This read is serialized, tracked as drain-aware administrative work
 * and bounded by the same projection envelope `session.resources` uses —
 * exactly the `packages.list` treatment. */
export class HookResources {
  private readonly mutex = new AsyncMutex();

  constructor(
    private readonly agentDir: string,
    private readonly trust: TrustService,
    private readonly workRegistry?: GatewayWorkRegistry,
  ) {}

  async list(cwd?: string): Promise<HookRegistrationProjection> {
    const work = this.workRegistry?.begin({
      kind: "administrative-provider-package-operation",
      hostEpoch: this.workRegistry.runtimeEpoch,
    });
    try {
      return await this.mutex.run(async () => {
        const loaded = await loadSessionFreeExtensions(this.agentDir, this.trust, cwd);
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
        })), loaded.errors);
      });
    } finally {
      work?.settle();
    }
  }
}
