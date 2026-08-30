import { Type } from "typebox";
import type { ExtensionContext, ExtensionFactory } from "@earendil-works/pi-coding-agent";
import type { NotificationAdmissionStatus } from "./notification-service.js";

export interface TronNotificationEnqueue {
  (input: {
    sessionId: string;
    sourceId: string;
    kind: "explicit" | "agent_finished";
    message: string;
    title?: string;
    route?: { sessionId: string; machineId: string };
  }): Promise<NotificationAdmissionStatus>;
}

function latestSuccessfulAssistantEntry(ctx: ExtensionContext): { id: string } | undefined {
  const entry = ctx.sessionManager.getBranch().findLast((candidate) => candidate.type === "message"
    && candidate.message.role === "assistant");
  if (entry?.type !== "message" || entry.message.role !== "assistant") return undefined;
  return entry.message.stopReason === "stop" || entry.message.stopReason === "length" ? entry : undefined;
}

/** First-party inline Pi extension. Its closure is the entire push capability. */
export function createTronNotifyExtension(input: {
  sessionId: () => string;
  sessionTitle: () => string;
  machineId?: string;
  isAutomaticCompletionSuppressed: (completionId: string) => boolean;
  suppressAutomaticCompletion: (input: { sessionId: string; sourceId: string }) => Promise<"suppressed">;
  enqueue: TronNotificationEnqueue;
}): ExtensionFactory {
  return (pi) => {
    let finalRunCompletedSuccessfully = false;

    pi.on("agent_start", () => {
      finalRunCompletedSuccessfully = false;
    });

    pi.on("agent_end", (event) => {
      const assistant = event.messages.findLast((message) => message.role === "assistant");
      finalRunCompletedSuccessfully = assistant?.role === "assistant"
        && (assistant.stopReason === "stop" || assistant.stopReason === "length");
    });

    pi.on("agent_settled", async (_event, ctx) => {
      // A later extension may already have started a continuation. Its
      // agent_start/agent_end events own the next eventual idle settlement.
      if (!ctx.isIdle()) return;
      const shouldNotify = finalRunCompletedSuccessfully;
      finalRunCompletedSuccessfully = false;
      if (!shouldNotify || !input.machineId) return;
      const completion = latestSuccessfulAssistantEntry(ctx);
      if (!completion) return;
      const sessionId = input.sessionId();
      if (input.isAutomaticCompletionSuppressed(completion.id)) {
        await input.suppressAutomaticCompletion({ sessionId, sourceId: completion.id });
        return;
      }
      await input.enqueue({
        sessionId,
        sourceId: completion.id,
        kind: "agent_finished",
        title: input.sessionTitle(),
        message: "The agent finished responding.",
        route: { sessionId, machineId: input.machineId },
      });
    });

    pi.registerTool({
      name: "notify",
      label: "Notify",
      description: "Queue a bounded notification to the user's notification-enabled Tron iPhones. Routing and delivery are controlled by Tron.",
      promptSnippet: "Send a notification to the user's Tron iPhones when useful.",
      promptGuidelines: ["Use notify only for useful attention requests; it is queued push delivery, not proof that the user received it."],
      parameters: Type.Object({ message: Type.String({ minLength: 1, maxLength: 512 }) }, { additionalProperties: false }),
      executionMode: "sequential",
      execute: async (toolCallId, params) => {
        const sessionId = input.sessionId();
        const status = await input.enqueue({
          sessionId,
          sourceId: toolCallId,
          kind: "explicit",
          title: input.sessionTitle(),
          message: params.message,
          ...(input.machineId ? { route: { sessionId, machineId: input.machineId } } : {}),
        });
        return {
          content: [{ type: "text", text: status === "queued" ? "Notification queued." : `Notification ${status.replaceAll("_", " ")}.` }],
          details: { status },
        };
      },
    });
  };
}
