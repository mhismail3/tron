import { AsyncLocalStorage } from "node:async_hooks";
import type { ExtensionOwner } from "../../protocol/types.js";

/** Call-time identity shared by extension callbacks and host presentation across awaits. */
const ownerStorage = new AsyncLocalStorage<ExtensionOwner>();
export interface InvocationExecutionContext {
  invocationId: string;
  operationId: string;
}
const invocationStorage = new AsyncLocalStorage<InvocationExecutionContext>();

export function currentExtensionOwner(): ExtensionOwner | undefined { return ownerStorage.getStore(); }
export function withExtensionOwner<T>(owner: ExtensionOwner, operation: () => T): T {
  return ownerStorage.run(owner, operation);
}
export function currentInvocationContext(): InvocationExecutionContext | undefined { return invocationStorage.getStore(); }
export function withInvocationContext<T>(context: InvocationExecutionContext, operation: () => T): T {
  return invocationStorage.run(context, operation);
}
