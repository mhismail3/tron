import type { AgentSession } from "../pi/coding-agent.js";
import type { ImageContent } from "../pi/ai.js";
import type { RequestPolicy } from "./request-policy.js";

export const CONTEXT_DELIVERY_RECEIPT_TYPE = "tron.context-delivery.v4";
export type InputDelivery = "user" | "wake";
export interface InputEnvelope { signal: AbortSignal; tokens: number; freshTokens: number; bytes: number; entries: number }
/** The kernel needs only these identities to bind canonical input receipts.
 * Implementing modules retain their richer message metadata without conversion. */
export interface InputMessage {
  customType: string;
  content: string;
  display: boolean;
  details: { eventId: string; taskId: string };
}
export interface InputTrigger { taskId: string; message: InputMessage }
export interface InputEnvelopeContext {
  session: AgentSession;
  policy: RequestPolicy;
  text: string;
  images: ImageContent[] | undefined;
  signal: AbortSignal | undefined;
  sessionFile(): string | undefined;
  entries(): number;
}

/** Admission is awaited in the run lane. An unpersisted trigger is released
 * before terminal settlement; the module owns delivery bounds and diagnostics. */
export interface InputAdmissionPolicy {
  admit(sessionId: string, operationId: string, delivery: InputDelivery,
    append: (message: InputMessage) => Promise<void>, envelope: () => Promise<InputEnvelope>): Promise<InputTrigger | undefined>;
  release(taskId: string, operationId: string, eventId: string): Promise<void>;
  settle(sessionId: string, operationId: string): Promise<void>;
  envelope(context: InputEnvelopeContext): Promise<InputEnvelope>;
  finished(startedAt: number, delivery: InputDelivery): void;
}
