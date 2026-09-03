import { StringEnum } from "@earendil-works/pi-ai";
import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { currentInvocationContext } from "../extensions/owner-attribution.js";
import type { JsonValue } from "../protocol/types.js";

export interface ScheduleToolRequest {
  action: "list" | "show" | "create" | "enable" | "pause" | "delete" | "runNow" | "cancel" | "resolve";
  name?: string;
  prompt?: string;
  notificationMessage?: string;
  target?: "currentSession" | "newSessionInWorkspace";
  at?: string;
  everyMinutes?: number;
  timezone?: string;
  localTime?: string;
  weekdays?: number[];
  activate?: boolean;
  automationId?: string;
  runId?: string;
  expectedRevision?: number;
  outcome?: "succeeded" | "failed" | "cancelled";
}

export interface ScheduleToolResult {
  message: string;
  details: JsonValue;
}

export interface ScheduleToolOperations {
  execute(sessionId: string, toolCallId: string, request: ScheduleToolRequest): Promise<ScheduleToolResult>;
}

const parameters = Type.Object({
  action: StringEnum(["list", "show", "create", "enable", "pause", "delete", "runNow", "cancel", "resolve"] as const),
  name: Type.Optional(Type.String({ minLength: 1, maxLength: 256 })),
  prompt: Type.Optional(Type.String({ minLength: 1, maxLength: 65_536 })),
  notificationMessage: Type.Optional(Type.String({ minLength: 1, maxLength: 512 })),
  target: Type.Optional(StringEnum(["currentSession", "newSessionInWorkspace"] as const)),
  at: Type.Optional(Type.String({ minLength: 1, maxLength: 64 })),
  everyMinutes: Type.Optional(Type.Integer({ minimum: 1, maximum: 525_600 })),
  timezone: Type.Optional(Type.String({ minLength: 1, maxLength: 128 })),
  localTime: Type.Optional(Type.String({ minLength: 5, maxLength: 5 })),
  weekdays: Type.Optional(Type.Array(Type.Integer({ minimum: 1, maximum: 7 }), { minItems: 1, maxItems: 7 })),
  activate: Type.Optional(Type.Boolean()),
  automationId: Type.Optional(Type.String({ minLength: 1, maxLength: 64 })),
  runId: Type.Optional(Type.String({ minLength: 1, maxLength: 64 })),
  expectedRevision: Type.Optional(Type.Integer({ minimum: 1 })),
  outcome: Type.Optional(StringEnum(["succeeded", "failed", "cancelled"] as const)),
}, { additionalProperties: false });

export function createTronScheduleExtension(input: {
  sessionId: () => string;
  operations: ScheduleToolOperations;
}): ExtensionFactory {
  return (pi) => {
    pi.registerTool({
      name: "schedule",
      label: "Schedule",
      description: "Create and manage durable Gateway-owned automations for this Tron session. Create accepts exactly one trigger: at, everyMinutes, or timezone + localTime + weekdays. Provide either prompt or notificationMessage, not both. Prompt automations may target the current session or create a new session in its workspace per run.",
      promptSnippet: "Create and manage durable schedules and reminders for the current Tron session",
      promptGuidelines: [
        "Use schedule only when the user explicitly asks to create, change, run, cancel, or resolve a persistent automation.",
        "The schedule tool manages only the current persisted Tron session, or a new session in its current workspace per prompt run; it cannot schedule shell commands, deployments, or Gateway lifecycle actions.",
        "Do not use schedule from inside a scheduled automation to create or mutate another automation.",
      ],
      parameters,
      executionMode: "sequential",
      execute: async (toolCallId, request, _signal, _onUpdate, ctx) => {
        const context = currentInvocationContext();
        if (request.action !== "list" && request.action !== "show"
          && context?.operationId?.startsWith("automation:")) {
          throw new Error("Scheduled automation turns cannot mutate automations");
        }
        if (request.action !== "list" && request.action !== "show") {
          if (!ctx.hasUI) throw new Error("Automation mutations require an interactive user confirmation");
          const confirmed = await ctx.ui.confirm(
            "Confirm automation change",
            request.action === "create" && request.activate !== true
              ? "Create this automation as a disabled draft?"
              : `Allow Tron to ${request.action} this durable automation?`,
          );
          if (!confirmed) {
            return { content: [{ type: "text", text: "Automation change cancelled by the user." }], details: { cancelled: true } };
          }
        }
        const result = await input.operations.execute(input.sessionId(), toolCallId, request);
        return {
          content: [{ type: "text", text: result.message }],
          details: result.details,
        };
      },
    });
  };
}
