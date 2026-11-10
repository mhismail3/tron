import type { ManagedSubagents } from "../kernel/delegation/managed-subagents.js";
import { attributeExtensions } from "../extensions/owner-attribution.js";
import { homedir } from "node:os";
import { DefaultResourceLoader, SettingsManager, type Extension } from "../kernel/pi/coding-agent.js";
import { GatewayError } from "../errors.js";
import type { TrustService } from "../kernel/resources/trust-service.js";
import { piBuiltinExtensions } from "../kernel/host/pi-builtins.js";

export interface SessionFreeExtensionLoad {
  extensions: Extension[];
  errors: Array<{ path: string; error: string }>;
  warnings: Array<{ path: string; warning: string }>;
}

export async function loadSessionFreeExtensions(
  agentDir: string,
  trust: TrustService,
  cwdInput?: string,
  managedSubagents?: ManagedSubagents,
): Promise<SessionFreeExtensionLoad> {
  const inspection = cwdInput === undefined ? undefined : await trust.inspect(cwdInput);
  const cwd = inspection?.cwd ?? homedir();
  const projectDir = inspection?.projectDir ?? cwd;
  const settings = SettingsManager.create(projectDir, agentDir, {
    projectTrusted: inspection?.effectiveDecision === true,
  });
  if (settings.drainErrors().length > 0) {
    throw new GatewayError("conflict", "Canonical extension settings could not be loaded");
  }
  const managedOptions = await managedSubagents?.loaderOptions(settings);
  const loader = new DefaultResourceLoader({
    cwd,
    projectDir,
    agentDir,
    settingsManager: settings,
    ...(managedOptions ?? {}),
    extensionsOverride: (base) => attributeExtensions(base, undefined, managedSubagents ? { managedSubagents } : {}),
    extensionFactories: [...(managedOptions?.extensionFactories ?? []), ...piBuiltinExtensions(agentDir)],
  });
  await loader.reload({
    resolveProjectTrust: async () => inspection === undefined
      ? false
      : (await trust.inspect(cwd)).effectiveDecision === true,
  });
  await managedSubagents?.completeLoad(settings, cwd, agentDir, loader.getExtensions().extensions);
  const loaded = loader.getExtensions();
  return { extensions: loaded.extensions, errors: loaded.errors, warnings: loaded.warnings ?? [] };
}
