import type { createAgentSessionServices, ModelRuntime } from "../pi/coding-agent.js";
import type { Model } from "../pi/ai.js";

type ProfileResourceOptions = Pick<NonNullable<NonNullable<Parameters<typeof createAgentSessionServices>[0]>["resourceLoaderOptions"]>,
  "noExtensions" | "noContextFiles" | "skillsOverride" | "systemPromptOverride" | "appendSystemPromptOverride">;
export interface ProfileModelRuntime { runtime: ModelRuntime; ownership: "owned" | "borrowed" }

interface ProfileRecipe {
  readonly name: string;
  readonly extensions: "ordinary" | readonly string[];
  readonly resources: Readonly<ProfileResourceOptions>;
  readonly projectTrust: "inspect" | "never";
  readonly projectSettings: boolean;
  readonly managedSubagents: boolean;
  readonly directBash: boolean;
  readonly tools?: readonly string[];
  readonly modelSelection?: Readonly<{ physicalOnly: true; assertAllowed(model: Model<any>): void }>;
  readonly launchDefaults: "settings-home-recipe" | "none";
  readonly compaction: "policy" | "disabled";
  readonly settingsActor: "home" | "agent";
  readonly workerSettings: boolean;
  readonly chapter: boolean;
  readonly subagentCatalog: boolean;
  readonly profileChanges: boolean;
  readonly requestPolicy: boolean;
}
export type SessionProfile = ProfileRecipe & (
  { readonly modelRuntime: "session" } |
  { readonly modelRuntime: "gateway"; acquireModelRuntime(): Promise<ProfileModelRuntime> }
);

export const ORDINARY_SESSION_PROFILE: SessionProfile = Object.freeze<SessionProfile>({
  name: "ordinary", extensions: "ordinary", resources: Object.freeze({}), projectTrust: "inspect",
  projectSettings: true, managedSubagents: true, directBash: true, modelRuntime: "session",
  launchDefaults: "none", compaction: "policy", settingsActor: "agent", workerSettings: false,
  chapter: false, subagentCatalog: true, profileChanges: false, requestPolicy: false,
});
