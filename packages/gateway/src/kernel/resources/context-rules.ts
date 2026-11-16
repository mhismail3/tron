import type { SettingsManager } from "../pi/coding-agent.js";

type ContextFiles = { agentsFiles: Array<{ path: string; content: string; global?: boolean }> };

export function admittedContextRules(settings: SettingsManager) {
  return {
    agentsFilesOverride: (base: ContextFiles): ContextFiles => {
      const rules = (settings.getSettings() as { contextRules?: { global?: unknown; project?: unknown } }).contextRules;
      const project = settings.isProjectTrusted() && rules?.project !== false;
      return { agentsFiles: base.agentsFiles.filter(file => file.global ? rules?.global !== false : project) };
    },
    systemPromptOverride: () => undefined,
    appendSystemPromptOverride: () => [],
  };
}
