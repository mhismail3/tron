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

export const PINNED_PI_VERSION = "0.84.1" as const;
export const EXTENSION_PRESENTATION_VERSION = 2 as const;

export type HostClassification = "native-semantic" | "remote-component" | "renderer" | "pi-runtime" | "explicit-fallback";
export interface CompatibilityEntry {
  classification: HostClassification;
  capability: string;
  limitation?: string;
}
const entry = (classification: HostClassification, capability: string, limitation?: string): CompatibilityEntry => ({
  classification, capability, ...(limitation ? { limitation } : {}),
});

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
  session_shutdown: entry("pi-runtime", "event.session-shutdown"), session_before_tree: entry("pi-runtime", "event.session-before-tree"),
  session_tree: entry("pi-runtime", "event.session-tree"), context: entry("pi-runtime", "event.context"),
  before_provider_request: entry("pi-runtime", "event.provider-request"), before_provider_headers: entry("pi-runtime", "event.provider-headers"),
  after_provider_response: entry("pi-runtime", "event.provider-response"), before_agent_start: entry("pi-runtime", "event.before-agent-start"),
  agent_start: entry("pi-runtime", "event.agent-start"), agent_end: entry("pi-runtime", "event.agent-end"), agent_settled: entry("pi-runtime", "event.agent-settled"),
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

export type OfficialExampleClassification = "extension-source" | "extension-resource" | "package-resource" | "documentation" | "component-asset";
export const officialExampleInventory = [
  { path: "README.md", classification: "documentation" },
  { path: "auto-commit-on-exit.ts", classification: "extension-source" },
  { path: "bash-spawn-hook.ts", classification: "extension-source" },
  { path: "bookmark.ts", classification: "extension-source" },
  { path: "border-status-editor.ts", classification: "extension-source" },
  { path: "built-in-tool-renderer.ts", classification: "extension-source" },
  { path: "claude-rules.ts", classification: "extension-source" },
  { path: "commands.ts", classification: "extension-source" },
  { path: "confirm-destructive.ts", classification: "extension-source" },
  { path: "custom-compaction.ts", classification: "extension-source" },
  { path: "custom-footer.ts", classification: "extension-source" },
  { path: "custom-header.ts", classification: "extension-source" },
  { path: "custom-provider-anthropic/index.ts", classification: "extension-source" },
  { path: "custom-provider-anthropic/package-lock.json", classification: "package-resource" },
  { path: "custom-provider-anthropic/package.json", classification: "package-resource" },
  { path: "custom-provider-gitlab-duo/index.ts", classification: "extension-source" },
  { path: "custom-provider-gitlab-duo/package.json", classification: "package-resource" },
  { path: "custom-provider-gitlab-duo/test.ts", classification: "extension-source" },
  { path: "dirty-repo-guard.ts", classification: "extension-source" },
  { path: "doom-overlay/README.md", classification: "documentation" },
  { path: "doom-overlay/doom-component.ts", classification: "extension-source" },
  { path: "doom-overlay/doom-engine.ts", classification: "extension-source" },
  { path: "doom-overlay/doom-keys.ts", classification: "extension-source" },
  { path: "doom-overlay/doom/build.sh", classification: "component-asset" },
  { path: "doom-overlay/doom/build/doom.js", classification: "component-asset" },
  { path: "doom-overlay/doom/build/doom.wasm", classification: "component-asset" },
  { path: "doom-overlay/doom/doomgeneric_pi.c", classification: "component-asset" },
  { path: "doom-overlay/index.ts", classification: "extension-source" },
  { path: "doom-overlay/wad-finder.ts", classification: "extension-source" },
  { path: "dynamic-resources/SKILL.md", classification: "extension-resource" },
  { path: "dynamic-resources/dynamic.json", classification: "extension-resource" },
  { path: "dynamic-resources/dynamic.md", classification: "extension-resource" },
  { path: "dynamic-resources/index.ts", classification: "extension-source" },
  { path: "dynamic-tools.ts", classification: "extension-source" },
  { path: "entry-renderer.ts", classification: "extension-source" },
  { path: "event-bus.ts", classification: "extension-source" },
  { path: "file-trigger.ts", classification: "extension-source" },
  { path: "git-checkpoint.ts", classification: "extension-source" },
  { path: "git-merge-and-resolve.ts", classification: "extension-source" },
  { path: "github-issue-autocomplete.ts", classification: "extension-source" },
  { path: "gondolin/index.ts", classification: "extension-source" },
  { path: "gondolin/package-lock.json", classification: "package-resource" },
  { path: "gondolin/package.json", classification: "package-resource" },
  { path: "handoff.ts", classification: "extension-source" },
  { path: "hello.ts", classification: "extension-source" },
  { path: "hidden-thinking-label.ts", classification: "extension-source" },
  { path: "inline-bash.ts", classification: "extension-source" },
  { path: "input-transform-streaming.ts", classification: "extension-source" },
  { path: "input-transform.ts", classification: "extension-source" },
  { path: "interactive-shell.ts", classification: "extension-source" },
  { path: "kimi-deferred-tools.ts", classification: "extension-source" },
  { path: "mac-system-theme.ts", classification: "extension-source" },
  { path: "message-renderer.ts", classification: "extension-source" },
  { path: "minimal-mode.ts", classification: "extension-source" },
  { path: "modal-editor.ts", classification: "extension-source" },
  { path: "model-status.ts", classification: "extension-source" },
  { path: "notify.ts", classification: "extension-source" },
  { path: "overlay-qa-tests.ts", classification: "extension-source" },
  { path: "overlay-test.ts", classification: "extension-source" },
  { path: "permission-gate.ts", classification: "extension-source" },
  { path: "pirate.ts", classification: "extension-source" },
  { path: "plan-mode/README.md", classification: "documentation" },
  { path: "plan-mode/index.ts", classification: "extension-source" },
  { path: "plan-mode/utils.ts", classification: "extension-source" },
  { path: "preset.ts", classification: "extension-source" },
  { path: "project-trust.ts", classification: "extension-source" },
  { path: "prompt-customizer.ts", classification: "extension-source" },
  { path: "protected-paths.ts", classification: "extension-source" },
  { path: "provider-payload.ts", classification: "extension-source" },
  { path: "qna.ts", classification: "extension-source" },
  { path: "question.ts", classification: "extension-source" },
  { path: "questionnaire.ts", classification: "extension-source" },
  { path: "rainbow-editor.ts", classification: "extension-source" },
  { path: "reload-runtime.ts", classification: "extension-source" },
  { path: "rpc-demo.ts", classification: "extension-source" },
  { path: "sandbox/index.ts", classification: "extension-source" },
  { path: "sandbox/package-lock.json", classification: "package-resource" },
  { path: "sandbox/package.json", classification: "package-resource" },
  { path: "send-user-message.ts", classification: "extension-source" },
  { path: "session-name.ts", classification: "extension-source" },
  { path: "shutdown-command.ts", classification: "extension-source" },
  { path: "snake.ts", classification: "extension-source" },
  { path: "space-invaders.ts", classification: "extension-source" },
  { path: "ssh.ts", classification: "extension-source" },
  { path: "status-line.ts", classification: "extension-source" },
  { path: "structured-output.ts", classification: "extension-source" },
  { path: "subagent/README.md", classification: "documentation" },
  { path: "subagent/agents.ts", classification: "extension-source" },
  { path: "subagent/agents/planner.md", classification: "extension-resource" },
  { path: "subagent/agents/reviewer.md", classification: "extension-resource" },
  { path: "subagent/agents/scout.md", classification: "extension-resource" },
  { path: "subagent/agents/worker.md", classification: "extension-resource" },
  { path: "subagent/index.ts", classification: "extension-source" },
  { path: "subagent/prompts/implement-and-review.md", classification: "extension-resource" },
  { path: "subagent/prompts/implement.md", classification: "extension-resource" },
  { path: "subagent/prompts/scout-and-plan.md", classification: "extension-resource" },
  { path: "summarize.ts", classification: "extension-source" },
  { path: "system-prompt-header.ts", classification: "extension-source" },
  { path: "tic-tac-toe.ts", classification: "extension-source" },
  { path: "timed-confirm.ts", classification: "extension-source" },
  { path: "titlebar-spinner.ts", classification: "extension-source" },
  { path: "todo.ts", classification: "extension-source" },
  { path: "tool-override.ts", classification: "extension-source" },
  { path: "tools.ts", classification: "extension-source" },
  { path: "trigger-compact.ts", classification: "extension-source" },
  { path: "truncated-tool.ts", classification: "extension-source" },
  { path: "widget-placement.ts", classification: "extension-source" },
  { path: "with-deps/index.ts", classification: "extension-source" },
  { path: "with-deps/package-lock.json", classification: "package-resource" },
  { path: "with-deps/package.json", classification: "package-resource" },
  { path: "working-indicator.ts", classification: "extension-source" },
  { path: "working-message-test.ts", classification: "extension-source" },
] as const satisfies readonly { path: string; classification: OfficialExampleClassification }[];
