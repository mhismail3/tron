import { Type } from "@earendil-works/pi-ai";
import type { ExtensionFactory, ToolInfo } from "@earendil-works/pi-coding-agent";
import type { ChangeRequest, ChangeResult } from "./settings-model.js";
import type { Resolution } from "./settings-resolver.js";

/**
 * The `settings` tool and the turn's web mark (docs/settings-model.md 5.1, 5.4).
 *
 * The tool is a thin client of `settings.resolve` and `settings.change` for an
 * agent: Home, a task worker or an ordinary chat's agent, each recorded as that
 * actor. It targets the chat it runs in, so it reaches that chat's layers
 * (Chat, Project, Mac, and Home's profile). Home alone may name a delegated
 * worker with `taskId` (#1336): the target is then that worker's session, and
 * the change is still Home's, through the same path, floors and approvals.
 *
 * The web mark is set by the Gateway from the tool calls it executes, never from
 * the model's own account. A tool marks the run unless it declares
 * `annotations.openWorldHint: false` (Mohsin, 2026-10-11): an undeclared tool is
 * untrusted. The mark belongs to the run (the prompt to the agent's final
 * answer): content a tool returned stays in context for the rest of it.
 */

export const SETTINGS_OUTCOME_MESSAGE = "tron.settings-outcome.v1";

/** A delegated worker's settings state beside its resolved keys (#1336). */
export interface TaskWorkerSettingsState {
  /** The worker's task operation is live: a change applies from its next provider request. */
  running: boolean;
  /** What the worker's next provider request uses. */
  selected: { model: string | null; thinking: string };
  /** What its latest assistant response ran on: the acknowledgment a change took effect. */
  lastResponse: { model: string; thinking: string | null; at: string } | null;
}

/** The task a `taskId` call resolved to: the worker's current task (a resume continues it). */
export interface TaskWorkerSettingsView extends TaskWorkerSettingsState {
  taskId: string;
  sessionId: string;
  operationId: string | null;
  state: string;
  resolvedFrom?: string;
}

/** What the session runtime gives the tool: its own target and identity, or Home's worker target. */
export interface SettingsToolAccess {
  resolve(keys?: string[], taskId?: string): Promise<Resolution & { worker?: TaskWorkerSettingsView }>;
  change(changes: ChangeRequest[], input: { reason: string; dryRun?: boolean; toolCallId: string; web: boolean; taskId?: string }): Promise<ChangeResult & { worker?: TaskWorkerSettingsView }>;
  /** Declined, expired or superseded changes this chat asked for, not yet told (Q22). */
  takeOutcomes(): Promise<string[]>;
}

/**
 * pi's own tools carry no annotations, so Tron declares the closed-world ones
 * here, bound to their built-in source so a third-party tool of the same name
 * declares for itself. `bash` is trusted (decision 33): Tron passes pi's bash
 * definition as its direct bash tool (`DirectBashProcessOwner`), so its source
 * is `<sdk:bash>`, and owner attribution reserves the name from extensions.
 */
const PI_CLOSED_WORLD: Readonly<Record<string, readonly string[]>> = {
  read: ["builtin:read"], edit: ["builtin:edit"], write: ["builtin:write"], grep: ["builtin:grep"], find: ["builtin:find"], ls: ["builtin:ls"],
  bash: ["builtin:bash", "<sdk:bash>"],
  // codemode's own call reads nothing; each tool it calls is marked by its own declaration.
  codemode: ["builtin:codemode"], tool_search: ["builtin:tool-search"],
};

/** Whether a call to this tool marks the run as having read open-world content. */
export function marksTurn(tool: Pick<ToolInfo, "name" | "annotations" | "sourceInfo"> | undefined): boolean {
  if (!tool) return true;
  if (tool.annotations?.openWorldHint === false) return false;
  return !(Object.hasOwn(PI_CLOSED_WORLD, tool.name) && PI_CLOSED_WORLD[tool.name]!.includes(tool.sourceInfo.path));
}

const CHANGE = Type.Object({
  key: Type.String({ minLength: 1, maxLength: 200, description: "A key id from resolve, e.g. run.retry.maxRetries." }),
  layer: Type.Union([Type.Literal("chat"), Type.Literal("profile"), Type.Literal("project"), Type.Literal("mac")]),
  op: Type.Union([Type.Literal("set"), Type.Literal("unset")]),
  value: Type.Optional(Type.Unknown()),
  qualifiers: Type.Optional(Type.Record(Type.String(), Type.String(), { description: "e.g. model (provider/id) or project (absolute path)." })),
  expected: Type.Optional(Type.Unknown({ description: "The value read at that layer (null when unset); refused if it changed." })),
}, { additionalProperties: false });

const TASK_ID = Type.Optional(Type.String({ minLength: 1, maxLength: 160,
  description: "Tron Home only: the delegated task (from task list) whose worker session to read or change instead of this chat." }));

const PARAMETERS = Type.Union([
  Type.Object({
    action: Type.Literal("resolve"),
    keys: Type.Optional(Type.Array(Type.String({ minLength: 1, maxLength: 200 }), { maxItems: 200 })),
    taskId: TASK_ID,
  }, { additionalProperties: false }),
  Type.Object({
    action: Type.Literal("change"),
    taskId: TASK_ID,
    changes: Type.Array(CHANGE, { minItems: 1, maxItems: 50 }),
    reason: Type.String({ minLength: 1, maxLength: 2_000, description: "Why, for the maintainer." }),
    dryRun: Type.Optional(Type.Boolean()),
  }, { additionalProperties: false }),
]);

/** How an applied change reaches a delegated worker (#1336), in the tool's own words. */
function signalText(result: ChangeResult): string {
  const signal = result.signal;
  if (!signal) return "";
  if (signal.status === "queued") return ` Stored now; worker ${signal.taskId} was signalled in its steering lane and uses it from its next model request (the request in flight keeps its settings). Confirm with resolve: worker.lastResponse shows what its latest response ran on.`;
  if (signal.status === "not-running") return ` Stored now; worker ${signal.taskId} is not running, so it takes effect when the task is resumed.`;
  return ` Stored now and used from the worker's next model request, but the signal to worker ${signal.taskId} was refused (${signal.error.code}: ${signal.error.message}).`;
}

export function createTronSettingsExtension(access: () => SettingsToolAccess | undefined): ExtensionFactory {
  return (pi) => {
    let marked = false;
    pi.on("agent_start", () => { marked = false; });
    // `tool_call` runs before each call executes, nested codemode calls
    // included, and before any call of a parallel batch runs.
    pi.on("tool_call", (event) => {
      if (marked) return;
      marked = marksTurn(pi.getAllTools().find(tool => tool.name === event.toolName));
    });
    pi.on("before_agent_start", async () => {
      const lines = await access()?.takeOutcomes();
      if (!lines?.length) return undefined;
      return { message: { customType: SETTINGS_OUTCOME_MESSAGE, content: lines.join("\n"), display: true } };
    });
    pi.registerTool({
      name: "settings",
      label: "Settings",
      description: "Read (resolve) or change Tron settings for this chat. A change sets or unsets one key at one layer and needs a reason. Its tier decides what happens: quiet applies, notify applies and tells the maintainer, approve waits for his tap (pending). Web or browser content read earlier in the run raises the tier one step; dryRun returns the tier. Tron Home only: taskId reads or changes that delegated worker's session instead; a running worker uses a model, thinking or Run change from its next model request and is signalled.",
      promptSnippet: "Change settings with the settings tool, never by editing settings files.",
      promptGuidelines: [
        "Use settings to read or change model, context, tools, permissions and run settings; never edit settings.json, .pi/ or trust files directly.",
        "Give every change a reason written for the maintainer. A pending change is not applied until the maintainer approves it.",
      ],
      parameters: PARAMETERS,
      annotations: { openWorldHint: false },
      executionMode: "sequential",
      execute: async (toolCallId, input): Promise<{ content: Array<{ type: "text"; text: string }>; details: unknown }> => {
        const owner = access();
        if (!owner) throw new Error("Settings are not available in this chat");
        if (input.action === "resolve") {
          const resolution = await owner.resolve(input.keys, input.taskId);
          const summary = resolution.keys.map(key => ({
            key: key.key, ...(key.qualifiers ? { qualifiers: key.qualifiers } : {}), value: key.display, layer: key.layer,
            ...(key.applied ? {} : { applied: false, reason: key.reason }),
          }));
          return { content: [{ type: "text", text: JSON.stringify({ ...(resolution.worker ? { worker: resolution.worker } : {}), layers: resolution.layers, keys: summary }) }], details: resolution };
        }
        const result = await owner.change(input.changes as ChangeRequest[], {
          reason: input.reason, ...(input.dryRun ? { dryRun: true } : {}), toolCallId, web: marked, ...(input.taskId ? { taskId: input.taskId } : {}),
        });
        const text = result.status === "pending"
          ? `Pending the maintainer's approval (request ${result.approval!.requestId}, expires ${result.approval!.expiresAt}). Nothing changed yet${result.worker ? "; the worker keeps its current settings and is told only if it is approved" : ""}.`
          : result.dryRun ? `Dry run: tier ${result.tier}.` : `Applied at tier ${result.tier}.${signalText(result)}`;
        return { content: [{ type: "text", text: `${text}\n${JSON.stringify(result)}` }], details: result };
      },
    });
  };
}
