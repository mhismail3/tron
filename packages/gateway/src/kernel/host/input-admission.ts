import type { AgentSession } from "../pi/coding-agent.js";
import type { ImageContent } from "../pi/ai.js";
import type { RequestPolicy } from "./request-policy.js";
import type { ExtensionToolOrigin } from "../../protocol/types.js";

export type InputDelivery = "user" | "wake";
type InputTriggerSource = "automation";
export interface InputTriggerAttribution {
  kind: InputTriggerSource; sourceId: string; eventId: string; title: string;
}
export interface InputTriggerRoute { homeId: string; routeGeneration: number; sessionId: string; enabled: boolean }
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
export interface InputMessage {
  customType: string;
  content: string;
  display: boolean;
  details: { eventId: string; taskId?: string; trigger?: InputTriggerAttribution };
}
export interface InputTrigger {
  taskId?: string; message: InputMessage;
  deliveryMessage?: InputMessage;
}
export interface InputEnvelopeContext {
  session: AgentSession;
  policy: RequestPolicy;
  text: string;
  images: ImageContent[] | undefined;
  signal: AbortSignal | undefined;
  sessionFile(): string | undefined;
  entries(): number;
}

export interface InputAdmissionPolicy {
  admit(sessionId: string, operationId: string, delivery: InputDelivery,
    append: (message: InputMessage) => Promise<void>, envelope: () => Promise<InputEnvelope>): Promise<InputTrigger | undefined>;
  release(taskId: string, operationId: string, eventId: string): Promise<void>;
  settle(sessionId: string, operationId: string): Promise<void>;
  committed?(sessionId: string, operationId: string): Promise<void>;
  envelope(context: InputEnvelopeContext): Promise<InputEnvelope>;
  finished(startedAt: number, delivery: InputDelivery): void;
}
