import type { TronModuleSummary } from "../protocol/types.js";
import type { ModuleHost } from "../kernel/host/module-host.js";

export const ORDINARY_MODULE_NAMES: readonly string[] = [
  "tron-invocation-settlement",
  "tron-context-window",
  "tron-compaction-policy",
  "tron-core",
  "tron-web-research",
  "tron-settings",
  "tron-session-import",
  "tron-projects",
  "tron-ask-user",
  "tron-display",
  "tron-swift-apps",
  "tron-native-capture",
  "tron-computer",
  "tron-schedule",
  "tron-notify",
];

export const MODULES_CAPABILITY = "modules.v1";

export function tronModuleSummaries(modules?: ModuleHost): TronModuleSummary[] {
  return modules?.summaries(modules.runtimeOrder) ?? [];
}
