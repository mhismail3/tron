import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { ExtensionOwner, ExtensionToolOrigin } from "../protocol/types.js";
import { withExtensionOwner } from "./owner-attribution.js";

/** The SDK retains content by reference when constructing/queuing appMessage.
 * Metadata shares that message's lifetime, not a slot-wide queue or ID map. */
const messageProducers = new WeakMap<object, ExtensionToolOrigin>();
const managedContent = Symbol("managed-producer-content");

export function isManagedProducerContent(content: unknown): boolean {
  return content !== null && typeof content === "object" && Object.hasOwn(content, managedContent);
}

export function capturedMessageProducer(content: unknown): ExtensionToolOrigin | undefined {
  return content !== null && typeof content === "object" ? messageProducers.get(content) : undefined;
}

/** Bind the complete managed API, including actions retained by factory-time
 * timers/watchers/ports. Async call-site context is never producer authority. */
export function managedProducerAPI(pi: ExtensionAPI, owner: ExtensionOwner): ExtensionAPI {
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
        messageProducers.set(content, { source: owner.source, owner });
        return withExtensionOwner(owner, () => target.sendMessage({ ...message, content }, options));
      };
      return (...args: unknown[]) => withExtensionOwner(owner, () => Reflect.apply(value, target, args));
    },
  });
}
