import { Type } from "@earendil-works/pi-ai";
import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
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

export type AgentTerminalOutcome = "completed" | "limited" | "failed" | "stopped" | "unknown" | "interrupted";

const terminalMessages: Record<AgentTerminalOutcome, string> = {
  completed: "The agent finished responding.",
  limited: "The agent reached its response limit.",
  failed: "The agent stopped because of an error.",
  stopped: "The agent was stopped.",
  unknown: "The agent stopped without a final response.",
  interrupted: "The agent was interrupted before its outcome could be confirmed.",
};

/** Static product copy only: provider errors and partial responses stay in chat. */
export async function notifyTronAgentTerminal(input: {
  sessionId: string;
  sourceId: string;
  outcome: AgentTerminalOutcome;
  sessionTitle: string;
  machineId?: string;
  observed: boolean;
  suppressAutomatic: (input: { sessionId: string; sourceId: string; kind: "agent_finished" }) => Promise<"suppressed">;
  enqueue: TronNotificationEnqueue;
}): Promise<void> {
  if (!input.machineId) return;
  const identity = { sessionId: input.sessionId, sourceId: input.sourceId, kind: "agent_finished" as const };
  if (input.observed) {
    await input.suppressAutomatic(identity);
    return;
  }
  await input.enqueue({
    ...identity,
    title: input.sessionTitle,
    message: terminalMessages[input.outcome],
    route: { sessionId: input.sessionId, machineId: input.machineId },
  });
}

/** First-party inline Pi extension. Its closures are the entire push capability. */
export function createTronNotifyExtension(input: {
  sessionId: () => string;
  sessionTitle: () => string;
  machineId?: string;
  enqueue: TronNotificationEnqueue;
}): ExtensionFactory {
  return (pi) => {
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
