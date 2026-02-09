/**
 * @fileoverview Shared Types for Sub-Agent Operations
 *
 * Defines common interfaces used by sub-agent handlers.
 */
import type { EventStore, SessionId, EventType } from '@infrastructure/events/index.js';
import type {
  SubagentStatusInfo,
  SubagentEventInfo,
  SubagentLogInfo,
} from '@capabilities/tools/subagent/index.js';
import type { SubagentResult } from '@capabilities/tools/subagent/index.js';
import type {
  AgentRunOptions,
  SessionInfo,
  CreateSessionOptions,
} from '../../types.js';
import type { RunResult } from '../../../agent/types.js';
import type { ActiveSessionStore } from '../../session/active-session-store.js';

// =============================================================================
// Configuration Types
// =============================================================================

/**
 * Configuration for SubagentOperations
 */
export interface SubagentOperationsConfig {
  /** EventStore instance for querying sessions */
  eventStore: EventStore;
  /** Active session store */
  sessionStore: ActiveSessionStore;
  /** Create a new session */
  createSession: (options: CreateSessionOptions) => Promise<SessionInfo>;
  /** Run agent for a session - returns RunResult[] */
  runAgent: (options: AgentRunOptions) => Promise<RunResult[]>;
  /** Append event to session (fire-and-forget) */
  appendEventLinearized: (
    sessionId: SessionId,
    type: EventType,
    payload: Record<string, unknown>
  ) => void;
  /** Emit event to orchestrator */
  emit: (event: string, data: unknown) => void;
}

// =============================================================================
// Result Types
// =============================================================================

/**
 * Result of spawning a subagent (unified for both inProcess and tmux modes)
 */
export interface SpawnSubagentResult {
  sessionId: string;
  success: boolean;
  error?: string;
  /** Tmux session name (tmux mode only) */
  tmuxSessionName?: string;
  /** Full output from subagent (blocking mode only) */
  output?: string;
  /** Brief summary of result (blocking mode only) */
  resultSummary?: string;
  /** Token usage (blocking mode only) */
  tokenUsage?: {
    inputTokens: number;
    outputTokens: number;
  };
}

// Legacy type alias for backwards compatibility with tmux-specific result
export type SpawnTmuxAgentResult = SpawnSubagentResult;

/**
 * Result of querying a sub-agent
 */
export interface QuerySubagentResult {
  success: boolean;
  status?: SubagentStatusInfo;
  events?: SubagentEventInfo[];
  logs?: SubagentLogInfo[];
  output?: string;
  error?: string;
}

/**
 * Result of waiting for sub-agents
 */
export interface WaitForSubagentsResult {
  success: boolean;
  results?: SubagentResult[];
  error?: string;
  timedOut?: boolean;
}
