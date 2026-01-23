/**
 * @fileoverview Subagent Tools
 *
 * Tools for spawning, querying, and managing subagent sessions.
 */

export {
  SpawnSubagentTool,
  type SpawnSubagentToolConfig,
  type SpawnSubagentParams,
  type SpawnSubagentResult,
  type SpawnSubagentCallback,
} from './spawn-subagent.js';

export {
  SpawnTmuxAgentTool,
  type SpawnTmuxAgentToolConfig,
  type SpawnTmuxAgentParams,
  type SpawnTmuxAgentResult,
  type SpawnTmuxAgentCallback,
} from './spawn-tmux-agent.js';

export {
  QuerySubagentTool,
  type QuerySubagentToolConfig,
  type QuerySubagentParams,
  type QuerySubagentResult,
  type QuerySubagentCallback,
  type SubagentQueryType,
  type SubagentStatusInfo,
  type SubagentEventInfo,
  type SubagentLogInfo,
} from './query-subagent.js';

export {
  WaitForSubagentTool,
  type WaitForSubagentToolConfig,
  type WaitForSubagentParams,
  type WaitForSubagentResult,
  type WaitForSubagentCallback,
} from './wait-for-subagent.js';

export {
  SubAgentTracker,
  createSubAgentTracker,
  type TrackedSubagent,
  type SubagentStatus,
  type SubagentTrackingEvent,
  type SubagentResult,
  type SubagentCompletionCallback,
} from './subagent-tracker.js';
