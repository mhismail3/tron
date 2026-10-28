import type { AgentSession } from "../pi/coding-agent.js";
import type { ImageContent } from "../pi/ai.js";
import type { RequestPolicy } from "./request-policy.js";
import type { ExtensionToolOrigin } from "../../protocol/types.js";

export const CONTEXT_DELIVERY_RECEIPT_TYPE = "tron.context-delivery.v4";
export type InputDelivery = "user" | "wake";
/** Gateway-owned trigger sources, never maintainer authority. */
export type InputTriggerSource = "automation";
export const INPUT_TRIGGER_MESSAGE = "tron.home-trigger.v1";
export interface InputTriggerAttribution {
  kind: InputTriggerSource; sourceId: string; eventId: string; title: string;
}
export interface InputTriggerRoute { homeId: string; routeGeneration: number; sessionId: string; enabled: boolean }
/** Each producer retains its durable outbox; Home owns only admission and wake policy. */
export interface InputTriggerInbox {
  pending(route: InputTriggerRoute, delivery: InputDelivery): boolean;
  admit(route: InputTriggerRoute, operationId: string, delivery: InputDelivery,
    append: (message: InputMessage) => Promise<void>, envelope: () => Promise<InputEnvelope>): Promise<InputTrigger | undefined>;
  release(eventId: string, operationId: string): Promise<void>;
  committed(sessionId: string, operationId: string): Promise<void>;
}
export function inputMessageOrigin(message: InputMessage): ExtensionToolOrigin | undefined {
  const trigger = message.details.trigger;
  return trigger ? { source: `gateway:trigger:${trigger.kind}`, owner: { id: trigger.sourceId, title: trigger.title, source: `gateway:trigger:${trigger.kind}` } } : undefined;
}
export interface InputEnvelope { signal: AbortSignal; tokens: number; freshTokens: number; bytes: number; entries: number }
/** The kernel needs only these identities to bind canonical input receipts.
 * Implementing modules retain their richer message metadata without conversion. */
export interface InputMessage {
  customType: string;
  content: string;
  display: boolean;
  details: { eventId: string; taskId?: string; trigger?: InputTriggerAttribution };
}
export interface InputTrigger { taskId?: string; message: InputMessage }
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
  /** Called after canonical attribution is persisted, before source acknowledgement. */
  committed?(sessionId: string, operationId: string): Promise<void>;
  envelope(context: InputEnvelopeContext): Promise<InputEnvelope>;
  finished(startedAt: number, delivery: InputDelivery): void;
}
