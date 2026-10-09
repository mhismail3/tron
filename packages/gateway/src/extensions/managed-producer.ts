import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { ExtensionOwner, ExtensionToolOrigin } from "../protocol/types.js";
import { withExtensionOwner } from "./owner-attribution.js";

/** The SDK retains content by reference when constructing/queuing appMessage.
 * Metadata shares that message's lifetime, not a slot-wide queue or ID map. */
export interface ManagedMessageCapture {
  origin: ExtensionToolOrigin;
  wakeOperationId?: string;
}
const messageProducers = new WeakMap<object, ManagedMessageCapture>();
const managedContent = Symbol("managed-producer-content");

export function isManagedProducerContent(content: unknown): boolean {
  return content !== null && typeof content === "object" && Object.hasOwn(content, managedContent);
}

export function capturedManagedMessage(content: unknown): ManagedMessageCapture | undefined {
  return content !== null && typeof content === "object" ? messageProducers.get(content) : undefined;
}

/** Bind the complete managed API, including actions retained by factory-time
 * timers/watchers/ports. Async call-site context is never producer authority. */
export type ManagedInternalWake = (content: Parameters<ExtensionAPI["sendUserMessage"]>[0],
  options: Parameters<ExtensionAPI["sendUserMessage"]>[1], owner: ExtensionOwner, messages: readonly ManagedMessageCapture[]) => Promise<void> | void;

/** Delivery policy is typed producer intent, never rendered notification text. */
function isProviderContextOnly(message: Parameters<ExtensionAPI["sendMessage"]>[0]): boolean {
  return message.customType === "subagent-incremental-child-notify"
    || (message.customType === "subagent_supervisor_request"
      && message.details !== null && typeof message.details === "object"
      && (message.details as { expectsReply?: unknown }).expectsReply === false);
}

export function managedProducerAPI(pi: ExtensionAPI, owner: ExtensionOwner, internalWake?: ManagedInternalWake): ExtensionAPI {
  // ParentWake sends context and its wake synchronously. A frame belongs to
  // this factory API, not ambient async context; a microtask retires it unused.
  let frame: ManagedMessageCapture[] | undefined;
  return new Proxy(pi, {
    get(target, key, receiver) {
      const value = Reflect.get(target, key, receiver);
      if (typeof value !== "function") return value;
      if (key === "sendMessage") return (message: Parameters<ExtensionAPI["sendMessage"]>[0], options: Parameters<ExtensionAPI["sendMessage"]>[1]) => {
        const canonicalContent = message.content;
        const content = typeof canonicalContent === "string"
          ? [{ type: "text" as const, text: canonicalContent }]
          : [...(canonicalContent ?? [])];
        // Preserve the producer's canonical representation. The transient
        // array is the SDK-valid identity carrier, not a persisted envelope.
        if (typeof canonicalContent === "string") {
          Object.defineProperty(content, "toJSON", { value: () => canonicalContent });
        }
        // The message-local brand prevents a missing capture from falling back
        // to another producer's ambient loop context. It is never serialized.
        Object.defineProperty(content, managedContent, { value: true });
        const capture: ManagedMessageCapture = { origin: { source: owner.source, owner } };
        messageProducers.set(content, capture);
        const contextOnly = isProviderContextOnly(message);
        if (!contextOnly && !frame) {
          const current: ManagedMessageCapture[] = [];
          frame = current;
          queueMicrotask(() => { if (frame === current) frame = undefined; });
        }
        if (!contextOnly) frame!.push(capture);
        // Explicit context-only intent never owns a wake. Completion, control and decision
        // sources own parent action; the provider also suppresses idle wakes
        // before its ParentWake wrapper reaches this boundary.
        const delivery = contextOnly
          ? { ...options, triggerTurn: false } : options;
        return withExtensionOwner(owner, () => target.sendMessage({ ...message, content }, delivery));
      };
      if (key === "sendUserMessage") return (content: Parameters<ExtensionAPI["sendUserMessage"]>[0], options: Parameters<ExtensionAPI["sendUserMessage"]>[1]) => {
        if (!internalWake) throw new Error("Managed internal wake has no RuntimeSlot admission owner");
        const messages = frame ?? [];
        frame = undefined;
        return internalWake(content, options, owner, messages);
      };
      return (...args: unknown[]) => withExtensionOwner(owner, () => Reflect.apply(value, target, args));
    },
  });
}
