import type { ExtensionFactory } from "../kernel/pi/coding-agent.js";
import type { TronModuleSummary } from "../protocol/types.js";
import type { ModuleHost, SessionContext } from "../kernel/host/module-host.js";

/** Runtime registration order differs from startup dependency order. Names are
 * identities only; all tool/command/purpose metadata belongs to descriptors. */
export const ORDINARY_MODULE_NAMES: readonly string[] = [
  "tron-invocation-settlement",
  "tron-context-window",
  "tron-compaction-policy",
  "tron-core",
  "tron-settings",
  "tron-ask-user",
  "tron-display",
  "tron-swift-apps",
  "tron-native-capture",
  "tron-computer",
  "tron-schedule",
  "tron-notify",
];

/** Home keeps these ordinary modules in ordinary order, then its own two. */
export const HOME_MODULE_NAMES: readonly string[] = [
  "tron-context-window",
  "tron-compaction-policy",
  "tron-settings",
  "tron-ask-user",
  "tron-display",
  "tron-notify",
];

export interface TronModuleRegistration { name: string; factory: ExtensionFactory }

export function tronModuleFactories(modules: ModuleHost, session: SessionContext): TronModuleRegistration[] {
  return modules.registrations(ORDINARY_MODULE_NAMES, session);
}

export function homeModuleFactories(modules: ModuleHost, session: SessionContext): TronModuleRegistration[] {
  return modules.registrations([...HOME_MODULE_NAMES, "tron-home", "tron-home-research"], session);
}

export const MODULES_CAPABILITY = "modules.v1";

/** No synthesized rows: Settings sees the started descriptors' own metadata. */
export function tronModuleSummaries(modules?: ModuleHost): TronModuleSummary[] {
  return modules?.summaries(ORDINARY_MODULE_NAMES) ?? [];
}
