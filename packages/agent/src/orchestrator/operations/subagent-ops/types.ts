/**
 * @fileoverview Shared Types for Sub-Agent Operations
 *
 * Defines common interfaces used by sub-agent handlers.
 */
import type { EventStore, SessionId, EventType } from '../../../events/index.js';
import type {
  SubagentStatusInfo,
  SubagentEventInfo,
  SubagentLogInfo,
} from '../../../tools/subagent/index.js';
import type { SubagentResult } from '../../../tools/subagent/index.js';
import type {
  ActiveSession,
  AgentRunOptions,
  SessionInfo,
  CreateSessionOptions,
} from '../../types.js';

// =============================================================================
// Configuration Types
// =============================================================================

/**
 * Configuration for SubagentOperations
 */
export interface SubagentOperationsConfig {
  /** EventStore instance for querying sessions */
  eventStore: EventStore;
  /** Get active session by ID */
  getActiveSession: (sessionId: string) => ActiveSession | undefined;
  /** Create a new session */
  createSession: (options: CreateSessionOptions) => Promise<SessionInfo>;
  /** Run agent for a session */
  runAgent: (options: AgentRunOptions) => Promise<unknown>;
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
 * Result of spawning a subsession
 */
export interface SpawnSubagentResult {
  sessionId: string;
  success: boolean;
  error?: string;
}

/**
 * Result of spawning a tmux agent
 */
export interface SpawnTmuxAgentResult {
  sessionId: string;
  tmuxSessionName: string;
  success: boolean;
  error?: string;
}

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
