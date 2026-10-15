import { Type } from "@earendil-works/pi-ai";
import type { ExtensionFactory, ToolInfo } from "@earendil-works/pi-coding-agent";
import type { ChangeRequest, ChangeResult } from "./settings-model.js";
import type { Resolution } from "./settings-resolver.js";

/**
 * The `settings` tool and the turn's web mark (docs/settings-model.md 5.1, 5.4).
 *
 * The tool is a thin client of `settings.resolve` and `settings.change` for an
 * agent: Home, a task worker or an ordinary chat's agent, each recorded as that
 * actor. It always targets the chat it runs in, so it reaches that chat's
 * layers (Chat, Project, Mac, and Home's profile) and nothing else.
 *
 * The web mark is set by the Gateway from the tool calls it executes, never from
 * the model's own account. A tool marks the run unless it declares
 * `annotations.openWorldHint: false` (Mohsin, 2026-10-11): an undeclared tool is
 * untrusted. The mark belongs to the run (the prompt to the agent's final
 * answer): content a tool returned stays in context for the rest of it.
 */

export const SETTINGS_OUTCOME_MESSAGE = "tron.settings-outcome.v1";

/** What the session runtime gives the tool: its own target and identity. */
export interface SettingsToolAccess {
  resolve(keys?: string[]): Promise<Resolution>;
  change(changes: ChangeRequest[], input: { reason: string; dryRun?: boolean; toolCallId: string; web: boolean }): Promise<ChangeResult>;
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

const PARAMETERS = Type.Union([
  Type.Object({
    action: Type.Literal("resolve"),
    keys: Type.Optional(Type.Array(Type.String({ minLength: 1, maxLength: 200 }), { maxItems: 200 })),
  }, { additionalProperties: false }),
  Type.Object({
    action: Type.Literal("change"),
    changes: Type.Array(CHANGE, { minItems: 1, maxItems: 50 }),
    reason: Type.String({ minLength: 1, maxLength: 2_000, description: "Why, for the maintainer." }),
    dryRun: Type.Optional(Type.Boolean()),
  }, { additionalProperties: false }),
]);

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
      description: "Read (resolve) or change Tron settings for this chat. A change sets or unsets one key at one layer and needs a reason. Its tier decides what happens: quiet applies, notify applies and tells the maintainer, approve waits for his tap (pending). Web or browser content read earlier in the run raises the tier one step; dryRun returns the tier.",
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
          const resolution = await owner.resolve(input.keys);
          const summary = resolution.keys.map(key => ({
            key: key.key, ...(key.qualifiers ? { qualifiers: key.qualifiers } : {}), value: key.display, layer: key.layer,
            ...(key.applied ? {} : { applied: false, reason: key.reason }),
          }));
          return { content: [{ type: "text", text: JSON.stringify({ layers: resolution.layers, keys: summary }) }], details: resolution };
        }
        const result = await owner.change(input.changes as ChangeRequest[], {
          reason: input.reason, ...(input.dryRun ? { dryRun: true } : {}), toolCallId, web: marked,
        });
        const text = result.status === "pending"
          ? `Pending the maintainer's approval (request ${result.approval!.requestId}, expires ${result.approval!.expiresAt}). Nothing changed yet.`
          : result.dryRun ? `Dry run: tier ${result.tier}.` : `Applied at tier ${result.tier}.`;
        return { content: [{ type: "text", text: `${text}\n${JSON.stringify(result)}` }], details: result };
      },
    });
  };
}
