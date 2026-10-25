import { createHash } from "node:crypto";
import { withExtensionOwner } from "./extension-execution-context.js";
import type { EntryRenderer, Extension, LoadExtensionsResult, MarkdownTransformer, MessageRenderer, RegisteredCommand, RegisteredTool, ToolDefinition } from "../pi/coding-agent.js";
import { adaptedExtensionEventHandler, adaptedToolDefinition, adaptMcpAuthCommandHandler } from "./extension-adapters.js";
import type { ExtensionOwner } from "../../protocol/types.js";
import type { BrowserResultObservation } from "../projection/tool-result.js";

/** The managed producer supplies its actual load admission, not a mirrored provider. */
export interface ManagedExtensionAdmission { admit(extensions: readonly Extension[]): void }

/** Runtime product policy is supplied by the module, including its reserved capabilities. */
export type ExtensionAdmission = (base: LoadExtensionsResult, browserLiveView?: BrowserResultObservation,
  managed?: ManagedExtensionAdmission) => LoadExtensionsResult;

type ExtensionHandlerList = Parameters<Extension["handlers"]["set"]>[1];
/** Pi keys shortcuts by its `KeyId` union, not an arbitrary string. */
type ExtensionShortcutKey = Parameters<Extension["shortcuts"]["set"]>[0];
type ExtensionShortcut = Parameters<Extension["shortcuts"]["set"]>[1];

const attributedCommandOwners = new WeakMap<RegisteredCommand["handler"], () => ExtensionOwner>();
const builtinMcpCommandHandlers = new WeakSet<RegisteredCommand["handler"]>();
const attributedToolOwners = new WeakMap<ToolDefinition["execute"], () => ExtensionOwner>();
/** Every callback admitted at this boundary, keyed by its owning extension, so
 * repeat registration of the same function by one extension cannot double-wrap
 * it while a different extension still receives its own correctly attributed
 * wrapper. */
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

/**
 * Wraps one callback in its owning extension context. The owner is
 * resolved at invocation time, not admission time: the pinned SDK finalizes
 * package `SourceInfo` after `extensionsOverride` returns. Admission is
 * idempotent per extension, so re-setting an already-admitted handler list
 * keeps one wrapper while a different extension sharing the same function
 * object still gets its own attributed wrapper.
 */
function ownCallback<T extends (...args: any[]) => any>(callback: T, state: RegistrationAdmission): T {
  if (admittedCallbackOwners.get(callback) === state.extension) return callback;
  const wrapper = ((...args: Parameters<T>) => withExtensionOwner(state.owner(), () => callback(...args))) as T;
  admittedCallbackOwners.set(wrapper, state.extension);
  return wrapper;
}

/** One live extension reference; policy and owner are resolved by its actual supplier. */
interface RegistrationAdmission {
  extension: Extension;
  owner: () => ExtensionOwner;
  assertToolName: (name: string) => void;
  browserLiveView?: BrowserResultObservation;
}

/**
 * The single registration admission boundary.
 *
 * Pi permits an already-loaded extension to register tools, commands,
 * handlers, shortcuts, and renderers at any time, not only during load. A
 * one-shot pass over the loader result therefore cannot own attribution or
 * reserved-name policy: a later `registerTool` would replace the admitted entry
 * with an unwrapped definition, losing producer identity and bypassing the
 * first-party name checks. Making the registration maps themselves the
 * admission boundary means load-time and late registration share exactly one
 * policy path, with no polling or post-hoc repair pass.
 */
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
  // A tool that already carries this extension's host wrapper is admitted;
  // re-setting it (for example during a normalizing pass) must not wrap it a
  // second time.
  if (admittedCallbackOwners.get(registered.definition.execute) === state.extension) return registered;
  state.assertToolName(name);
  const definition = adaptedToolDefinition(state.extension, name, registered.definition);
  const execute = ownCallback(async (...args: Parameters<ToolDefinition["execute"]>) => {
    const result = await definition.execute(...args);
    if (!state.browserLiveView) return result;
    return state.browserLiveView.observeResult({
      // The SDK finalizes public package provenance after extensionsOverride.
      // Read it at execution, never authorize from the provisional owner.
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
  // `on()` re-sets the whole list each time, so already-admitted handlers must
  // keep their existing wrapper identity instead of being adapted twice.
  return handlers.map((handler) => admittedCallbackOwners.get(handler) === state.extension
    ? handler
    : ownCallback(adaptedExtensionEventHandler(state.extension, handler), state));
}

function admitCommand(state: RegistrationAdmission, name: string, command: RegisteredCommand): RegisteredCommand {
  if (admittedCallbackOwners.get(command.handler) === state.extension) return command;
  // Pi separates a synthetic built-in's source (`builtin`) from its path (`builtin:mcp`).
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

function admitMarkdownTransformer(state: RegistrationAdmission, transformer: MarkdownTransformer): MarkdownTransformer {
  return ownCallback(transformer, state);
}

/**
 * Installs the admission boundary on one loaded extension. Registered entries
 * are admitted through the same functions that later registrations use, so a
 * reload (which yields fresh extension objects) re-establishes exactly one
 * wrapper per callback.
 */
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
