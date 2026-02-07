/**
 * @fileoverview Streaming Event RPC Types
 *
 * Types for real-time streaming events from server to client.
 */

import type { SessionEvent, TokenUsage } from '@infrastructure/events/types.js';
import type { TokenRecord } from '@infrastructure/tokens/index.js';

// =============================================================================
// Event Types
// =============================================================================

/**
 * All event types that can be sent from server to client
 */
export type RpcEventType =
  // Agent events
  | 'agent.turn_start'
  | 'agent.turn_end'
  | 'agent.text_delta'
  | 'agent.thinking_delta'
  | 'agent.tool_start'
  | 'agent.tool_end'
  | 'agent.error'
  | 'agent.complete'
  | 'agent.ready'
  // Subagent events (for iOS real-time updates)
  | 'agent.subagent_spawned'
  | 'agent.subagent_status'
  | 'agent.subagent_completed'
  | 'agent.subagent_failed'
  | 'agent.subagent_event'  // Forwarded event from subagent (tool calls, text, etc.)
  | 'agent.subagent_result_available'  // Subagent completed while parent was idle
  // Session events
  | 'session.created'
  | 'session.ended'
  | 'session.updated'
  | 'session.forked'
  // Event sync events (for real-time event broadcasting)
  | 'events.new'
  | 'events.batch'
  // Tree events
  | 'tree.updated'
  | 'tree.branch_created'
  // System events
  | 'system.connected'
  | 'system.disconnected'
  | 'system.error'
  // Browser events
  | 'browser.frame'
  // UI Canvas events (for RenderAppUI tool)
  | 'agent.ui_render_start'
  | 'agent.ui_render_chunk'
  | 'agent.ui_render_complete'
  | 'agent.ui_action'
  | 'agent.ui_state_change';

/**
 * Event data for agent turn end
 * Includes both raw and structured token data for UI components
 */
export interface AgentTurnEndEvent {
  turn: number;
  duration: number;
  tokenUsage?: TokenUsage;
  /** Immutable token record with source, computed, and metadata */
  tokenRecord?: TokenRecord;
  cost?: number;
  contextLimit?: number;
}

/**
 * Event data for agent text streaming
 */
export interface AgentTextDeltaEvent {
  delta: string;
  accumulated?: string;
}

/**
 * Event data for agent thinking streaming
 */
export interface AgentThinkingDeltaEvent {
  delta: string;
}

/**
 * Event data for tool start
 */
export interface AgentToolStartEvent {
  toolCallId: string;
  toolName: string;
  arguments: Record<string, unknown>;
}

/**
 * Event data for tool end
 */
export interface AgentToolEndEvent {
  toolCallId: string;
  toolName: string;
  duration: number;
  success: boolean;
  output?: string;
  error?: string;
}

/**
 * Event data for agent completion
 */
export interface AgentCompleteEvent {
  turns: number;
  tokenUsage: {
    input: number;
    output: number;
  };
  success: boolean;
  error?: string;
}

/**
 * Event data for subagent spawned (real-time WebSocket streaming for iOS)
 * Note: Distinct from SubagentSpawnedEvent in events/types.ts which is for DB storage
 */
export interface RpcSubagentSpawnedData {
  subagentSessionId: string;
  task: string;
  model: string;
  workingDirectory: string;
  toolCallId?: string;
}

/**
 * Event data for subagent status update (real-time WebSocket streaming for iOS)
 */
export interface RpcSubagentStatusData {
  subagentSessionId: string;
  status: 'running' | 'completed' | 'failed';
  currentTurn: number;
}

/**
 * Event data for subagent completed (real-time WebSocket streaming for iOS)
 * Note: Distinct from SubagentCompletedEvent in events/types.ts which is for DB storage
 */
export interface RpcSubagentCompletedData {
  subagentSessionId: string;
  resultSummary: string;
  fullOutput: string;
  totalTurns: number;
  duration: number;
  tokenUsage?: {
    inputTokens: number;
    outputTokens: number;
  };
}

/**
 * Event data for subagent failed (real-time WebSocket streaming for iOS)
 * Note: Distinct from SubagentFailedEvent in events/types.ts which is for DB storage
 */
export interface RpcSubagentFailedData {
  subagentSessionId: string;
  error: string;
  duration: number;
}

/**
 * Event data for subagent result available notification
 * Emitted when a non-blocking subagent completes while the parent is idle,
 * allowing iOS to show a notification chip for the user to review results.
 */
export interface RpcSubagentResultAvailableData {
  parentSessionId: string;
  subagentSessionId: string;
  task: string;
  resultSummary: string;
  success: boolean;
  totalTurns: number;
  duration: number;
  tokenUsage?: {
    inputTokens: number;
    outputTokens: number;
  };
  error?: string;
  completedAt: string;
}

/**
 * Event data for session fork notification
 */
export interface SessionForkedEvent {
  sourceSessionId: string;
  sourceEventId: string;
  newSessionId: string;
  newRootEventId: string;
  name?: string;
}

/**
 * Event data for new session event broadcast
 */
export interface EventsNewEvent {
  event: SessionEvent;
  sessionId: string;
}

/**
 * Event data for batch event broadcast
 */
export interface EventsBatchEvent {
  events: SessionEvent[];
  sessionId: string;
  syncCursor: string;
}

/**
 * Event data for tree structure update
 */
export interface TreeUpdatedEvent {
  sessionId: string;
  headEventId: string;
  affectedEventIds: string[];
}

/**
 * Event data for branch creation
 */
export interface TreeBranchCreatedEvent {
  sourceSessionId: string;
  newSessionId: string;
  forkEventId: string;
  branchName?: string;
}
