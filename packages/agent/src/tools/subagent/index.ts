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
  QueryAgentTool,
  type QueryAgentToolConfig,
  type QueryAgentParams,
  type QueryAgentResult,
  type QueryAgentCallback,
  type SubagentQueryType,
  type SubagentStatusInfo,
  type SubagentEventInfo,
  type SubagentLogInfo,
} from './query-agent.js';

export {
  WaitForAgentsTool,
  type WaitForAgentsToolConfig,
  type WaitForAgentsParams,
  type WaitForAgentsResult,
  type WaitForAgentsCallback,
} from './wait-for-agents.js';

export {
  SubAgentTracker,
  createSubAgentTracker,
  type TrackedSubagent,
  type SubagentStatus,
  type SubagentTrackingEvent,
  type SubagentResult,
  type SubagentCompletionCallback,
} from './subagent-tracker.js';
