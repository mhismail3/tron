import { Type } from "typebox";
import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import type { NotificationAdmissionStatus } from "./notification-service.js";

export interface TronNotificationEnqueue {
  (input: { sessionId: string; toolCallId: string; kind: "explicit"; message: string }): Promise<NotificationAdmissionStatus>;
}

/** First-party inline Pi extension. Its closure is the entire push capability. */
export function createTronNotifyExtension(input: {
  sessionId: () => string;
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
        const status = await input.enqueue({ sessionId: input.sessionId(), toolCallId, kind: "explicit", message: params.message });
        return {
          content: [{ type: "text", text: status === "queued" ? "Notification queued." : `Notification ${status.replaceAll("_", " ")}.` }],
          details: { status },
        };
      },
    });
  };
}
