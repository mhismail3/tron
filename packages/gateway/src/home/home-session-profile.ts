import type { ProfileModelRuntime, SessionProfile } from "../kernel/host/session-profile.js";
import type { ModelRef } from "../protocol/types.js";
import { HOME_TOOL_NAMES } from "./home-runtime-policy.js";

export const HOME_SESSION_PROFILE_NAME = "home";
const HOME_MODULE_NAMES: readonly string[] = [
  "tron-context-window", "tron-compaction-policy", "tron-settings", "tron-ask-user", "tron-display", "tron-notify",
];
export interface HomeSessionProfileServices {
  decision(sessionId: string, cwd: string): "home" | "ordinary" | "unnamed";
  model(sessionId: string): ModelRef | undefined;
  changed(sessionId: string, model: ModelRef): Promise<void>;
  runtime(): Promise<ProfileModelRuntime>;
}

/** Static recipe, live owner callbacks. Resource overrides read their loader's
 * current base, not a session or designation captured during module start. */
export function homeSessionProfile(services: () => HomeSessionProfileServices): SessionProfile {
  return {
    name: HOME_SESSION_PROFILE_NAME,
    extensions: [...HOME_MODULE_NAMES, "tron-home", "tron-home-research"],
    resources: {
      noExtensions: true, noContextFiles: true,
      // The composer may offer user-invocable skills/templates, but no skill is
      // listed in Home's system prompt. Inserted resources stay user input.
      skillsOverride: base => ({ ...base, skills: base.skills.map(skill => ({ ...skill, disableModelInvocation: true })) }),
      // These agent-directory files are not gated by any no* loader option.
      systemPromptOverride: () => undefined,
      appendSystemPromptOverride: () => [],
    },
    projectTrust: "never", projectSettings: false, managedSubagents: false, directBash: false,
    tools: HOME_TOOL_NAMES, modelRuntime: "gateway", acquireModelRuntime: () => services().runtime(),
    model: {
      recorded: sessionId => services().model(sessionId),
      changed: (sessionId, model) => services().changed(sessionId, model), physicalOnly: true,
    },
    launchDefaults: "settings-profile-layer", compaction: "disabled", settingsActor: "home", workerSettings: true,
    chapter: true, subagentCatalog: false, profileChanges: true, requestPolicy: true,
  };
}
