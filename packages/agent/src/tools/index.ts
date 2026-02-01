/**
 * @fileoverview Tools module exports
 *
 * Tools are organized by domain:
 * - fs/       - Filesystem operations (read, write, edit, find)
 * - subagent/ - Subagent management (spawn, query, wait, tracker)
 * - browser/  - Browser automation (open-url, browse-the-web)
 * - system/   - System commands (bash)
 * - search/   - Code search (unified text + AST search)
 * - ui/       - User interaction (ask-user-question, todo-write, notify-app, render-app-ui)
 * - web/      - Web fetching and searching (web-fetch, web-search)
 */

// Filesystem tools
export {
  ReadTool,
  type ReadToolConfig,
  WriteTool,
  type WriteToolConfig,
  EditTool,
  type EditToolConfig,
  FindTool,
  type FindToolConfig,
} from './fs/index.js';

// Subagent tools
export {
  SpawnSubagentTool,
  type SpawnSubagentToolConfig,
  type SpawnSubagentParams,
  type SpawnSubagentResult,
  type SpawnSubagentCallback,
  QueryAgentTool,
  type QueryAgentToolConfig,
  type QueryAgentParams,
  type QueryAgentResult,
  type QueryAgentCallback,
  type SubagentQueryType,
  type SubagentStatusInfo,
  type SubagentEventInfo,
  type SubagentLogInfo,
  WaitForAgentsTool,
  type WaitForAgentsToolConfig,
  type WaitForAgentsParams,
  type WaitForAgentsResult,
  type WaitForAgentsCallback,
  SubAgentTracker,
  createSubAgentTracker,
  type TrackedSubagent,
  type SubagentStatus,
  type SubagentTrackingEvent,
  type SubagentResult,
  type SubagentCompletionCallback,
  // Tool denial system
  checkToolDenial,
  filterToolsByDenial,
  mergeToolDenials,
  type ToolDenialConfig,
  type ToolDenialRule,
  type ParameterDenialPattern,
  type ToolDenialCheckResult,
} from './subagent/index.js';

// Browser tools
export {
  OpenURLTool,
  type OpenURLConfig,
  BrowseTheWebTool,
  type BrowseTheWebToolConfig,
  type BrowserDelegate,
} from './browser/index.js';

// System tools
export {
  BashTool,
  type BashToolConfig,
} from './system/index.js';

// Search tools
export {
  SearchTool,
  type SearchToolConfig,
} from './search/index.js';

// UI tools
export {
  AskUserQuestionTool,
  type AskUserQuestionConfig,
  TodoWriteTool,
  type TodoWriteToolConfig,
  type TodoWriteParams,
  type TodoWriteDetails,
  NotifyAppTool,
  type NotifyAppToolConfig,
  type NotifyAppParams,
  type NotifyAppResult,
  type NotifyAppCallback,
  RenderAppUITool,
  type RenderAppUIConfig,
} from './ui/index.js';

// Web tools
export {
  WebFetchTool,
  type WebFetchToolConfig,
  type WebFetchParams,
  type WebFetchResult,
  type SubagentSpawnCallback as WebFetchSubagentCallback,
  type SubagentSpawnResult as WebFetchSubagentResult,
  // WebSearch v2 - comprehensive Brave API support
  WebSearchToolV2,
  type WebSearchV2Config,
  // Legacy WebSearch - deprecated, use WebSearchToolV2
  WebSearchTool,
  type WebSearchToolConfig,
  type WebSearchParams,
  type WebSearchResult,
  type SearchResultItem,
  // Brave API components
  BraveKeyRotator,
  KeyRotatorError,
  type KeyRotatorConfig,
  type RotatorStatus,
  type PublicKeyState,
  BraveMultiClient,
  type BraveMultiClientConfig,
  type BraveSearchParams as BraveApiSearchParams,
  type BraveSearchResult as BraveApiSearchResult,
  // Brave API types
  type BraveEndpoint,
  type BraveWebResult,
  type BraveNewsResult,
  type BraveImageResult,
  type BraveVideoResult,
  type BraveFreshness,
  type BraveSafesearch,
  type BraveWebSearchResponse,
  type BraveNewsSearchResponse,
  type BraveImageSearchResponse,
  type BraveVideoSearchResponse,
  BRAVE_ENDPOINT_PATHS,
  BRAVE_ENDPOINT_LIMITS,
  BRAVE_ENDPOINT_CAPABILITIES,
  // Summarizer
  createSummarizer,
  createHaikuSummarizer,
  type SummarizerConfig,
  // Utilities
  validateUrl,
  UrlValidator,
  type UrlValidatorConfig,
  parseHtml,
  HtmlParser,
  type HtmlParserConfig,
  WebCache,
  type WebCacheConfig,
  // Legacy Brave client - deprecated, use BraveMultiClient
  BraveSearchClient,
  type BraveSearchClientConfig,
} from './web/index.js';

// Utility functions for token estimation and output truncation
export {
  estimateTokens,
  tokensToChars,
  truncateOutput,
  type TruncateOptions,
  type TruncateResult,
} from './utils.js';
