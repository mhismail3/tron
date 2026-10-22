import type { createAgentSessionServices, ModelRuntime } from "../pi/coding-agent.js";

export type ProfileResourceOptions = Pick<NonNullable<NonNullable<Parameters<typeof createAgentSessionServices>[0]>["resourceLoaderOptions"]>,
  "noExtensions" | "noContextFiles" | "skillsOverride" | "systemPromptOverride" | "appendSystemPromptOverride">;
export interface ProfileModelRuntime { runtime: ModelRuntime; ownership: "owned" | "borrowed" }

/** An immutable recipe selected once per runtime. Record-based canonical append
 * classification resolves a recipe separately on every append. */
interface ProfileRecipe {
  readonly name: string;
  readonly extensions: "ordinary" | readonly string[];
  readonly resources: Readonly<ProfileResourceOptions>;
  readonly projectTrust: "inspect" | "never";
  readonly projectSettings: boolean;
  readonly managedSubagents: boolean;
  readonly directBash: boolean;
  readonly tools?: readonly string[];
  /** Only fixed physical models; a virtual model routes on a transcript the profile does not own. */
  readonly physicalModelsOnly?: boolean;
  readonly launchDefaults: "settings-home-recipe" | "none";
  readonly compaction: "policy" | "disabled";
  readonly settingsActor: "home" | "agent";
  readonly workerSettings: boolean;
  readonly chapter: boolean;
  readonly subagentCatalog: boolean;
  readonly profileChanges: boolean;
  /** Selects the call-time module hook, never a captured policy instance. */
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
