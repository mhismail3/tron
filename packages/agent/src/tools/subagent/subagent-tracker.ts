/**
 * @fileoverview SubAgent Tracker
 *
 * Manages tracking of sub-agents spawned by a session.
 * Supports event-sourced reconstruction for session resume/fork.
 * Provides waiting, notification, and result injection mechanisms.
 */

import type {
  SessionId,
  TokenUsage,
  SubagentSpawnType,
} from '../../events/types.js';
import { createLogger } from '../../logging/index.js';
import { categorizeError, LogErrorCategory, LogErrorCodes } from '../../logging/error-codes.js';

const logger = createLogger('subagent-tracker');

/**
 * Status of a tracked sub-agent
 */
export type SubagentStatus =
  | 'spawning'
  | 'running'
  | 'paused'
  | 'waiting_input'
  | 'completed'
  | 'failed';

/**
 * Full result of a completed sub-agent
 */
export interface SubagentResult {
  /** Session ID of the sub-agent */
  sessionId: SessionId;
  /** Whether the sub-agent completed successfully */
  success: boolean;
  /** Full output text from the sub-agent */
  output: string;
  /** Brief summary of the result */
  summary: string;
  /** Task that was given to the sub-agent */
  task: string;
  /** Total turns taken */
  totalTurns: number;
  /** Total token usage */
  tokenUsage: TokenUsage;
  /** Duration in milliseconds */
  duration: number;
  /** Timestamp when completed */
  completedAt: string;
  /** Error message if failed */
  error?: string;
}

/**
 * Callback for when a sub-agent completes
 */
export type SubagentCompletionCallback = (result: SubagentResult) => void;

/**
 * Information about a tracked sub-agent
 */
export interface TrackedSubagent {
  /** Session ID of the sub-agent */
  sessionId: SessionId;
  /** Event ID that recorded the spawn */
  spawnEventId: string;
  /** Type of spawn */
  spawnType: SubagentSpawnType;
  /** Task/prompt given to the sub-agent */
  task: string;
  /** Model used by the sub-agent */
  model: string;
  /** Working directory */
  workingDirectory: string;
  /** Current status */
  status: SubagentStatus;
  /** Current turn number */
  currentTurn: number;
  /** Token usage so far */
  tokenUsage: TokenUsage;
  /** Start time (ISO string) */
  startedAt: string;
  /** End time if completed/failed (ISO string) */
  endedAt?: string;
  /** Result summary if completed */
  resultSummary?: string;
  /** Full output if completed */
  fullOutput?: string;
  /** Error message if failed */
  error?: string;
  /** Tmux session name (for tmux spawn type) */
  tmuxSessionName?: string;
  /** Maximum turns allowed */
  maxTurns?: number;
  /** Duration in ms if completed */
  duration?: number;
}

/**
 * Generic event structure for reconstruction
 */
export interface SubagentTrackingEvent {
  id: string;
  type: string;
  payload: Record<string, unknown>;
  timestamp?: string;
}

/**
 * SubAgentTracker manages tracking of sub-agents spawned by a session.
 *
 * Key features:
 * - Tracks spawned sub-agents and their status
 * - Supports event-sourced reconstruction from event history
 * - Provides APIs to query active and all sub-agents
 * - Handles context clear/compact (which clear sub-agent tracking)
 * - Maintains pending results queue for automatic injection
 * - Supports promise-based waiting for sub-agent completion
 * - Fires callbacks when sub-agents complete
 */
export class SubAgentTracker {
  private subagents: Map<string, TrackedSubagent> = new Map();

  /** Queue of completed results waiting to be consumed */
  private pendingResults: SubagentResult[] = [];

  /** Callbacks registered for completion notifications */
  private completionCallbacks: Map<string, SubagentCompletionCallback[]> = new Map();

  /** Global callbacks for any sub-agent completion */
  private globalCompletionCallbacks: SubagentCompletionCallback[] = [];

  /** Promises waiting for specific sub-agents to complete */
  private waitingPromises: Map<string, {
    resolve: (result: SubagentResult) => void;
    reject: (error: Error) => void;
    timeoutId?: ReturnType<typeof setTimeout>;
  }[]> = new Map();

  /**
   * Record that a sub-agent has been spawned
   */
  spawn(
    sessionId: SessionId,
    spawnType: SubagentSpawnType,
    task: string,
    model: string,
    workingDirectory: string,
    eventId: string,
    options?: {
      tmuxSessionName?: string;
      maxTurns?: number;
      startedAt?: string;
    }
  ): void {
    this.subagents.set(sessionId, {
      sessionId,
      spawnEventId: eventId,
      spawnType,
      task,
      model,
      workingDirectory,
      status: 'spawning',
      currentTurn: 0,
      tokenUsage: {
        inputTokens: 0,
        outputTokens: 0,
      },
      startedAt: options?.startedAt ?? new Date().toISOString(),
      tmuxSessionName: options?.tmuxSessionName,
      maxTurns: options?.maxTurns,
    });
  }

  /**
   * Update the status of a sub-agent
   */
  updateStatus(
    sessionId: SessionId,
    status: SubagentStatus,
    updates?: {
      currentTurn?: number;
      tokenUsage?: TokenUsage;
      activity?: string;
    }
  ): boolean {
    const subagent = this.subagents.get(sessionId);
    if (!subagent) return false;

    subagent.status = status;
    if (updates?.currentTurn !== undefined) {
      subagent.currentTurn = updates.currentTurn;
    }
    if (updates?.tokenUsage) {
      subagent.tokenUsage = updates.tokenUsage;
    }
    return true;
  }

  /**
   * Mark a sub-agent as completed
   */
  complete(
    sessionId: SessionId,
    resultSummary: string,
    totalTurns: number,
    totalTokenUsage: TokenUsage,
    duration: number,
    fullOutput?: string
  ): boolean {
    const subagent = this.subagents.get(sessionId);
    if (!subagent) return false;

    const completedAt = new Date().toISOString();

    subagent.status = 'completed';
    subagent.resultSummary = resultSummary;
    subagent.fullOutput = fullOutput;
    subagent.currentTurn = totalTurns;
    subagent.tokenUsage = totalTokenUsage;
    subagent.duration = duration;
    subagent.endedAt = completedAt;

    // Create the result object
    const result: SubagentResult = {
      sessionId,
      success: true,
      output: fullOutput ?? resultSummary,
      summary: resultSummary,
      task: subagent.task,
      totalTurns,
      tokenUsage: totalTokenUsage,
      duration,
      completedAt,
    };

    // Add to pending results queue
    this.pendingResults.push(result);

    // Fire completion callbacks
    this.fireCompletionCallbacks(sessionId, result);

    // Resolve waiting promises
    this.resolveWaitingPromises(sessionId, result);

    return true;
  }

  /**
   * Mark a sub-agent as failed
   */
  fail(
    sessionId: SessionId,
    error: string,
    options?: {
      failedAtTurn?: number;
      duration?: number;
    }
  ): boolean {
    const subagent = this.subagents.get(sessionId);
    if (!subagent) return false;

    const completedAt = new Date().toISOString();
    const duration = options?.duration ?? 0;
    const failedAtTurn = options?.failedAtTurn ?? subagent.currentTurn;

    subagent.status = 'failed';
    subagent.error = error;
    subagent.currentTurn = failedAtTurn;
    subagent.duration = duration;
    subagent.endedAt = completedAt;

    // Create the result object (failed)
    const result: SubagentResult = {
      sessionId,
      success: false,
      output: '',
      summary: `Failed: ${error}`,
      task: subagent.task,
      totalTurns: failedAtTurn,
      tokenUsage: subagent.tokenUsage,
      duration,
      completedAt,
      error,
    };

    // Add to pending results queue (even failures)
    this.pendingResults.push(result);

    // Fire completion callbacks (even for failures)
    this.fireCompletionCallbacks(sessionId, result);

    // Resolve waiting promises (they still resolve, just with success: false)
    this.resolveWaitingPromises(sessionId, result);

    return true;
  }

  /**
   * Get a specific sub-agent by session ID
   */
  get(sessionId: SessionId): TrackedSubagent | undefined {
    return this.subagents.get(sessionId);
  }

  /**
   * Check if a sub-agent is tracked
   */
  has(sessionId: SessionId): boolean {
    return this.subagents.has(sessionId);
  }

  /**
   * Get all active (running, spawning, paused, waiting) sub-agents
   */
  getActive(): TrackedSubagent[] {
    return Array.from(this.subagents.values()).filter(
      s => s.status === 'running' || s.status === 'spawning' ||
           s.status === 'paused' || s.status === 'waiting_input'
    );
  }

  /**
   * Get all tracked sub-agents
   */
  getAll(): TrackedSubagent[] {
    return Array.from(this.subagents.values());
  }

  /**
   * Get the count of tracked sub-agents
   */
  get count(): number {
    return this.subagents.size;
  }

  /**
   * Get the count of active sub-agents
   */
  get activeCount(): number {
    return this.getActive().length;
  }

  // ===========================================================================
  // Waiting and Notification APIs
  // ===========================================================================

  /**
   * Wait for a specific sub-agent to complete.
   * Returns a promise that resolves with the result when complete.
   *
   * @param sessionId - Session ID of the sub-agent to wait for
   * @param timeout - Maximum time to wait in milliseconds (default: 5 minutes)
   * @returns Promise that resolves with SubagentResult
   * @throws Error if timeout is reached or sub-agent not found
   */
  waitFor(
    sessionId: SessionId,
    timeout: number = 5 * 60 * 1000
  ): Promise<SubagentResult> {
    const subagent = this.subagents.get(sessionId);

    // If already completed/failed, return immediately
    if (subagent?.status === 'completed' || subagent?.status === 'failed') {
      const result: SubagentResult = {
        sessionId,
        success: subagent.status === 'completed',
        output: subagent.fullOutput ?? subagent.resultSummary ?? '',
        summary: subagent.resultSummary ?? subagent.error ?? '',
        task: subagent.task,
        totalTurns: subagent.currentTurn,
        tokenUsage: subagent.tokenUsage,
        duration: subagent.duration ?? 0,
        completedAt: subagent.endedAt ?? new Date().toISOString(),
        error: subagent.error,
      };
      return Promise.resolve(result);
    }

    // If not tracked at all, reject
    if (!subagent) {
      return Promise.reject(new Error(`Sub-agent ${sessionId} not found`));
    }

    // Create a promise that will be resolved when complete
    return new Promise((resolve, reject) => {
      const timeoutId = setTimeout(() => {
        // Remove this promise from waiting list
        const waiters = this.waitingPromises.get(sessionId);
        if (waiters) {
          const idx = waiters.findIndex(w => w.resolve === resolve);
          if (idx >= 0) waiters.splice(idx, 1);
          if (waiters.length === 0) this.waitingPromises.delete(sessionId);
        }
        reject(new Error(`Timeout waiting for sub-agent ${sessionId} after ${timeout}ms`));
      }, timeout);

      const waiter = { resolve, reject, timeoutId };
      const existing = this.waitingPromises.get(sessionId);
      if (existing) {
        existing.push(waiter);
      } else {
        this.waitingPromises.set(sessionId, [waiter]);
      }
    });
  }

  /**
   * Wait for any of the specified sub-agents to complete.
   * Returns when the first one completes.
   *
   * @param sessionIds - Array of session IDs to wait for
   * @param timeout - Maximum time to wait in milliseconds
   * @returns Promise that resolves with the first completed result
   */
  waitForAny(
    sessionIds: SessionId[],
    timeout: number = 5 * 60 * 1000
  ): Promise<SubagentResult> {
    if (sessionIds.length === 0) {
      return Promise.reject(new Error('No session IDs provided'));
    }
    return Promise.race(sessionIds.map(id => this.waitFor(id, timeout)));
  }

  /**
   * Wait for all specified sub-agents to complete.
   *
   * @param sessionIds - Array of session IDs to wait for
   * @param timeout - Maximum time to wait in milliseconds (applies to each)
   * @returns Promise that resolves with all results
   */
  waitForAll(
    sessionIds: SessionId[],
    timeout: number = 5 * 60 * 1000
  ): Promise<SubagentResult[]> {
    if (sessionIds.length === 0) {
      return Promise.resolve([]);
    }
    return Promise.all(sessionIds.map(id => this.waitFor(id, timeout)));
  }

  /**
   * Register a callback to be called when a specific sub-agent completes.
   *
   * @param sessionId - Session ID to watch
   * @param callback - Function to call when complete
   */
  onComplete(sessionId: SessionId, callback: SubagentCompletionCallback): void {
    const existing = this.completionCallbacks.get(sessionId);
    if (existing) {
      existing.push(callback);
    } else {
      this.completionCallbacks.set(sessionId, [callback]);
    }
  }

  /**
   * Register a callback to be called when ANY sub-agent completes.
   *
   * @param callback - Function to call when any sub-agent completes
   */
  onAnyComplete(callback: SubagentCompletionCallback): void {
    this.globalCompletionCallbacks.push(callback);
  }

  /**
   * Remove a completion callback.
   */
  removeCompletionCallback(
    sessionId: SessionId,
    callback: SubagentCompletionCallback
  ): void {
    const callbacks = this.completionCallbacks.get(sessionId);
    if (callbacks) {
      const idx = callbacks.indexOf(callback);
      if (idx >= 0) callbacks.splice(idx, 1);
      if (callbacks.length === 0) this.completionCallbacks.delete(sessionId);
    }
  }

  /**
   * Remove a global completion callback.
   */
  removeGlobalCompletionCallback(callback: SubagentCompletionCallback): void {
    const idx = this.globalCompletionCallbacks.indexOf(callback);
    if (idx >= 0) this.globalCompletionCallbacks.splice(idx, 1);
  }

  // ===========================================================================
  // Pending Results Queue (for automatic injection)
  // ===========================================================================

  /**
   * Get all pending results without consuming them.
   */
  getPendingResults(): SubagentResult[] {
    return [...this.pendingResults];
  }

  /**
   * Consume all pending results (removes them from queue).
   * Call this after injecting results into context.
   */
  consumePendingResults(): SubagentResult[] {
    const results = this.pendingResults;
    this.pendingResults = [];
    return results;
  }

  /**
   * Check if there are any pending results.
   */
  hasPendingResults(): boolean {
    return this.pendingResults.length > 0;
  }

  /**
   * Get count of pending results.
   */
  get pendingCount(): number {
    return this.pendingResults.length;
  }

  // ===========================================================================
  // Internal Helper Methods
  // ===========================================================================

  /**
   * Fire completion callbacks for a session.
   */
  private fireCompletionCallbacks(sessionId: SessionId, result: SubagentResult): void {
    // Session-specific callbacks
    const callbacks = this.completionCallbacks.get(sessionId);
    if (callbacks) {
      for (const cb of callbacks) {
        try {
          cb(result);
        } catch (err) {
          // Log but don't throw - we don't want callback errors to break the flow
          const structured = categorizeError(err, { sessionId, callbackType: 'session-specific' });
          logger.error('Subagent completion callback error', {
            code: LogErrorCodes.SUB_ERROR,
            category: LogErrorCategory.SUBAGENT,
            sessionId,
            error: structured.message,
            retryable: structured.retryable,
          });
        }
      }
      // Clear callbacks after firing
      this.completionCallbacks.delete(sessionId);
    }

    // Global callbacks
    for (const cb of this.globalCompletionCallbacks) {
      try {
        cb(result);
      } catch (err) {
        const structured = categorizeError(err, { sessionId, callbackType: 'global' });
        logger.error('Global subagent completion callback error', {
          code: LogErrorCodes.SUB_ERROR,
          category: LogErrorCategory.SUBAGENT,
          sessionId,
          error: structured.message,
          retryable: structured.retryable,
        });
      }
    }
  }

  /**
   * Resolve waiting promises for a session.
   */
  private resolveWaitingPromises(sessionId: SessionId, result: SubagentResult): void {
    const waiters = this.waitingPromises.get(sessionId);
    if (waiters) {
      for (const waiter of waiters) {
        if (waiter.timeoutId) clearTimeout(waiter.timeoutId);
        waiter.resolve(result);
      }
      this.waitingPromises.delete(sessionId);
    }
  }

  /**
   * Clear all tracked sub-agents (for context clear/compact)
   */
  clear(): void {
    this.subagents.clear();
    // Note: We don't clear pendingResults - they should still be delivered
    // But we do clear waiting promises since they're tied to cleared sessions
    for (const waiters of this.waitingPromises.values()) {
      for (const waiter of waiters) {
        if (waiter.timeoutId) clearTimeout(waiter.timeoutId);
        waiter.reject(new Error('Sub-agent tracking cleared'));
      }
    }
    this.waitingPromises.clear();
  }

  /**
   * Reconstruct sub-agent tracker state from event history.
   *
   * This is the key method for supporting:
   * - Session resume: Replay events to rebuild state
   * - Fork: Events include parent ancestry, state is inherited
   *
   * @param events - Array of events in chronological order
   * @returns New SubAgentTracker with reconstructed state
   */
  static fromEvents(events: SubagentTrackingEvent[]): SubAgentTracker {
    const tracker = new SubAgentTracker();

    for (const event of events) {
      switch (event.type) {
        case 'subagent.spawned': {
          const payload = event.payload as {
            subagentSessionId: string;
            spawnType: SubagentSpawnType;
            task: string;
            model: string;
            workingDirectory: string;
            tmuxSessionName?: string;
            maxTurns?: number;
          };
          tracker.spawn(
            payload.subagentSessionId as SessionId,
            payload.spawnType,
            payload.task,
            payload.model,
            payload.workingDirectory,
            event.id,
            {
              tmuxSessionName: payload.tmuxSessionName,
              maxTurns: payload.maxTurns,
              startedAt: event.timestamp,
            }
          );
          // Mark as running after spawn
          tracker.updateStatus(payload.subagentSessionId as SessionId, 'running');
          break;
        }
        case 'subagent.status_update': {
          const payload = event.payload as {
            subagentSessionId: string;
            status: SubagentStatus;
            currentTurn: number;
            tokenUsage?: TokenUsage;
          };
          tracker.updateStatus(
            payload.subagentSessionId as SessionId,
            payload.status,
            {
              currentTurn: payload.currentTurn,
              tokenUsage: payload.tokenUsage,
            }
          );
          break;
        }
        case 'subagent.completed': {
          const payload = event.payload as {
            subagentSessionId: string;
            resultSummary: string;
            totalTurns: number;
            totalTokenUsage: TokenUsage;
            duration: number;
          };
          tracker.complete(
            payload.subagentSessionId as SessionId,
            payload.resultSummary,
            payload.totalTurns,
            payload.totalTokenUsage,
            payload.duration
          );
          break;
        }
        case 'subagent.failed': {
          const payload = event.payload as {
            subagentSessionId: string;
            error: string;
            failedAtTurn?: number;
            duration?: number;
          };
          tracker.fail(
            payload.subagentSessionId as SessionId,
            payload.error,
            {
              failedAtTurn: payload.failedAtTurn,
              duration: payload.duration,
            }
          );
          break;
        }
        case 'context.cleared':
        case 'compact.boundary':
          // Both clear and compact reset sub-agent tracking
          tracker.clear();
          break;
        // Other event types are ignored
      }
    }

    return tracker;
  }
}

/**
 * Create a new empty SubAgentTracker
 */
export function createSubAgentTracker(): SubAgentTracker {
  return new SubAgentTracker();
}
