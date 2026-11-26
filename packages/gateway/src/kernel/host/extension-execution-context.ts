import { AsyncLocalStorage } from "node:async_hooks";
import type { ExtensionOwner } from "../../protocol/types.js";

const ownerStorage = new AsyncLocalStorage<ExtensionOwner>();
interface InvocationExecutionContext {
  invocationId: string;
  operationId: string;
  trigger?: import("./input-admission.js").InputTriggerAttribution | undefined;
}
const invocationStorage = new AsyncLocalStorage<InvocationExecutionContext>();
const toolCallSignalStorage = new AsyncLocalStorage<AbortSignal>();

export function currentExtensionOwner(): ExtensionOwner | undefined { return ownerStorage.getStore(); }
export function withExtensionOwner<T>(owner: ExtensionOwner, operation: () => T): T {
  return ownerStorage.run(owner, operation);
}
export function currentInvocationContext(): InvocationExecutionContext | undefined { return invocationStorage.getStore(); }
export function withInvocationContext<T>(context: InvocationExecutionContext, operation: () => T): T {
  return invocationStorage.run(context, operation);
}
export function currentToolCallSignal(): AbortSignal | undefined { return toolCallSignalStorage.getStore(); }
export function withToolCallSignal<T>(signal: AbortSignal, operation: () => T): T {
  return toolCallSignalStorage.run(signal, operation);
}
