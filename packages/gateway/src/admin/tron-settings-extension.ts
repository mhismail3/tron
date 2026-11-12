import { type SettingsToolAccess, type ChangeRequest, type ChangeResult } from "../kernel/settings/tool-contract.js";
import { nativeChangeConfirmer, type NativeChangeRequest } from "../kernel/host/native-change.js";
import { StringEnum, Type } from "../kernel/pi/ai.js";
import type { ExtensionFactory } from "../kernel/pi/coding-agent.js";

const CHANGE = Type.Object({
  key: Type.String({ minLength: 1, maxLength: 200, description: "A key id from resolve, e.g. run.retry.maxRetries." }),
  layer: Type.Union([Type.Literal("session"), Type.Literal("global")], { description: "Session/Home override or Global. Project is read-only." }),
  op: Type.Union([Type.Literal("set"), Type.Literal("unset")]),
  value: Type.Optional(Type.Unknown()),
  qualifiers: Type.Optional(Type.Record(Type.String(), Type.String(), { description: "e.g. model (provider/id) or project (absolute path)." })),
  expected: Type.Optional(Type.Unknown({ description: "The value read at that layer (null when unset); refused if it changed." })),
}, { additionalProperties: false });

const PARAMETERS = Type.Object({
  action: StringEnum(["resolve", "change", "history", "undo", "inventory"] as const, { description: "resolve: read current values and scopes. history: page durable audit records, optionally filtered by key. undo: reverse a change by changeId under the same writer and native-tap rules. change: apply/log reversible edits; trust, privacy expansion, spend, install and irreversible effects show the shared native card." }),
  keys: Type.Optional(Type.Array(Type.String({ minLength: 1, maxLength: 200 }), { maxItems: 200, description: "resolve: the key ids to read; omit for every key." })),
  taskId: Type.Optional(Type.String({ minLength: 1, maxLength: 160,
    description: "Tron Home only: the delegated task (from task list) whose worker session to read or change instead of this chat." })),
  changes: Type.Optional(Type.Array(CHANGE, { minItems: 1, maxItems: 50, description: "change (required): the changes, applied together." })),
  key: Type.Optional(Type.String({ minLength: 1, maxLength: 200, description: "history: include only this key." })),
  cursor: Type.Optional(Type.String({ minLength: 1, maxLength: 200, description: "history: nextCursor from the previous page." })),
  limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, description: "history/inventory: maximum records per page or section (default 50). Inventory sections also have byte limits and disclose omitted counts." })),
  changeId: Type.Optional(Type.String({ minLength: 1, maxLength: 200, description: "undo (required): changeId from history." })),
  reason: Type.Optional(Type.String({ minLength: 1, maxLength: 2_000, description: "change/undo (required): why, for the maintainer." })),
  dryRun: Type.Optional(Type.Boolean({ description: "change: validate and return exact before/after without applying." })),
}, { additionalProperties: false });

type SettingsCall =
  | { action: "inventory"; limit?: number }
  | { action: "resolve"; keys?: string[]; taskId?: string }
  | { action: "history"; key?: string; cursor?: string; limit?: number }
  | { action: "undo"; changeId: string; reason: string }
  | { action: "change"; changes: ChangeRequest[]; reason: string; dryRun?: boolean; taskId?: string };

function admitSettingsCall(input: { action: "resolve" | "change" | "history" | "undo" | "inventory"; keys?: string[]; taskId?: string; changes?: unknown[]; reason?: string; dryRun?: boolean; key?: string; cursor?: string; limit?: number; changeId?: string }): SettingsCall {
  const fields = {
    resolve: ["keys", "taskId"], change: ["changes", "reason", "dryRun", "taskId"],
    history: ["key", "cursor", "limit"], undo: ["changeId", "reason"], inventory: ["limit"],
  }[input.action];
  for (const [field, value] of Object.entries(input)) {
    if (field !== "action" && value !== undefined && !fields.includes(field)) throw new Error(`settings ${input.action}: "${field}" is not used by this action`);
  }
  if (input.action === "inventory") return { action: "inventory", ...(input.limit !== undefined ? { limit: input.limit } : {}) };
  if (input.action === "history") return { action: "history", ...(input.key ? { key: input.key } : {}), ...(input.cursor ? { cursor: input.cursor } : {}), ...(input.limit !== undefined ? { limit: input.limit } : {}) };
  if (input.action === "undo") {
    if (!input.changeId?.trim()) throw new Error("settings undo: changeId is required");
    if (!input.reason?.trim()) throw new Error("settings undo: reason is required, written for the maintainer");
    return { action: "undo", changeId: input.changeId, reason: input.reason };
  }
  if (input.action === "resolve") {
    return { action: "resolve", ...(input.keys ? { keys: input.keys } : {}), ...(input.taskId ? { taskId: input.taskId } : {}) };
  }
  if (!input.changes?.length) throw new Error(`settings ${input.action}: "changes" is required (1 to 50 changes)`);
  if (!input.reason?.trim()) throw new Error(`settings ${input.action}: "reason" is required, written for the maintainer`);
  return { action: input.action, changes: input.changes as ChangeRequest[], reason: input.reason,
    ...(input.dryRun ? { dryRun: true } : {}), ...(input.taskId ? { taskId: input.taskId } : {}) };
}

function signalText(result: ChangeResult): string {
  const signal = result.signal;
  if (!signal) return "";
  if (signal.status === "queued") return ` Stored now; worker ${signal.taskId} was signalled in its steering lane and uses it from its next model request (the request in flight keeps its settings). Confirm with resolve: worker.lastResponse shows what its latest response ran on.`;
  if (signal.status === "not-running") return ` Stored now; worker ${signal.taskId} is not running, so it takes effect when the task is resumed.`;
  return ` Stored now and used from the worker's next model request, but the signal to worker ${signal.taskId} was refused (${signal.error.code}: ${signal.error.message}).`;
}

export function createTronSettingsExtension(access: () => SettingsToolAccess | undefined, requestChange: NativeChangeRequest): ExtensionFactory {
  return pi => {
    pi.registerTool({
      name: "settings", label: "Settings",
      description: "Read and change Tron settings through typed writes. Reversible changes apply and are logged. Read bounded hooks (by event and extension), packages, Tron modules and MCP status with inventory. Read durable audit records with history; reverse a change with undo and its changeId. Only irreversible effects, trust/authority, privacy expansion, spend and installs need the exact shared native tap. dryRun validates and returns before/after without effects. Home may target its task worker; running workers adopt from the next model request and are signalled.",
      promptSnippet: "Change settings with the settings tool, never by editing settings files.",
      promptGuidelines: [
        "Use settings to read or change model, context, tools, permissions and run settings; never edit settings.json, .pi/ or trust files directly.",
        "Give every change a reason. Do not use generic forms to authorize effects; native change cards bind their exact before/after.",
      ],
      parameters: PARAMETERS, annotations: { openWorldHint: false }, executionMode: "sequential",
      execute: async (toolCallId, raw, signal, _onUpdate, context) => {
        const input = admitSettingsCall(raw);
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
        if (input.action === "inventory") {
          const result = await owner.inventory(input.limit);
          return { content: [{ type: "text" as const, text: JSON.stringify(result) }], details: result };
        }
        if (input.action === "history") {
          const { action: _action, ...query } = input;
          const result = await owner.history(query);
          return { content: [{ type: "text" as const, text: JSON.stringify(result) }], details: result };
        }
        const confirm = nativeChangeConfirmer(context, requestChange, signal);
        const result = input.action === "undo" ? await owner.undo(input.changeId, {
          reason: input.reason, toolCallId, ...(confirm ? { confirm } : {}),
        }) : await owner.change(input.changes, {
          reason: input.reason, toolCallId, ...(input.dryRun ? { dryRun: true } : {}), ...(input.taskId ? { taskId: input.taskId } : {}),
          ...(confirm ? { confirm } : {}),
        });
        const text = result.dryRun ? "Dry run; nothing changed." : result.status === "applied"
          ? `Applied and logged.${signalText(result)}` : result.status === "review" ? "A paired native change card is required; nothing changed." : `Change ${result.status}.`;
        return { content: [{ type: "text" as const, text: text + "\n" + JSON.stringify(result) }], details: result };
      },
    });
  };
}
