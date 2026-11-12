import type { ExtensionAPI } from "../pi/coding-agent.js";
import type { ExtensionOwner, ExtensionToolOrigin } from "../../protocol/types.js";
import { withExtensionOwner } from "../host/extension-execution-context.js";
import { injectedText } from "../host/injected-text.js";

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

export type ManagedInternalWake = (content: Parameters<ExtensionAPI["sendUserMessage"]>[0],
  options: Parameters<ExtensionAPI["sendUserMessage"]>[1], owner: ExtensionOwner, messages: readonly ManagedMessageCapture[]) => Promise<void> | void;

function isProviderContextOnly(message: Parameters<ExtensionAPI["sendMessage"]>[0]): boolean {
  return message.customType === "subagent-incremental-child-notify"
    || (message.customType === "subagent_supervisor_request"
      && message.details !== null && typeof message.details === "object"
      && (message.details as { expectsReply?: unknown }).expectsReply === false);
}

export function managedProducerAPI(pi: ExtensionAPI, owner: ExtensionOwner, internalWake?: ManagedInternalWake): ExtensionAPI {
  let frame: ManagedMessageCapture[] | undefined;
  return new Proxy(pi, {
    get(target, key, receiver) {
      const value = Reflect.get(target, key, receiver);
      if (typeof value !== "function") return value;
      if (key === "sendMessage") return (message: Parameters<ExtensionAPI["sendMessage"]>[0], options: Parameters<ExtensionAPI["sendMessage"]>[1]) => {
        const canonicalContent = injectedText(message.content ?? [], "pi-subagents", "subagent-notice", "none");
        const content = typeof canonicalContent === "string"
          ? [{ type: "text" as const, text: canonicalContent }]
          : [...(canonicalContent ?? [])];
        if (typeof canonicalContent === "string") {
          Object.defineProperty(content, "toJSON", { value: () => canonicalContent });
        }
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
        const delivery = contextOnly
          ? { ...options, triggerTurn: false } : options;
        return withExtensionOwner(owner, () => target.sendMessage({ ...message, content }, delivery));
      };
      if (key === "sendUserMessage") return (content: Parameters<ExtensionAPI["sendUserMessage"]>[0], options: Parameters<ExtensionAPI["sendUserMessage"]>[1]) => {
        if (!internalWake) throw new Error("Managed internal wake has no RuntimeSlot admission owner");
        const messages = frame ?? [];
        frame = undefined;
        const wrapped = injectedText(content, "pi-subagents", "subagent-notice", "none");
        return internalWake(wrapped, options, owner, messages);
      };
      return (...args: unknown[]) => withExtensionOwner(owner, () => Reflect.apply(value, target, args));
    },
  });
}
