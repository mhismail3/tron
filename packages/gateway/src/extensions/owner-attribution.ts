import { AsyncLocalStorage } from "node:async_hooks";
import { createHash } from "node:crypto";
import { basename, extname } from "node:path";
import type { Extension, LoadExtensionsResult, RegisteredCommand, RegisteredTool, ToolDefinition } from "@earendil-works/pi-coding-agent";
import { adaptedExtensionEventHandler, adaptedToolDefinition } from "./extension-adapters.js";
import type { ExtensionOwner } from "../protocol/types.js";
import { GatewayError } from "../errors.js";

/** The owner is intentionally opaque to extension code and is only readable by
 * the gateway presentation projection. AsyncLocalStorage preserves it across
 * promises and timers without guessing attribution for unattributed calls. */
const ownerStorage = new AsyncLocalStorage<ExtensionOwner>();
// Adapter classification is established once at the trusted extension-load
// boundary; transcript code never guesses from customType, text, or renderer
// registration.
const trustedSubagentOwnerIDs = new Set<string>();
const trustedSubagentAdapterSource = "npm:pi-subagents";
export interface InvocationExecutionContext {
  invocationId: string;
  operationId: string;
}
const invocationStorage = new AsyncLocalStorage<InvocationExecutionContext>();
const attributedCommandOwners = new WeakMap<RegisteredCommand["handler"], ExtensionOwner>();
const attributedToolOwners = new WeakMap<ToolDefinition["execute"], ExtensionOwner>();

export function currentExtensionOwner(): ExtensionOwner | undefined { return ownerStorage.getStore(); }
export function currentInvocationContext(): InvocationExecutionContext | undefined { return invocationStorage.getStore(); }
export function withInvocationContext<T>(context: InvocationExecutionContext, operation: () => T): T {
  return invocationStorage.run(context, operation);
}
export function attributedCommandOwner(command: RegisteredCommand | undefined): ExtensionOwner | undefined {
  return command ? attributedCommandOwners.get(command.handler) : undefined;
}
export function attributedToolOwner(tool: RegisteredTool | undefined): ExtensionOwner | undefined {
  return tool ? attributedToolOwners.get(tool.definition.execute) : undefined;
}

function humanizedDisplayName(extension: Extension): string {
  const sourcePath = extension.sourceInfo.baseDir || extension.sourceInfo.path || extension.resolvedPath || extension.path;
  const directory = basename(sourcePath);
  const candidate = extname(directory) ? directory.slice(0, -extname(directory).length) : directory;
  const words = candidate.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  return words.length === 0 ? "Extension" : words.map((word) => word[0]!.toUpperCase() + word.slice(1)).join(" ");
}

export function extensionOwnerFor(extension: Extension): ExtensionOwner {
  const source = extension.sourceInfo.source;
  const identity = `${source}\0${extension.resolvedPath}`;
  const id = `extension:${createHash("sha256").update(identity).digest("base64url")}`;
  if (source === trustedSubagentAdapterSource) trustedSubagentOwnerIDs.add(id);
  return { id, title: humanizedDisplayName(extension), source };
}

export function trustedExtensionOriginKind(owner: ExtensionOwner): "subagent" | "extension" {
  return trustedSubagentOwnerIDs.has(owner.id) ? "subagent" : "extension";
}

function owned<T extends (...args: any[]) => any>(fn: T, owner: ExtensionOwner): T {
  return ((...args: Parameters<T>) => ownerStorage.run(owner, () => fn(...args))) as T;
}

/** Wrap every callback registered by one loaded extension. The result is safe
 * to apply on every resource reload because each load result is wrapped once
 * and all maps/functions are retained as public Pi objects. */
export function attributeExtensions(base: LoadExtensionsResult): LoadExtensionsResult {
  const bashOwners = base.extensions.filter((extension) => extension.tools.has("bash"));
  if (bashOwners.length > 0) {
    throw new GatewayError("conflict", "The bash tool name is reserved by Tron");
  }
  const notifyOwners = base.extensions.filter((extension) => extension.tools.has("notify"));
  if (notifyOwners.some((extension) => extension.path !== "<inline:tron-notify>")) {
    throw new GatewayError("conflict", "The notify tool name is reserved by Tron");
  }
  if (notifyOwners.filter((extension) => extension.path === "<inline:tron-notify>").length > 1) {
    throw new GatewayError("conflict", "The first-party notify tool was registered more than once");
  }
  for (const extension of base.extensions) {
    const owner = extensionOwnerFor(extension);
    for (const [event, handlers] of extension.handlers) {
      extension.handlers.set(event, handlers.map((handler) => owned(adaptedExtensionEventHandler(extension, handler), owner)));
    }
    for (const [name, registered] of extension.tools) {
      const definition = adaptedToolDefinition(extension, name, registered.definition);
      const execute = owned(definition.execute, owner);
      attributedToolOwners.set(execute, owner);
      extension.tools.set(name, {
        ...registered,
        definition: {
          ...definition,
          execute,
          ...(definition.prepareArguments ? { prepareArguments: owned(definition.prepareArguments, owner) } : {}),
          ...(definition.renderCall ? { renderCall: owned(definition.renderCall, owner) } : {}),
          ...(definition.renderResult ? { renderResult: owned(definition.renderResult, owner) } : {}),
        } as ToolDefinition,
      } as RegisteredTool);
    }
    for (const [name, command] of extension.commands) {
      const handler = owned(command.handler, owner);
      attributedCommandOwners.set(handler, owner);
      extension.commands.set(name, { ...command, handler } as RegisteredCommand);
    }
    for (const [name, shortcut] of extension.shortcuts) {
      extension.shortcuts.set(name, { ...shortcut, handler: owned(shortcut.handler, owner) });
    }
    for (const [name, renderer] of extension.messageRenderers) extension.messageRenderers.set(name, owned(renderer, owner));
    for (const [name, renderer] of extension.entryRenderers ?? []) extension.entryRenderers!.set(name, owned(renderer, owner));
    if (extension.markdownTransformer) extension.markdownTransformer = owned(extension.markdownTransformer, owner);
  }
  return base;
}
