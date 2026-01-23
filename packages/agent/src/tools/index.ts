/**
 * @fileoverview Tools module exports
 *
 * Tools are organized by domain:
 * - fs/       - Filesystem operations (read, write, edit, find, grep, ls)
 * - subagent/ - Subagent management (spawn, query, wait, tracker)
 * - browser/  - Browser automation (open-browser, agent-web-browser)
 * - system/   - System commands (bash, ast-grep)
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
  GrepTool,
  type GrepToolConfig,
  LsTool,
  type LsToolConfig,
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
  OpenBrowserTool,
  type OpenBrowserConfig,
  AgentWebBrowserTool,
  type AgentWebBrowserToolConfig,
  type BrowserDelegate,
} from './browser/index.js';

// System tools
export {
  BashTool,
  type BashToolConfig,
  AstGrepTool,
  type AstGrepToolConfig,
  type AstGrepMatch,
  type AstGrepDetails,
} from './system/index.js';

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
