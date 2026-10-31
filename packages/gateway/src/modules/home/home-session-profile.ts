import type { ProfileModelRuntime, SessionProfile } from "../../kernel/host/session-profile.js";
import { HOME_TOOL_NAMES } from "./home-runtime-policy.js";
import { GatewayError } from "../../errors.js";
import { isVirtualModel } from "../../providers/virtual-model.js";

export const HOME_SESSION_PROFILE_NAME = "home";
const HOME_MODULE_NAMES: readonly string[] = [
  "tron-context-window", "tron-compaction-policy", "tron-settings", "tron-projects", "tron-ask-user", "tron-display", "tron-notify", "tron-schedule",
];
export interface HomeSessionProfileServices {
  decision(sessionId: string, cwd: string): "home" | "ordinary" | "unnamed";
  runtime(): Promise<ProfileModelRuntime>;
}

/** Static recipe, live owner callbacks. Resource overrides read their loader's
 * current base, not a session or designation captured during module start. */
export function homeSessionProfile(services: () => HomeSessionProfileServices): SessionProfile {
  return {
    name: HOME_SESSION_PROFILE_NAME,
    extensions: [...HOME_MODULE_NAMES, "tron-home", "tron-home-research", "tron-web-research"],
    resources: {
      noExtensions: true, noContextFiles: true,
      // These agent-directory files are not gated by any no* loader option.
      systemPromptOverride: () => undefined,
      appendSystemPromptOverride: () => [],
    },
    projectTrust: "never", projectSettings: false, managedSubagents: false, directBash: true,
    tools: [...HOME_TOOL_NAMES], modelRuntime: "gateway", acquireModelRuntime: () => services().runtime(),
    modelSelection: { physicalOnly: true, assertAllowed(model) {
      // A virtual router owns a transcript that Home’s profile does not own.
      if (isVirtualModel(model)) throw new GatewayError("invalid_request", "Tron Home requires a fixed physical model; virtual models are not supported");
    } },
    launchDefaults: "settings-home-recipe", compaction: "disabled", settingsActor: "home", workerSettings: true,
    chapter: true, subagentCatalog: false, profileChanges: true, requestPolicy: true,
  };
}
