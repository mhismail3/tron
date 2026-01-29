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
  SpawnTmuxAgentTool,
  type SpawnTmuxAgentToolConfig,
  type SpawnTmuxAgentParams,
  type SpawnTmuxAgentResult,
  type SpawnTmuxAgentCallback,
  QuerySubagentTool,
  type QuerySubagentToolConfig,
  type QuerySubagentParams,
  type QuerySubagentResult,
  type QuerySubagentCallback,
  type SubagentQueryType,
  type SubagentStatusInfo,
  type SubagentEventInfo,
  type SubagentLogInfo,
  WaitForSubagentTool,
  type WaitForSubagentToolConfig,
  type WaitForSubagentParams,
  type WaitForSubagentResult,
  type WaitForSubagentCallback,
  SubAgentTracker,
  createSubAgentTracker,
  type TrackedSubagent,
  type SubagentStatus,
  type SubagentTrackingEvent,
  type SubagentResult,
  type SubagentCompletionCallback,
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

// Utility functions for token estimation and output truncation
export {
  estimateTokens,
  tokensToChars,
  truncateOutput,
  type TruncateOptions,
  type TruncateResult,
} from './utils.js';
