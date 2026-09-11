import { AsyncLocalStorage } from "node:async_hooks";
import { createHash } from "node:crypto";
import { basename, extname } from "node:path";
import type { Extension, LoadExtensionsResult, RegisteredCommand, RegisteredTool, ToolDefinition } from "@earendil-works/pi-coding-agent";
import { adaptedExtensionEventHandler, adaptedToolDefinition } from "./extension-adapters.js";
import type { ExtensionOwner } from "../protocol/types.js";
import { GatewayError } from "../errors.js";
import type { BrowserLiveViewRegistry } from "../display/browser-live-view.js";
import { observeTrustedAgentBrowserResult } from "../display/browser-live-view-adapter.js";

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
const attributedCommandOwners = new WeakMap<RegisteredCommand["handler"], Extension>();
const attributedToolOwners = new WeakMap<ToolDefinition["execute"], Extension>();

export function currentExtensionOwner(): ExtensionOwner | undefined { return ownerStorage.getStore(); }
export function currentInvocationContext(): InvocationExecutionContext | undefined { return invocationStorage.getStore(); }
export function withInvocationContext<T>(context: InvocationExecutionContext, operation: () => T): T {
  return invocationStorage.run(context, operation);
}
export function attributedCommandOwner(command: RegisteredCommand | undefined): ExtensionOwner | undefined {
  const extension = command ? attributedCommandOwners.get(command.handler) : undefined;
  return extension ? extensionOwnerFor(extension) : undefined;
}
export function attributedToolOwner(tool: RegisteredTool | undefined): ExtensionOwner | undefined {
  const extension = tool ? attributedToolOwners.get(tool.definition.execute) : undefined;
  return extension ? extensionOwnerFor(extension) : undefined;
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

function owned<T extends (...args: any[]) => any>(fn: T, extension: Extension): T {
  // The SDK finalizes package SourceInfo after extensionsOverride returns.
  // Resolve at admission so callbacks and command/tool lookups agree.
  return ((...args: Parameters<T>) => ownerStorage.run(extensionOwnerFor(extension), () => fn(...args))) as T;
}

/** Wrap every callback registered by one loaded extension. The result is safe
 * to apply on every resource reload because each load result is wrapped once
 * and all maps/functions are retained as public Pi objects. */
export function attributeExtensions(base: LoadExtensionsResult, browserLiveView?: {
  views: BrowserLiveViewRegistry;
  sessionId: string;
  runtimeGeneration: string;
}): LoadExtensionsResult {
  const loadToken = browserLiveView?.views.beginSessionLoad(browserLiveView.sessionId);
  const bashOwners = base.extensions.filter((extension) => extension.tools.has("bash"));
  if (bashOwners.length > 0) {
    throw new GatewayError("conflict", "The bash tool name is reserved by Tron");
  }
  for (const [tool, owner] of [["notify", "tron-notify"], ["display", "tron-display"], ["native_capture", "tron-native-capture"]] as const) {
    const owners = base.extensions.filter((extension) => extension.tools.has(tool));
    if (owners.some((extension) => extension.path !== `<inline:${owner}>`)) {
      throw new GatewayError("conflict", `The ${tool} tool name is reserved by Tron`);
    }
    if (owners.length > 1) throw new GatewayError("conflict", `The first-party ${tool} tool was registered more than once`);
  }
  for (const extension of base.extensions) {
    for (const [event, handlers] of extension.handlers) {
      extension.handlers.set(event, handlers.map((handler) => owned(adaptedExtensionEventHandler(extension, handler), extension)));
    }
    for (const [name, registered] of extension.tools) {
      const definition = adaptedToolDefinition(extension, name, registered.definition);
      const execute = owned(async (...args: Parameters<ToolDefinition["execute"]>) => {
        const result = await definition.execute(...args);
        if (!browserLiveView) return result;
        return observeTrustedAgentBrowserResult({
          // The SDK finalizes public package provenance after extensionsOverride.
          // Read it at execution, never authorize from the provisional owner.
          owner: extensionOwnerFor(extension),
          toolName: name,
          toolCallId: args[0],
          result,
          sessionId: browserLiveView.sessionId,
          runtimeGeneration: browserLiveView.runtimeGeneration,
          loadToken: loadToken!,
          views: browserLiveView.views,
        }) as Awaited<ReturnType<ToolDefinition["execute"]>>;
      }, extension);
      attributedToolOwners.set(execute, extension);
      extension.tools.set(name, {
        ...registered,
        definition: {
          ...definition,
          execute,
          ...(definition.prepareArguments ? { prepareArguments: owned(definition.prepareArguments, extension) } : {}),
          ...(definition.renderCall ? { renderCall: owned(definition.renderCall, extension) } : {}),
          ...(definition.renderResult ? { renderResult: owned(definition.renderResult, extension) } : {}),
        } as ToolDefinition,
      } as RegisteredTool);
    }
    for (const [name, command] of extension.commands) {
      const handler = owned(command.handler, extension);
      attributedCommandOwners.set(handler, extension);
      extension.commands.set(name, { ...command, handler } as RegisteredCommand);
    }
    for (const [name, shortcut] of extension.shortcuts) {
      extension.shortcuts.set(name, { ...shortcut, handler: owned(shortcut.handler, extension) });
    }
    for (const [name, renderer] of extension.messageRenderers) extension.messageRenderers.set(name, owned(renderer, extension));
    for (const [name, renderer] of extension.entryRenderers ?? []) extension.entryRenderers!.set(name, owned(renderer, extension));
    if (extension.markdownTransformer) extension.markdownTransformer = owned(extension.markdownTransformer, extension);
  }
  return base;
}
