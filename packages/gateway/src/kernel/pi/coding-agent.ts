// The pi-coding-agent half of the Pi seam (K-0 §4): the only production module that
// imports `@earendil-works/pi-coding-agent`. Every name the Gateway uses is listed here;
// a `// patch N` note marks a name used through an API of Tron's patched tarball
// (pi-coding-agent-patch.json `removeWhen`, items 1-5), so this list is the patch-removal
// checklist: when a release ships those APIs, each noted call site is rechecked.
export {
  AgentSessionRuntime,
  createAgentSessionFromServices,
  createAgentSessionRuntime,
  createAgentSessionServices, // patch 1: `{ projectDir }`
  createBashToolDefinition,
  createCodemodeExtension,
  createEditToolDefinition,
  createFindToolDefinition,
  createGrepToolDefinition,
  createLsToolDefinition,
  createMcpExtension,
  createPowerShellToolDefinition,
  createReadToolDefinition,
  createToolSearchExtension,
  createWriteToolDefinition,
  CredentialSynchronizationError,
  DefaultPackageManager, // patch 1: `{ projectDir }`
  DefaultResourceLoader, // patch 1: `projectDir` (session-free extension loads)
  estimateTokens,
  getShellConfig,
  hasTrustRequiringProjectResources, // patch 1: `(cwd, projectDir)`
  initTheme,
  ModelRuntime,
  parseFrontmatter,
  parseSessionEntries,
  ProjectTrustStore,
  SessionManager,
  SettingsManager, // patch 1: `SettingsManager.create(projectDir, …)` reads `<projectDir>/.pi`
  stripFrontmatter,
  Theme,
} from "@earendil-works/pi-coding-agent";
export type {
  AgentSession, // patch 1 `projectDir`; 2-3 `steer`/`followUp(text, images)`; 4 idle `systemPrompt`; 5 `prompt({ preflightResult })` revocation
  AgentSessionEvent,
  BashOperations,
  ContextEditEntry,
  CreateAgentSessionRuntimeFactory,
  EntryRenderer,
  EntryRenderOptions,
  Extension,
  ExtensionAPI,
  ExtensionCommandContext,
  ExtensionCommandContextActions,
  ExtensionContext,
  ExtensionEvent,
  ExtensionFactory,
  ExtensionToolContext,
  ExtensionUIContext,
  FileEntry,
  InlineExtension,
  KeybindingsManager,
  LoadExtensionsResult,
  MarkdownTransformContext,
  MarkdownTransformer,
  MessageRenderer,
  MessageRenderOptions,
  PackageSource,
  RegisteredCommand,
  RegisteredTool,
  ResolvedPaths,
  ResolvedResource,
  SessionBeforeCompactEvent,
  SessionEntry,
  SessionProjection,
  SessionTreeNode,
  SourceInfo,
  ThemeColor,
  ToolDefinition,
  ToolInfo,
  ToolRenderResultOptions,
  ToolResultEvent,
  WorkingIndicatorOptions,
} from "@earendil-works/pi-coding-agent";
