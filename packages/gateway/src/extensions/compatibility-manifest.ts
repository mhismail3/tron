import { PI_VERSION } from "../version.js";
import type {
  EntryRenderOptions,
  ExtensionAPI,
  ExtensionCommandContext,
  ExtensionContext,
  ExtensionEvent,
  ExtensionUIContext,
  MarkdownTransformContext,
  MessageRenderOptions,
  ToolDefinition,
  ToolRenderResultOptions,
} from "@earendil-works/pi-coding-agent";

export { PI_VERSION };
export const PINNED_PI_VERSION = PI_VERSION;
export const EXTENSION_PRESENTATION_VERSION = 3 as const;

export type HostClassification = "native-semantic" | "remote-component" | "renderer" | "pi-runtime" | "explicit-fallback";
export interface CompatibilityEntry {
  classification: HostClassification;
  capability: string;
  limitation?: string;
}
const entry = (classification: HostClassification, capability: string, limitation?: string): CompatibilityEntry => ({
  classification, capability, ...(limitation ? { limitation } : {}),
});

export const extensionToolAdapterCompatibility = {
  tronDisplay: entry("native-semantic", "display-artifacts.v1", "Reserved first-party tool; durable project artifacts use typed sheet, inline, or floating native presentation, while public URLs remain gesture-gated."),
  tronBrowserLive: entry("native-semantic", "browser-live-view.v1", "Disposable read-only observation of an exact provider browser generation; only active native sheet/floating viewers hold capture leases. No browser launch, control relay, or durable frame storage."),
  zhushanwenAskUserForm: entry("native-semantic", "form.v1", "Exact npm:@zhushanwen/pi-ask-user@7.0.15 marker contract; one bounded atomic form with no primitive fallback."),
} as const;

export const extensionPresentationCompatibility = {
  select: entry("native-semantic", "dialogs.select"), confirm: entry("native-semantic", "dialogs.confirm"),
  input: entry("native-semantic", "dialogs.input"), editor: entry("native-semantic", "dialogs.editor"),
  notify: entry("native-semantic", "notifications"), setStatus: entry("native-semantic", "status"),
  setWorkingMessage: entry("native-semantic", "working.message"), setWorkingVisible: entry("native-semantic", "working.visible"),
  setWorkingIndicator: entry("native-semantic", "working.indicator"), setHiddenThinkingLabel: entry("native-semantic", "thinking.hidden-label"),
  setWidget: entry("native-semantic", "widgets.string", "String widgets remain semantic; component-valued retained widgets are projected as bounded read-only generic surfaces."),
  setTitle: entry("native-semantic", "title"), pasteToEditor: entry("native-semantic", "editor.revisioned"),
  setEditorText: entry("native-semantic", "editor.revisioned"), getEditorText: entry("native-semantic", "editor.revisioned"),
  getToolsExpanded: entry("native-semantic", "tools.expanded"), setToolsExpanded: entry("native-semantic", "tools.expanded"),
  onTerminalInput: entry("remote-component", "terminal.input", "The bounded in-memory input seam is proven; production routing remains unavailable while the binding is RPC."),
  setFooter: entry("remote-component", "components.footer", "Public component composition is proven; production slot mounting awaits Phase 4D."), setHeader: entry("remote-component", "components.header", "Public component composition is proven; production slot mounting awaits Phase 4D."),
  custom: entry("remote-component", "components.custom", "Foundation-only: one exclusive non-overlay custom owner is bounded in the dormant harness; overlay UX, input routing, and production activation are deferred."),
  addAutocompleteProvider: entry("remote-component", "editor.autocomplete", "Phase 4."),
  setEditorComponent: entry("remote-component", "editor.component", "Phase 4."), getEditorComponent: entry("remote-component", "editor.component", "Phase 4."),
  theme: entry("explicit-fallback", "theme.baseline", "Pinned Pi has no public per-session process-global theme injection seam."),
  getAllThemes: entry("remote-component", "theme.registry", "Phase 4."), getTheme: entry("remote-component", "theme.registry", "Phase 4."),
  setTheme: entry("remote-component", "theme.switch", "Phase 4."),
} satisfies Record<keyof ExtensionUIContext, CompatibilityEntry>;

export const extensionEventCompatibility = {
  project_trust: entry("pi-runtime", "event.project-trust"), resources_discover: entry("pi-runtime", "event.resources-discover"),
  session_start: entry("pi-runtime", "event.session-start"), session_info_changed: entry("pi-runtime", "event.session-info"),
  session_before_switch: entry("pi-runtime", "event.session-before-switch"), session_before_fork: entry("pi-runtime", "event.session-before-fork"),
  session_before_compact: entry("pi-runtime", "event.session-before-compact"), session_compact: entry("pi-runtime", "event.session-compact"),
  session_compact_failed: entry("pi-runtime", "event.session-compact-failed"),
  session_shutdown: entry("pi-runtime", "event.session-shutdown"), session_before_tree: entry("pi-runtime", "event.session-before-tree"),
  session_tree: entry("pi-runtime", "event.session-tree"), context: entry("pi-runtime", "event.context"), context_with_system: entry("pi-runtime", "event.context-with-system"),
  cache_warming_decision: entry("pi-runtime", "event.cache-warming-decision"), agent_before_settle: entry("pi-runtime", "event.agent-before-settle"),
  before_provider_request: entry("pi-runtime", "event.provider-request"), before_provider_headers: entry("pi-runtime", "event.provider-headers"),
  after_provider_response: entry("pi-runtime", "event.provider-response"), before_agent_start: entry("pi-runtime", "event.before-agent-start"),
  agent_start: entry("pi-runtime", "event.agent-start"), agent_end: entry("pi-runtime", "event.agent-end"), agent_settled: entry("pi-runtime", "event.agent-settled"),
  ui_prompt_start: entry("pi-runtime", "event.ui-prompt-start"), ui_prompt_end: entry("pi-runtime", "event.ui-prompt-end"),
  turn_start: entry("pi-runtime", "event.turn-start"), turn_end: entry("pi-runtime", "event.turn-end"),
  message_start: entry("pi-runtime", "event.message-start"), message_update: entry("pi-runtime", "event.message-update"), message_end: entry("pi-runtime", "event.message-end"),
  tool_execution_start: entry("pi-runtime", "event.tool-start"), tool_execution_update: entry("pi-runtime", "event.tool-update"), tool_execution_end: entry("pi-runtime", "event.tool-end"),
  model_select: entry("pi-runtime", "event.model-select"), thinking_level_select: entry("pi-runtime", "event.thinking-select"),
  user_bash: entry("pi-runtime", "event.user-bash"), input: entry("pi-runtime", "event.input"), tool_call: entry("pi-runtime", "event.tool-call"), tool_result: entry("pi-runtime", "event.tool-result"),
} satisfies Record<ExtensionEvent["type"], CompatibilityEntry>;

export const extensionContextCompatibility = {
  ui: entry("native-semantic", "context.ui"), mode: entry("pi-runtime", "context.mode"), hasUI: entry("pi-runtime", "context.has-ui"), cwd: entry("pi-runtime", "context.cwd"),
  sessionManager: entry("pi-runtime", "context.session-manager"), modelRegistry: entry("pi-runtime", "context.model-registry"), model: entry("pi-runtime", "context.model"),
  scopedModels: entry("pi-runtime", "context.scoped-models"), thinkingLevel: entry("pi-runtime", "context.thinking-level"), isIdle: entry("pi-runtime", "context.idle"),
  isProjectTrusted: entry("pi-runtime", "context.trust"), signal: entry("pi-runtime", "context.signal"), abort: entry("pi-runtime", "context.abort"),
  hasPendingMessages: entry("pi-runtime", "context.queue"), shutdown: entry("pi-runtime", "context.session-shutdown"), getContextUsage: entry("pi-runtime", "context.usage"),
  compact: entry("pi-runtime", "context.compact"), getSystemPrompt: entry("pi-runtime", "context.system-prompt"),
} satisfies Record<keyof ExtensionContext, CompatibilityEntry>;

export const commandContextCompatibility = {
  ...extensionContextCompatibility,
  getSystemPromptOptions: entry("pi-runtime", "command.system-prompt-options"), waitForIdle: entry("pi-runtime", "command.wait-idle"),
  newSession: entry("pi-runtime", "command.new-session"), fork: entry("pi-runtime", "command.fork"), navigateTree: entry("pi-runtime", "command.navigate-tree"),
  switchSession: entry("pi-runtime", "command.switch-session"), reload: entry("pi-runtime", "command.reload"),
} satisfies Record<keyof ExtensionCommandContext, CompatibilityEntry>;

export const extensionAPICompatibility = {
  on: entry("pi-runtime", "registration.events"), registerTool: entry("pi-runtime", "registration.tools"), registerCommand: entry("pi-runtime", "registration.commands"),
  registerShortcut: entry("pi-runtime", "registration.shortcuts"), registerFlag: entry("pi-runtime", "registration.flags"), getFlag: entry("pi-runtime", "control.flags"),
  registerMessageRenderer: entry("renderer", "renderer.message"), registerMarkdownTransformer: entry("renderer", "renderer.markdown"), registerEntryRenderer: entry("renderer", "renderer.entry"),
  sendMessage: entry("pi-runtime", "control.send-message"), sendUserMessage: entry("pi-runtime", "control.send-user-message"), appendEntry: entry("pi-runtime", "control.append-entry"),
  setSessionName: entry("pi-runtime", "control.session-name"), getSessionName: entry("pi-runtime", "control.session-name"), setLabel: entry("pi-runtime", "control.label"),
  exec: entry("pi-runtime", "control.exec"), getActiveTools: entry("pi-runtime", "control.tools"), getAllTools: entry("pi-runtime", "control.tools"), setActiveTools: entry("pi-runtime", "control.tools"),
  getCommands: entry("pi-runtime", "control.commands"), setModel: entry("pi-runtime", "control.model"), getThinkingLevel: entry("pi-runtime", "control.thinking"), setThinkingLevel: entry("pi-runtime", "control.thinking"),
  registerProvider: entry("pi-runtime", "registration.providers"), unregisterProvider: entry("pi-runtime", "registration.providers"), events: entry("pi-runtime", "registration.event-bus"),
} satisfies Record<keyof ExtensionAPI, CompatibilityEntry>;

type PublicToolRenderContext = Parameters<NonNullable<ToolDefinition["renderCall"]>>[2];

export const toolDefinitionCompatibility = {
  name: "pi-runtime", label: "pi-runtime", description: "pi-runtime", promptSnippet: "pi-runtime",
  promptGuidelines: "pi-runtime", parameters: "pi-runtime", constrainedSampling: "pi-runtime",
  renderShell: "renderer", prepareArguments: "pi-runtime", executionMode: "pi-runtime", execute: "pi-runtime",
  renderCall: "renderer", renderResult: "renderer",
} satisfies Record<keyof ToolDefinition, "pi-runtime" | "renderer">;

export const remoteTuiFeasibilityCompatibility = {
  terminal: entry("remote-component", "feasibility.terminal", "A bounded no-stdio Terminal drives production read-only component widgets; remote input remains unavailable."),
  composition: entry("remote-component", "feasibility.main-screen", "Root-exported TuiMainScreen capture composes retained read-only widgets; overlay geometry, stacking, focus, and blocking custom UI remain deferred."),
  recording: entry("remote-component", "feasibility.recording", "Recording wrappers capture Pi's single render invocation into generic widget surfaces; interactive component surfaces remain deferred."),
  frameParser: entry("remote-component", "feasibility.frame-parser", "Logical lines sanitize to bounded plain text, RGB styles, safe links, and cursor state for the unified v2 presentation protocol."),
  presentationStore: entry("remote-component", "presentation.aggregate-revision", "One epoch-scoped store atomically owns semantic state, surfaces, interactions, leases, capabilities, and diagnostics while production remains RPC."),
  fullFrames: entry("remote-component", "presentation.full-frames", "Retained component widgets may publish bounded read-only frames; interactive custom/overlay surfaces remain deferred."),
  inputLeaseProjection: entry("remote-component", "presentation.input-lease", "The scoped lease is modeled and retained; acquisition and input routing await Phase 4C."),
  terminalImages: entry("explicit-fallback", "feasibility.images", "Kitty/iTerm image and file controls are stripped; remote terminal images are not advertised."),
  kittyKeyRelease: entry("explicit-fallback", "feasibility.kitty-key-release", "The in-memory terminal truthfully reports Kitty keyboard protocol unavailable."),
} as const;

export const rendererThemeCompatibility = {
  callbackInjectedTheme: entry("renderer", "renderer.callback-theme", "The public callback theme is authoritative for renderer execution."),
  processGlobalHelpers: entry("explicit-fallback", "renderer.global-theme-helpers", "Pi exposes initialization but no public per-session process-global synchronization seam."),
} as const;

export const rendererContractCompatibility = {
  toolResultOptions: { expanded: "renderer", isPartial: "renderer" } satisfies Record<keyof ToolRenderResultOptions, "renderer">,
  toolContext: {
    args: "renderer", toolCallId: "renderer", invalidate: "renderer", lastComponent: "renderer", state: "renderer", cwd: "renderer",
    executionStarted: "renderer", argsComplete: "renderer", isPartial: "renderer", expanded: "renderer", showImages: "renderer", isError: "renderer",
  } satisfies Record<keyof PublicToolRenderContext, "renderer">,
  messageOptions: { expanded: "renderer", outputPad: "renderer" } satisfies Record<keyof MessageRenderOptions, "renderer">,
  entryOptions: { expanded: "renderer" } satisfies Record<keyof EntryRenderOptions, "renderer">,
  markdownContext: { messageType: "renderer", isStreaming: "renderer", availableWidth: "renderer" } satisfies Record<keyof MarkdownTransformContext, "renderer">,
} as const;
