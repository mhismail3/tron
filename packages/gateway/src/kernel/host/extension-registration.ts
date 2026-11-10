import { createHash } from "node:crypto";
import { withExtensionOwner } from "./extension-execution-context.js";
import type { EntryRenderer, Extension, LoadExtensionsResult, MarkdownTransformerRegistration, MessageRenderer, RegisteredCommand, RegisteredTool, ToolDefinition } from "../pi/coding-agent.js";
import { adaptedExtensionEventHandler, adaptedToolDefinition, adaptMcpAuthCommandHandler } from "./extension-adapters.js";
import type { ExtensionOwner } from "../../protocol/types.js";
import type { BrowserResultObservation } from "../projection/tool-result.js";

export interface ManagedExtensionAdmission { admit(extensions: readonly Extension[]): void }

export type ExtensionAdmission = (base: LoadExtensionsResult, browserLiveView?: BrowserResultObservation,
  managed?: ManagedExtensionAdmission) => LoadExtensionsResult;

type ExtensionHandlerList = Parameters<Extension["handlers"]["set"]>[1];
type ExtensionShortcutKey = Parameters<Extension["shortcuts"]["set"]>[0];
type ExtensionShortcut = Parameters<Extension["shortcuts"]["set"]>[1];

const attributedCommandOwners = new WeakMap<RegisteredCommand["handler"], () => ExtensionOwner>();
const builtinMcpCommandHandlers = new WeakSet<RegisteredCommand["handler"]>();
const attributedToolOwners = new WeakMap<ToolDefinition["execute"], () => ExtensionOwner>();
const admittedCallbackOwners = new WeakMap<Function, Extension>();

export function isBuiltinMcpCommand(command: RegisteredCommand | undefined): boolean {
  return command !== undefined && builtinMcpCommandHandlers.has(command.handler);
}
export function attributedCommandOwner(command: RegisteredCommand | undefined): ExtensionOwner | undefined {
  const owner = command ? attributedCommandOwners.get(command.handler) : undefined;
  return owner?.();
}
export function attributedToolOwner(tool: RegisteredTool | undefined): ExtensionOwner | undefined {
  const owner = tool ? attributedToolOwners.get(tool.definition.execute) : undefined;
  return owner?.();
}

export function producerIdentity(source: string, path: string, title: string, kind: NonNullable<ExtensionOwner["kind"]>): ExtensionOwner {
  const id = `extension:${createHash("sha256").update(`${source}\0${path}`).digest("base64url")}`;
  return { id, title, source, kind };
}

function ownCallback<T extends (...args: any[]) => any>(callback: T, state: RegistrationAdmission): T {
  if (admittedCallbackOwners.get(callback) === state.extension) return callback;
  const wrapper = ((...args: Parameters<T>) => withExtensionOwner(state.owner(), () => callback(...args))) as T;
  admittedCallbackOwners.set(wrapper, state.extension);
  return wrapper;
}

interface RegistrationAdmission {
  extension: Extension;
  owner: () => ExtensionOwner;
  assertToolName: (name: string) => void;
  browserLiveView?: BrowserResultObservation;
}

class RegistrationMap<K, V> extends Map<K, V> {
  constructor(
    private readonly admit: (key: K, value: V) => V,
    entries?: Iterable<readonly [K, V]>,
  ) {
    super();
    if (entries) for (const [key, value] of entries) this.set(key, value);
  }
  override set(key: K, value: V): this {
    return super.set(key, this.admit(key, value));
  }
}

function admitTool(state: RegistrationAdmission, name: string, registered: RegisteredTool): RegisteredTool {
  if (admittedCallbackOwners.get(registered.definition.execute) === state.extension) return registered;
  state.assertToolName(name);
  const definition = adaptedToolDefinition(state.extension, name, registered.definition);
  const execute = ownCallback(async (...args: Parameters<ToolDefinition["execute"]>) => {
    const result = await definition.execute(...args);
    if (!state.browserLiveView) return result;
    return state.browserLiveView.observeResult({
      owner: state.owner(),
      toolName: name,
      toolCallId: args[0],
      result,
      sessionId: state.browserLiveView.sessionId,
      runtimeGeneration: state.browserLiveView.runtimeGeneration,
      loadToken: state.browserLiveView.loadToken,
    }) as Awaited<ReturnType<ToolDefinition["execute"]>>;
  }, state);
  attributedToolOwners.set(execute, state.owner);
  return {
    ...registered,
    definition: {
      ...definition,
      execute,
      ...(definition.prepareArguments ? { prepareArguments: ownCallback(definition.prepareArguments, state) } : {}),
      ...(definition.prepareLoadout ? { prepareLoadout: ownCallback(definition.prepareLoadout, state) } : {}),
      ...(definition.renderCall ? { renderCall: ownCallback(definition.renderCall, state) } : {}),
      ...(definition.renderResult ? { renderResult: ownCallback(definition.renderResult, state) } : {}),
    } as ToolDefinition,
  } as RegisteredTool;
}

function admitHandlers(state: RegistrationAdmission, _event: string, handlers: ExtensionHandlerList): ExtensionHandlerList {
  return handlers.map((handler) => admittedCallbackOwners.get(handler) === state.extension
    ? handler
    : ownCallback(adaptedExtensionEventHandler(state.extension, handler), state));
}

function admitCommand(state: RegistrationAdmission, name: string, command: RegisteredCommand): RegisteredCommand {
  if (admittedCallbackOwners.get(command.handler) === state.extension) return command;
  const callback = state.extension.sourceInfo.path === "builtin:mcp" && name === "mcp"
    ? adaptMcpAuthCommandHandler(command.handler)
    : command.handler;
  const handler = ownCallback(callback, state);
  attributedCommandOwners.set(handler, state.owner);
  if (state.extension.sourceInfo.path === "builtin:mcp" && name === "mcp") builtinMcpCommandHandlers.add(handler);
  return { ...command, handler };
}



function admitShortcut(state: RegistrationAdmission, _key: ExtensionShortcutKey, shortcut: ExtensionShortcut): ExtensionShortcut {
  if (admittedCallbackOwners.get(shortcut.handler) === state.extension) return shortcut;
  return { ...shortcut, handler: ownCallback(shortcut.handler, state) };
}

function admitRenderer<T extends MessageRenderer | EntryRenderer>(state: RegistrationAdmission, renderer: T): T {
  return ownCallback(renderer, state);
}

function admitMarkdownTransformer(state: RegistrationAdmission, registration: MarkdownTransformerRegistration): MarkdownTransformerRegistration {
  return { ...registration, transformer: ownCallback(registration.transformer, state) };
}

export function installExtensionRegistration(extension: Extension, owner: () => ExtensionOwner,
  assertToolName: (name: string) => void, browserLiveView?: BrowserResultObservation): void {
  const state: RegistrationAdmission = { extension, owner, assertToolName, ...(browserLiveView ? { browserLiveView } : {}) };
  extension.handlers = new RegistrationMap<string, ExtensionHandlerList>(
    (event, handlers) => admitHandlers(state, event, handlers), extension.handlers);
  extension.tools = new RegistrationMap<string, RegisteredTool>(
    (name, registered) => admitTool(state, name, registered), extension.tools);
  extension.commands = new RegistrationMap<string, RegisteredCommand>(
    (name, command) => admitCommand(state, name, command), extension.commands);
  extension.shortcuts = new RegistrationMap<ExtensionShortcutKey, ExtensionShortcut>(
    (key, shortcut) => admitShortcut(state, key, shortcut), extension.shortcuts);
  extension.messageRenderers = new RegistrationMap<string, MessageRenderer>(
    (type, renderer) => admitRenderer(state, renderer), extension.messageRenderers);
  extension.entryRenderers = new RegistrationMap<string, EntryRenderer>(
    (type, renderer) => admitRenderer(state, renderer), extension.entryRenderers ?? new Map());
  if (extension.markdownTransformer) extension.markdownTransformer = admitMarkdownTransformer(state, extension.markdownTransformer);
}
