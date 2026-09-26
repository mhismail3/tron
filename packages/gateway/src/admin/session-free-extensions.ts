import { homedir } from "node:os";
import { DefaultResourceLoader, SettingsManager, type Extension } from "@earendil-works/pi-coding-agent";
import { GatewayError } from "../errors.js";
import type { TrustService } from "./trust-service.js";

/** One session-free extension load: the extensions a scope would load, and the
 * modules that failed to load. */
export interface SessionFreeExtensionLoad {
  extensions: Extension[];
  errors: Array<{ path: string; error: string }>;
}

/** Loads the extensions of one scope (Global, or one project folder) without
 * opening a session. `hooks.list` and `packages.list` share this single loader
 * implementation, so both reads create their `SettingsManager` and
 * `DefaultResourceLoader` identically under the same project-trust gating.
 *
 * Pi exposes handler, tool and command registrations only by loading extension
 * modules, and the pinned SDK cannot cancel that load. Each caller therefore
 * runs this inside its own administrative mutex and drain-aware work
 * registration; the loader is created here, read once, and discarded, and its
 * extension-owned provider registrations are never replayed into a global
 * ModelRuntime. An absent cwd is the global scope: the process working directory
 * never selects a project, and the load runs against an untrusted home
 * directory. A supplied cwd is canonicalized by the trust owner and re-read
 * during the load, so a decision change cannot leave project extension code
 * loaded. */
export async function loadSessionFreeExtensions(
  agentDir: string,
  trust: TrustService,
  cwdInput?: string,
): Promise<SessionFreeExtensionLoad> {
  const inspection = cwdInput === undefined ? undefined : await trust.inspect(cwdInput);
  const cwd = inspection?.cwd ?? homedir();
  const settings = SettingsManager.create(cwd, agentDir, {
    projectTrusted: inspection?.effectiveDecision === true,
  });
  // The SDK reports settings load failures through drainErrors rather than
  // throwing; a malformed settings file must not look like "no extensions".
  if (settings.drainErrors().length > 0) {
    throw new GatewayError("conflict", "Canonical extension settings could not be loaded");
  }
  const loader = new DefaultResourceLoader({ cwd, agentDir, settingsManager: settings });
  await loader.reload({
    resolveProjectTrust: async () => inspection === undefined
      ? false
      : (await trust.inspect(cwd)).effectiveDecision === true,
  });
  const loaded = loader.getExtensions();
  return { extensions: loaded.extensions, errors: loaded.errors };
}
