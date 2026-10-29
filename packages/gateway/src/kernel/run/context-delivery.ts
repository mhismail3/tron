import type { AgentSession } from "../pi/coding-agent.js";
import { CONTEXT_DELIVERY_RECEIPT_TYPE, SETTINGS_OUTCOME_MESSAGE } from "../receipts/delivery-tags.js";
import { inputMessageOrigin, type InputMessage } from "../host/input-admission.js";
import type { JsonValue } from "../../protocol/types.js";
import { safeJson } from "../projection/projection.js";
import { GatewayError } from "../../errors.js";
import { makeContextDeliveryReceipt } from "../receipts/context-delivery-receipts.js";

export async function deliverPromptInput(
  context: { readonly inboxAttributedMessages: Set<string>; persistCanonicalCustomEntry(type: string, data: JsonValue, identity: string): Promise<void> },
  session: AgentSession, message: InputMessage, committed?: () => Promise<void>,
): Promise<void> {
  // Recover missing attribution without appending the firing or replaying its turn.
  const existing = message.details.trigger ? session.sessionManager.getBranch().find(candidate => candidate.type === "custom_message"
    && (candidate.details as { eventId?: unknown } | undefined)?.eventId === message.details.eventId) : undefined;
  if (existing && (existing.type !== "custom_message" || existing.customType !== message.customType
    || JSON.stringify(existing.content) !== JSON.stringify(message.content) || JSON.stringify(existing.details) !== JSON.stringify(message.details))) {
    throw new GatewayError("conflict", "Trigger delivery contradicts its canonical message");
  }
  context.inboxAttributedMessages.add(message.details.eventId);
  try { if (!existing) await session.sendCustomMessage(message, { triggerTurn: false }); }
  finally { context.inboxAttributedMessages.delete(message.details.eventId); }
  const entry = existing ?? session.sessionManager.getLeafEntry();
  if (entry?.type !== "custom_message" || entry.customType !== message.customType
    || (entry.details as { eventId?: string })?.eventId !== message.details.eventId) throw new GatewayError("conflict", "Home task message lost its exact canonical identity");
  const settings = message.customType === SETTINGS_OUTCOME_MESSAGE;
  const source = settings ? "gateway:settings" : "gateway:home-task";
  await context.persistCanonicalCustomEntry(CONTEXT_DELIVERY_RECEIPT_TYPE,
    safeJson(makeContextDeliveryReceipt(entry.id, "stored", inputMessageOrigin(message) ?? { source,
      owner: { id: message.details.taskId!, title: settings ? "Settings" : "Home task", source } })), entry.id);
  await committed?.();
}
