import { AsyncLocalStorage } from "node:async_hooks";
import { basename, extname } from "node:path";
import type { Extension, LoadExtensionsResult, RegisteredCommand, RegisteredTool, ToolDefinition } from "@earendil-works/pi-coding-agent";
import type { ExtensionOwner } from "../protocol/types.js";

/** The owner is intentionally opaque to extension code and is only readable by
 * the gateway presentation projection. AsyncLocalStorage preserves it across
 * promises and timers without guessing attribution for unattributed calls. */
const ownerStorage = new AsyncLocalStorage<ExtensionOwner>();

export function currentExtensionOwner(): ExtensionOwner | undefined { return ownerStorage.getStore(); }

function humanizedDisplayName(extension: Extension): string {
  const sourcePath = extension.sourceInfo.baseDir || extension.sourceInfo.path || extension.resolvedPath || extension.path;
  const directory = basename(sourcePath);
  const candidate = extname(directory) ? directory.slice(0, -extname(directory).length) : directory;
  const words = candidate.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  return words.length === 0 ? "Extension" : words.map((word) => word[0]!.toUpperCase() + word.slice(1)).join(" ");
}

function ownerFor(extension: Extension): ExtensionOwner {
  return { id: extension.resolvedPath, title: humanizedDisplayName(extension), source: extension.sourceInfo.source };
}

function owned<T extends (...args: any[]) => any>(fn: T, owner: ExtensionOwner): T {
  return ((...args: Parameters<T>) => ownerStorage.run(owner, () => fn(...args))) as T;
}

/** Wrap every callback registered by one loaded extension. The result is safe
 * to apply on every resource reload because each load result is wrapped once
 * and all maps/functions are retained as public Pi objects. */
export function attributeExtensions(base: LoadExtensionsResult): LoadExtensionsResult {
  for (const extension of base.extensions) {
    const owner = ownerFor(extension);
    for (const [event, handlers] of extension.handlers) {
      extension.handlers.set(event, handlers.map((handler) => owned(handler, owner)));
    }
    for (const [name, registered] of extension.tools) {
      const definition = registered.definition;
      extension.tools.set(name, {
        ...registered,
        definition: {
          ...definition,
          execute: owned(definition.execute, owner),
          ...(definition.prepareArguments ? { prepareArguments: owned(definition.prepareArguments, owner) } : {}),
          ...(definition.renderCall ? { renderCall: owned(definition.renderCall, owner) } : {}),
          ...(definition.renderResult ? { renderResult: owned(definition.renderResult, owner) } : {}),
        } as ToolDefinition,
      } as RegisteredTool);
    }
    for (const [name, command] of extension.commands) {
      extension.commands.set(name, { ...command, handler: owned(command.handler, owner) } as RegisteredCommand);
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
