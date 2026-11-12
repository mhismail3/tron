import { createHash } from "node:crypto";
import { Type } from "../kernel/pi/ai.js";
import type { ExtensionFactory } from "../kernel/pi/coding-agent.js";
import { nativeChangeConfirmer, type NativeChangeRequest } from "../kernel/host/native-change.js";
import type { ChangeReview } from "../protocol/types.js";
import type { NotificationAdmissionStatus } from "./notification-service.js";
import type { AgentTerminalOutcome } from "../kernel/host/module-host.js";

interface TronNotificationEnqueue {
  (input: {
    sessionId: string;
    sourceId: string;
    kind: "explicit" | "agent_finished" | "waiting";
    message: string;
    title?: string;
    route?: { sessionId: string; machineId: string };
    readOnAdmission?: boolean;
  }): Promise<NotificationAdmissionStatus>;
}

const terminalMessages: Record<AgentTerminalOutcome, string> = {
  completed: "The agent finished responding.",
  limited: "The agent reached its response limit.",
  failed: "The agent stopped because of an error.",
  stopped: "The agent was stopped.",
  unknown: "The agent stopped without a final response.",
  interrupted: "The agent was interrupted before its outcome could be confirmed.",
};

export async function notifyTronAgentTerminal(input: {
  sessionId: string;
  sourceId: string;
  outcome: AgentTerminalOutcome;
  sessionTitle: string;
  machineId?: string;
  observed: boolean;
  suppressAutomatic: (input: { sessionId: string; sourceId: string; kind: "agent_finished" }) => Promise<"suppressed">;
  enqueue: TronNotificationEnqueue;
  pendingBackgroundWork?: number;
  waitingEpisode?: boolean;
}): Promise<void> {
  if (!input.machineId) return;
  const waiting = (input.pendingBackgroundWork ?? 0) > 0;
  const kind = waiting ? "waiting" as const : "agent_finished" as const;
  const identity = { sessionId: input.sessionId, sourceId: input.sourceId, kind };
  if (input.observed) {
    await input.suppressAutomatic({ ...identity, kind: "agent_finished" });
    return;
  }
  if (waiting && input.waitingEpisode) return;
  await input.enqueue({
    ...identity,
    title: input.sessionTitle,
    message: waiting
      ? `The agent is waiting on ${input.pendingBackgroundWork} background ${input.pendingBackgroundWork === 1 ? "task" : "tasks"}.`
      : terminalMessages[input.outcome],
    route: { sessionId: input.sessionId, machineId: input.machineId },
  });
}

export function pushRetryReview(input: { sessionId: string; toolCallId: string; reason: string }): ChangeReview {
  return {
    digest: createHash("sha256").update(JSON.stringify(["push-registration-retry", input.sessionId, input.toolCallId])).digest("hex"),
    title: "Retry push registration",
    requiresTap: true,
    reason: input.reason,
    intent: "push-registration-retry",
    items: [{
      label: "Push registration",
      before: "Stopped on the iPhone that approves this card",
      after: "Retried once there, with one fresh App Attest key",
      detail: "Only the iPhone that approves this card retries. No setting changes, and no other iPhone is affected.",
    }],
  };
}

export function createTronNotifyExtension(input: {
  sessionId: () => string;
  sessionTitle: () => string;
  machineId?: string;
  observed: () => boolean;
  enqueue: TronNotificationEnqueue;
  requestChange: NativeChangeRequest;
}): ExtensionFactory {
  return (pi) => {
    pi.registerTool({
      name: "push_retry",
      annotations: { openWorldHint: false },
      label: "Retry push",
      description: "Ask the user to retry this Mac's push registration on the iPhone that approves the exact native card. Nothing runs without that tap; the card names the iPhone.",
      promptSnippet: "Use push_retry only when push alerts are stopped and the user should retry registration on their iPhone.",
      promptGuidelines: ["push_retry shows a native card; approval retries registration on the approving iPhone only."],
      parameters: Type.Object({ reason: Type.String({ minLength: 1, maxLength: 2000 }) }, { additionalProperties: false }),
      executionMode: "sequential",
      execute: async (toolCallId, params, signal, _onUpdate, context) => {
        const confirm = nativeChangeConfirmer(context, input.requestChange, signal);
        if (!confirm) {
          return { content: [{ type: "text", text: "A paired native change card is required; nothing changed." }], details: { status: "review" } };
        }
        const review = pushRetryReview({ sessionId: input.sessionId(), toolCallId, reason: params.reason });
        const result = await confirm(review, async acceptance => ({ status: "requested" as const, deviceId: acceptance.deviceId }));
        const status = result ? result.status : "declined";
        return { content: [{ type: "text", text: status === "requested" ? "Retry requested on the approving iPhone." : `Push retry ${status}; nothing changed.` }], details: { status } };
      },
    });
    pi.registerTool({
      name: "notify",
      annotations: { openWorldHint: false },
      label: "Notify",
      description: "Queue a bounded notification to the user's notification-enabled Tron iPhones. Routing and delivery are controlled by Tron.",
      promptSnippet: "Send a notification to the user's Tron iPhones when useful.",
      promptGuidelines: ["Use notify only for useful attention requests; it is queued push delivery, not proof that the user received it."],
      parameters: Type.Object({ message: Type.String({ minLength: 1, maxLength: 512 }) }, { additionalProperties: false }),
      executionMode: "sequential",
      execute: async (toolCallId, params) => {
        const sessionId = input.sessionId();
        const observed = input.observed();
        const status = await input.enqueue({
          sessionId,
          sourceId: toolCallId,
          kind: "explicit",
          title: input.sessionTitle(),
          message: params.message,
          ...(input.machineId ? { route: { sessionId, machineId: input.machineId } } : {}),
          ...(observed ? { readOnAdmission: true } : {}),
        });
        return {
          content: [{ type: "text", text: status === "queued" ? "Notification queued." : `Notification ${status.replaceAll("_", " ")}.` }],
          details: { status },
        };
      },
    });
  };
}
