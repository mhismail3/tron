import { homedir } from "node:os";
import { basename } from "node:path";
import { DefaultResourceLoader, SettingsManager } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import { projectHookRegistrations, type HookRegistrationProjection } from "../sessions/hook-projection.js";
import type { GatewayWorkRegistry } from "../sessions/gateway-work-registry.js";
import { AsyncMutex } from "../util/async-mutex.js";
import type { TrustService } from "./trust-service.js";

export const HOOKS_CAPABILITY = "hooks.v1";

/** Session-free hooks for one scope (Global, or one project folder).
 *
 * Pi exposes handler registrations only by loading extension modules, and the
 * pinned SDK cannot cancel that load, so this read is serialized, tracked as
 * drain-aware administrative work and bounded by the same projection envelope
 * `session.resources` uses — exactly the `packages.list` treatment. It never
 * opens a session: the loader is created here, only read, and discarded, and its
 * extension-owned provider registrations are never replayed into a global
 * ModelRuntime. */
export class HookResources {
  private readonly mutex = new AsyncMutex();

  constructor(
    private readonly agentDir: string,
    private readonly trust: TrustService,
    private readonly workRegistry?: GatewayWorkRegistry,
  ) {}

  /** An absent cwd is the global scope; the process working directory never
   * selects a project here. */
  async list(cwd?: string): Promise<HookRegistrationProjection> {
    const work = this.workRegistry?.begin({
      kind: "administrative-provider-package-operation",
      hostEpoch: this.workRegistry.runtimeEpoch,
    });
    try {
      return await this.mutex.run(async () => {
        // The global scope loads against an untrusted home directory, exactly like
        // the global provider runtime. A project scope re-reads the canonical trust
        // decision during the load so a decision change cannot leave project
        // extension code loaded.
        const inspection = cwd === undefined ? undefined : await this.trust.inspect(cwd);
        const resolvedCwd = inspection?.cwd ?? homedir();
        const settings = SettingsManager.create(resolvedCwd, this.agentDir, {
          projectTrusted: inspection?.effectiveDecision === true,
        });
        // The SDK reports settings load failures through drainErrors rather than
        // throwing; a malformed settings file must not look like "no hooks".
        if (settings.drainErrors().length > 0) {
          throw new GatewayError("conflict", "Canonical hook settings could not be loaded");
        }
        const loader = new DefaultResourceLoader({
          cwd: resolvedCwd,
          agentDir: this.agentDir,
          settingsManager: settings,
        });
        await loader.reload({
          resolveProjectTrust: async () => inspection === undefined
            ? false
            : (await this.trust.inspect(resolvedCwd)).effectiveDecision === true,
        });
        const loaded = loader.getExtensions();
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
