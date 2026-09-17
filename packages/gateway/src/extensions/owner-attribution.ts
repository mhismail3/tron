import { AsyncLocalStorage } from "node:async_hooks";
import { createHash } from "node:crypto";
import { basename, extname } from "node:path";
import type {
  EntryRenderer,
  Extension,
  LoadExtensionsResult,
  MarkdownTransformer,
  MessageRenderer,
  RegisteredCommand,
  RegisteredTool,
  ToolDefinition,
} from "@earendil-works/pi-coding-agent";
import { adaptedExtensionEventHandler, adaptedToolDefinition, AUDITED_ASK_USER_PACKAGE } from "./extension-adapters.js";
import type { ExtensionOwner } from "../protocol/types.js";
import { GatewayError } from "../errors.js";
import type { BrowserLiveViewRegistry } from "../display/browser-live-view.js";
import { observeTrustedAgentBrowserResult } from "../display/browser-live-view-adapter.js";
import { TRON_ASK_USER_INLINE_PATH, TRON_ASK_USER_SOURCE } from "./tron-ask-user-contract.js";

type ExtensionHandlerList = Parameters<Extension["handlers"]["set"]>[1];
/** Pi keys shortcuts by its `KeyId` union, not an arbitrary string. */
type ExtensionShortcutKey = Parameters<Extension["shortcuts"]["set"]>[0];
type ExtensionShortcut = Parameters<Extension["shortcuts"]["set"]>[1];

/** The owner is intentionally opaque to extension code and is only readable by
 * the gateway presentation projection. AsyncLocalStorage preserves it across
 * promises and timers without guessing attribution for unattributed calls. */
const ownerStorage = new AsyncLocalStorage<ExtensionOwner>();
// Adapter classification is established once at the trusted extension-load
// boundary; transcript code never guesses from customType, text, or renderer
// registration.
const trustedSubagentOwnerIDs = new Set<string>();
const trustedSubagentAdapterSource = "npm:pi-subagents";
/** First-party inline tool names and the exact inline extension that may own them. */
const RESERVED_FIRST_PARTY_TOOLS: ReadonlyArray<readonly [string, string]> = [
  ["notify", "tron-notify"],
  ["display", "tron-display"],
  ["native_capture", "tron-native-capture"],
  ["computer", "tron-computer"],
];
export interface InvocationExecutionContext {
  invocationId: string;
  operationId: string;
}
const invocationStorage = new AsyncLocalStorage<InvocationExecutionContext>();
const attributedCommandOwners = new WeakMap<RegisteredCommand["handler"], Extension>();
const attributedToolOwners = new WeakMap<ToolDefinition["execute"], Extension>();
/** Every callback admitted at this boundary, keyed by its owning extension, so
 * repeat registration of the same function by one extension cannot double-wrap
 * it while a different extension still receives its own correctly attributed
 * wrapper. */
const admittedCallbackOwners = new WeakMap<Function, Extension>();

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

/**
 * Names that identify a container rather than the extension itself. Every
 * project extension lives in `.pi/extensions/`, and packages commonly expose
 * `index.ts`, so deriving a user-visible title from a container name makes
 * unrelated extensions share one label ("Pi") and collapses them into one
 * producer group in native presentation.
 */
const GENERIC_EXTENSION_NAMES: ReadonlySet<string> = new Set([
  "index", "main", "mod", "entry", "extension", "extensions", "bundle",
  ".pi", "pi", "dist", "src", "lib", "libs", "build", "out", "node_modules",
]);

function titleFromName(value: string): string | undefined {
  const words = value.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  if (words.length === 0) return undefined;
  return words.map((word) => word[0]!.toUpperCase() + word.slice(1)).join(" ");
}

function baseNameWithoutExtension(value: string | undefined): string | undefined {
  if (!value) return undefined;
  const name = basename(value);
  const extension = extname(name);
  return extension ? name.slice(0, -extension.length) : name;
}

/**
 * The human-readable producer title for one extension, resolved in a fixed
 * precedence that never accepts a container name: the entry file, then its
 * immediate directory, then the installed package name. A project extension in
 * the standard `.pi/extensions/` layout is therefore named by its own file, and
 * a package whose entry sits in a generic directory falls back to its package
 * name instead of colliding with every other such package.
 */
function humanizedDisplayName(extension: Extension): string {
  // Pi's inline extensions carry a generated `<kind:name>` path with no directory.
  const inline = [extension.path, extension.resolvedPath, extension.sourceInfo.path]
    .find((value) => typeof value === "string" && value.startsWith("<") && value.endsWith(">"));
  if (inline) {
    const inner = inline.slice(1, -1);
    return titleFromName(inner.slice(inner.indexOf(":") + 1) || inner) ?? "Extension";
  }
  for (const name of [baseNameWithoutExtension(extension.resolvedPath), baseNameWithoutExtension(extension.sourceInfo.baseDir)]) {
    if (name && !GENERIC_EXTENSION_NAMES.has(name.toLowerCase())) {
      const title = titleFromName(name);
      if (title) return title;
    }
  }
  const npmPackage = /^npm:(?:@[^/]+\/)?(.+)$/u.exec(extension.sourceInfo.source ?? "")?.[1];
  return (npmPackage ? titleFromName(npmPackage) : undefined) ?? "Extension";
}

export function extensionOwnerFor(extension: Extension): ExtensionOwner {
  // Inline source labels are loader defaults; this exact generated path is the
  // stable release-owned capability identity used by native projections.
  const source = extension.path === TRON_ASK_USER_INLINE_PATH
    ? TRON_ASK_USER_SOURCE
    : extension.sourceInfo.source;
  const identity = `${source}\0${extension.resolvedPath}`;
  const id = `extension:${createHash("sha256").update(identity).digest("base64url")}`;
  if (source === trustedSubagentAdapterSource) trustedSubagentOwnerIDs.add(id);
  return { id, title: humanizedDisplayName(extension), source };
}

export function trustedExtensionOriginKind(owner: ExtensionOwner): "subagent" | "extension" {
  return trustedSubagentOwnerIDs.has(owner.id) ? "subagent" : "extension";
}

/**
 * Wraps one callback in its owning extension context. `extensionOwnerFor` is
 * resolved at invocation time, not admission time: the pinned SDK finalizes
 * package `SourceInfo` after `extensionsOverride` returns. Admission is
 * idempotent per extension, so re-setting an already-admitted handler list
 * keeps one wrapper while a different extension sharing the same function
 * object still gets its own attributed wrapper.
 */
function ownCallback<T extends (...args: any[]) => any>(callback: T, extension: Extension): T {
  if (admittedCallbackOwners.get(callback) === extension) return callback;
  const wrapper = ((...args: Parameters<T>) => ownerStorage.run(extensionOwnerFor(extension), () => callback(...args))) as T;
  admittedCallbackOwners.set(wrapper, extension);
  return wrapper;
}

/**
 * Per-extension registration policy. Created once per load so late
 * registrations enforce the same rules as the entries present at load time.
 */
interface RegistrationAdmission {
  extension: Extension;
  requireTronAskUser: boolean;
  browserLiveView?: {
    views: BrowserLiveViewRegistry;
    sessionId: string;
    runtimeGeneration: string;
    loadToken: string;
  };
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

function assertAdmissibleToolName(state: RegistrationAdmission, name: string): void {
  if (name === "bash") throw new GatewayError("conflict", "The bash tool name is reserved by Tron");
  for (const [tool, owner] of RESERVED_FIRST_PARTY_TOOLS) {
    if (name !== tool) continue;
    if (state.extension.path !== `<inline:${owner}>`) {
      throw new GatewayError("conflict", `The ${tool} tool name is reserved by Tron`);
    }
    return;
  }
  if (name !== "ask_user" || !state.requireTronAskUser || state.extension.path === TRON_ASK_USER_INLINE_PATH) return;
  if (state.extension.sourceInfo.source === AUDITED_ASK_USER_PACKAGE.source) {
    throw new GatewayError("conflict", `The configured ${AUDITED_ASK_USER_PACKAGE.source} extension conflicts with Tron's ask_user capability; disable only that extension in the destination Pi settings and retry`);
  }
  throw new GatewayError("conflict", "The ask_user tool name is reserved by Tron");
}

function admitTool(state: RegistrationAdmission, name: string, registered: RegisteredTool): RegisteredTool {
  // A tool that already carries this extension's host wrapper is admitted;
  // re-setting it (for example during a normalizing pass) must not wrap it a
  // second time.
  if (admittedCallbackOwners.get(registered.definition.execute) === state.extension) return registered;
  assertAdmissibleToolName(state, name);
  const definition = adaptedToolDefinition(state.extension, name, registered.definition);
  const execute = ownCallback(async (...args: Parameters<ToolDefinition["execute"]>) => {
    const result = await definition.execute(...args);
    if (!state.browserLiveView) return result;
    return observeTrustedAgentBrowserResult({
      // The SDK finalizes public package provenance after extensionsOverride.
      // Read it at execution, never authorize from the provisional owner.
      owner: extensionOwnerFor(state.extension),
      toolName: name,
      toolCallId: args[0],
      result,
      sessionId: state.browserLiveView.sessionId,
      runtimeGeneration: state.browserLiveView.runtimeGeneration,
      loadToken: state.browserLiveView.loadToken,
      views: state.browserLiveView.views,
    }) as Awaited<ReturnType<ToolDefinition["execute"]>>;
  }, state.extension);
  attributedToolOwners.set(execute, state.extension);
  return {
    ...registered,
    definition: {
      ...definition,
      execute,
      ...(definition.prepareArguments ? { prepareArguments: ownCallback(definition.prepareArguments, state.extension) } : {}),
      ...(definition.renderCall ? { renderCall: ownCallback(definition.renderCall, state.extension) } : {}),
      ...(definition.renderResult ? { renderResult: ownCallback(definition.renderResult, state.extension) } : {}),
    } as ToolDefinition,
  } as RegisteredTool;
}

function admitHandlers(state: RegistrationAdmission, _event: string, handlers: ExtensionHandlerList): ExtensionHandlerList {
  // `on()` re-sets the whole list each time, so already-admitted handlers must
  // keep their existing wrapper identity instead of being adapted twice.
  return handlers.map((handler) => admittedCallbackOwners.get(handler) === state.extension
    ? handler
    : ownCallback(adaptedExtensionEventHandler(state.extension, handler), state.extension));
}

function admitCommand(state: RegistrationAdmission, _name: string, command: RegisteredCommand): RegisteredCommand {
  if (admittedCallbackOwners.get(command.handler) === state.extension) return command;
  const handler = ownCallback(command.handler, state.extension);
  attributedCommandOwners.set(handler, state.extension);
  return { ...command, handler };
}

function admitShortcut(state: RegistrationAdmission, _key: ExtensionShortcutKey, shortcut: ExtensionShortcut): ExtensionShortcut {
  if (admittedCallbackOwners.get(shortcut.handler) === state.extension) return shortcut;
  return { ...shortcut, handler: ownCallback(shortcut.handler, state.extension) };
}

function admitRenderer<T extends MessageRenderer | EntryRenderer>(state: RegistrationAdmission, renderer: T): T {
  return ownCallback(renderer, state.extension);
}

function admitMarkdownTransformer(state: RegistrationAdmission, transformer: MarkdownTransformer): MarkdownTransformer {
  return ownCallback(transformer, state.extension);
}

/**
 * Installs the admission boundary on one loaded extension. Registered entries
 * are admitted through the same functions that later registrations use, so a
 * reload (which yields fresh extension objects) re-establishes exactly one
 * wrapper per callback.
 */
function installRegistrationAdmission(extension: Extension, admission: Omit<RegistrationAdmission, "extension">): void {
  const state: RegistrationAdmission = { extension, ...admission };
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

/**
 * Validates reserved capabilities and first-party ownership across the whole
 * loaded set before any admission boundary is installed, so a conflicting load
 * fails closed without leaving a partially admitted extension behind.
 */
function validateReservedCapabilities(base: LoadExtensionsResult, options?: { requireTronAskUser?: boolean }): void {
  if (base.extensions.some((extension) => extension.tools.has("bash"))) {
    throw new GatewayError("conflict", "The bash tool name is reserved by Tron");
  }
  for (const [tool, owner] of RESERVED_FIRST_PARTY_TOOLS) {
    const owners = base.extensions.filter((extension) => extension.tools.has(tool));
    if (owners.some((extension) => extension.path !== `<inline:${owner}>`)) {
      throw new GatewayError("conflict", `The ${tool} tool name is reserved by Tron`);
    }
    if (owners.length > 1) throw new GatewayError("conflict", `The first-party ${tool} tool was registered more than once`);
  }
  if (!options?.requireTronAskUser) return;
  const firstParty = base.extensions.filter((extension) => extension.path === TRON_ASK_USER_INLINE_PATH);
  if (firstParty.length !== 1 || !firstParty[0]!.tools.has("ask_user")) {
    throw new GatewayError("conflict", "The first-party ask_user capability failed to load");
  }
  const owners = base.extensions.filter((extension) => extension.tools.has("ask_user"));
  const superseded = owners.find((extension) => extension.sourceInfo.source === AUDITED_ASK_USER_PACKAGE.source);
  if (superseded) {
    throw new GatewayError("conflict", `The configured ${AUDITED_ASK_USER_PACKAGE.source} extension conflicts with Tron's ask_user capability; disable only that extension in the destination Pi settings and retry`);
  }
  if (owners.some((extension) => extension.path !== TRON_ASK_USER_INLINE_PATH)) {
    throw new GatewayError("conflict", "The ask_user tool name is reserved by Tron");
  }
  if (owners.length > 1) throw new GatewayError("conflict", "The first-party ask_user tool was registered more than once");
}

/** Wraps every callback registered by one loaded extension, including
 * registrations performed later through the same API. The result is safe to
 * apply on every resource reload because each load result is admitted once and
 * all maps/functions are retained as public Pi objects. */
export function attributeExtensions(base: LoadExtensionsResult, browserLiveView?: {
  views: BrowserLiveViewRegistry;
  sessionId: string;
  runtimeGeneration: string;
}, options?: { requireTronAskUser?: boolean }): LoadExtensionsResult {
  const loadToken = browserLiveView?.views.beginSessionLoad(browserLiveView.sessionId);
  validateReservedCapabilities(base, options);
  const admission: Omit<RegistrationAdmission, "extension"> = {
    requireTronAskUser: options?.requireTronAskUser === true,
    ...(browserLiveView && loadToken ? { browserLiveView: { ...browserLiveView, loadToken } } : {}),
  };
  for (const extension of base.extensions) installRegistrationAdmission(extension, admission);
  return base;
}
