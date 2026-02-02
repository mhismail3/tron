/**
 * @fileoverview Subagent Events
 *
 * Events for subagent lifecycle management.
 */

import type { SessionId } from './branded.js';
import type { BaseEvent } from './base.js';
import type { TokenUsage } from './token-usage.js';

// =============================================================================
// Subagent Events
// =============================================================================

/** Spawn type for subagent */
export type SubagentSpawnType = 'subsession' | 'tmux' | 'fork';

/**
 * Subagent spawned event - emitted when a sub-agent is created
 */
export interface SubagentSpawnedEvent extends BaseEvent {
  type: 'subagent.spawned';
  payload: {
    /** Session ID of the spawned sub-agent */
    subagentSessionId: SessionId;
    /** Type of spawn (in-process vs tmux) */
    spawnType: SubagentSpawnType;
    /** Task/prompt given to the sub-agent */
    task: string;
    /** Model used by the sub-agent */
    model: string;
    /** Tools enabled for the sub-agent */
    tools?: string[];
    /** Skills loaded for the sub-agent */
    skills?: string[];
    /** Working directory for the sub-agent */
    workingDirectory: string;
    /** Tmux session name (only for tmux spawn type) */
    tmuxSessionName?: string;
    /** Maximum turns allowed */
    maxTurns?: number;
  };
}

/**
 * Subagent status update event - periodic status updates during execution
 */
export interface SubagentStatusUpdateEvent extends BaseEvent {
  type: 'subagent.status_update';
  payload: {
    /** Session ID of the sub-agent */
    subagentSessionId: SessionId;
    /** Current status */
    status: 'running' | 'paused' | 'waiting_input';
    /** Current turn number */
    currentTurn: number;
    /** Brief description of current activity */
    activity?: string;
    /** Token usage so far */
    tokenUsage?: TokenUsage;
  };
}

/**
 * Subagent completed event - emitted when sub-agent finishes successfully
 */
export interface SubagentCompletedEvent extends BaseEvent {
  type: 'subagent.completed';
  payload: {
    /** Session ID of the sub-agent */
    subagentSessionId: SessionId;
    /** Summary of what the sub-agent accomplished */
    resultSummary: string;
    /** Total turns taken */
    totalTurns: number;
    /** Total token usage */
    totalTokenUsage: TokenUsage;
    /** Duration in milliseconds */
    duration: number;
    /** Files modified by the sub-agent */
    filesModified?: string[];
    /** Final output/response from the sub-agent */
    finalOutput?: string;
  };
}

/**
 * Subagent failed event - emitted when sub-agent fails
 */
export interface SubagentFailedEvent extends BaseEvent {
  type: 'subagent.failed';
  payload: {
    /** Session ID of the sub-agent */
    subagentSessionId: SessionId;
    /** Error message */
    error: string;
    /** Error code if available */
    code?: string;
    /** Whether the error is recoverable */
    recoverable: boolean;
    /** Partial result if any work was completed before failure */
    partialResult?: string;
    /** Turn number when failure occurred */
    failedAtTurn?: number;
    /** Duration until failure in milliseconds */
    duration?: number;
  };
}
