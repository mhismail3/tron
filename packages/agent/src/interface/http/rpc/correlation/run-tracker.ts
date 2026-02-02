/**
 * @fileoverview Run ID correlation tracker
 *
 * Tracks agent runs through the system for correlation and debugging.
 */

import { randomUUID } from 'crypto';
import type {
  RunInfo,
  RunStatus,
  RunQueryOptions,
  RunStats,
  RunTrackerConfig,
} from './types.js';
import { DEFAULT_RUN_TRACKER_CONFIG } from './types.js';
import { createLogger } from '@infrastructure/logging/index.js';

const logger = createLogger('run-tracker');

// Re-export types for convenience
export type { RunInfo, RunStatus, RunQueryOptions, RunStats, RunTrackerConfig };

/**
 * Generate a unique run ID
 */
export function generateRunId(): string {
  return `run_${randomUUID().replace(/-/g, '').slice(0, 16)}`;
}

/**
 * Run tracker implementation
 */
export class RunTracker {
  private runs = new Map<string, RunInfo>();
  private sessionRuns = new Map<string, string[]>(); // sessionId -> runIds (in insertion order)
  private currentSessionRuns = new Map<string, string>(); // sessionId -> current runId
  private config: Required<RunTrackerConfig>;
  private insertionOrder = new Map<string, number>(); // runId -> insertion index
  private insertionCounter = 0;

  constructor(config: RunTrackerConfig = {}) {
    this.config = {
      ...DEFAULT_RUN_TRACKER_CONFIG,
      ...config,
    };
  }

  /**
   * Start a new run for a session
   */
  startRun(sessionId: string, clientRequestId?: string): RunInfo {
    const runId = generateRunId();
    const now = new Date().toISOString();

    const runInfo: RunInfo = {
      runId,
      sessionId,
      clientRequestId,
      status: 'pending',
      startedAt: now,
    };

    this.runs.set(runId, runInfo);
    this.insertionOrder.set(runId, this.insertionCounter++);

    // Track by session
    if (!this.sessionRuns.has(sessionId)) {
      this.sessionRuns.set(sessionId, []);
    }
    this.sessionRuns.get(sessionId)!.push(runId);

    // Set as current run for session
    this.currentSessionRuns.set(sessionId, runId);

    // Enforce per-session limit
    this.enforceSessionLimit(sessionId);

    logger.debug('Run started', {
      runId,
      sessionId,
      clientRequestId,
    });

    return runInfo;
  }

  /**
   * Get the current active run for a session
   */
  getCurrentRun(sessionId: string): RunInfo | undefined {
    const runId = this.currentSessionRuns.get(sessionId);
    if (!runId) return undefined;

    const run = this.runs.get(runId);
    if (!run) return undefined;

    // Only return if still active
    if (run.status === 'pending' || run.status === 'running') {
      return run;
    }

    // Clear stale current run reference
    this.currentSessionRuns.delete(sessionId);
    return undefined;
  }

  /**
   * Get run info by ID
   */
  getRun(runId: string): RunInfo | undefined {
    return this.runs.get(runId);
  }

  /**
   * Update run status
   */
  updateRunStatus(runId: string, status: RunStatus): boolean {
    const run = this.runs.get(runId);
    if (!run) return false;

    run.status = status;

    logger.debug('Run status updated', {
      runId,
      status,
    });

    return true;
  }

  /**
   * Mark run as completed
   */
  completeRun(runId: string, result?: unknown): void {
    const run = this.runs.get(runId);
    if (!run) return;

    run.status = 'completed';
    run.completedAt = new Date().toISOString();
    run.result = result;

    // Clear from current if this was the current run
    if (this.currentSessionRuns.get(run.sessionId) === runId) {
      this.currentSessionRuns.delete(run.sessionId);
    }

    logger.debug('Run completed', {
      runId,
      sessionId: run.sessionId,
      duration: Date.now() - new Date(run.startedAt).getTime(),
    });
  }

  /**
   * Mark run as failed
   */
  failRun(runId: string, error: string): void {
    const run = this.runs.get(runId);
    if (!run) return;

    run.status = 'failed';
    run.completedAt = new Date().toISOString();
    run.error = error;

    // Clear from current
    if (this.currentSessionRuns.get(run.sessionId) === runId) {
      this.currentSessionRuns.delete(run.sessionId);
    }

    logger.warn('Run failed', {
      runId,
      sessionId: run.sessionId,
      error,
    });
  }

  /**
   * Mark run as aborted
   */
  abortRun(runId: string): void {
    const run = this.runs.get(runId);
    if (!run) return;

    run.status = 'aborted';
    run.completedAt = new Date().toISOString();

    // Clear from current
    if (this.currentSessionRuns.get(run.sessionId) === runId) {
      this.currentSessionRuns.delete(run.sessionId);
    }

    logger.info('Run aborted', {
      runId,
      sessionId: run.sessionId,
    });
  }

  /**
   * Get runs for a session
   */
  getRunsBySession(sessionId: string, options: RunQueryOptions = {}): RunInfo[] {
    const runIds = this.sessionRuns.get(sessionId) ?? [];
    let runs = runIds
      .map((id) => this.runs.get(id))
      .filter((r): r is RunInfo => r !== undefined);

    // Filter by status
    if (options.status?.length) {
      runs = runs.filter((r) => options.status!.includes(r.status));
    }

    // Filter by time
    if (options.since) {
      runs = runs.filter((r) => r.startedAt >= options.since!);
    }

    // Sort by insertion order descending (newest first)
    // Using insertion order as primary key to handle same-timestamp cases
    runs.sort((a, b) => {
      const orderA = this.insertionOrder.get(a.runId) ?? 0;
      const orderB = this.insertionOrder.get(b.runId) ?? 0;
      return orderB - orderA;
    });

    // Apply limit
    if (options.limit) {
      runs = runs.slice(0, options.limit);
    }

    return runs;
  }

  /**
   * Clean up old completed runs
   */
  cleanup(): void {
    const cutoff = new Date(Date.now() - this.config.retentionMs).toISOString();
    let removed = 0;

    for (const [runId, run] of this.runs) {
      // Only clean up completed/failed/aborted runs past retention
      if (
        run.completedAt &&
        run.completedAt < cutoff &&
        ['completed', 'failed', 'aborted'].includes(run.status)
      ) {
        this.runs.delete(runId);
        this.insertionOrder.delete(runId);

        // Remove from session index
        const sessionRunIds = this.sessionRuns.get(run.sessionId);
        if (sessionRunIds) {
          const index = sessionRunIds.indexOf(runId);
          if (index >= 0) {
            sessionRunIds.splice(index, 1);
          }
        }

        removed++;
      }
    }

    if (removed > 0) {
      logger.debug('Cleaned up old runs', { removed });
    }
  }

  /**
   * Get run statistics
   */
  stats(): RunStats {
    let activeRuns = 0;
    let completedRuns = 0;
    let failedRuns = 0;
    let abortedRuns = 0;

    for (const run of this.runs.values()) {
      switch (run.status) {
        case 'pending':
        case 'running':
          activeRuns++;
          break;
        case 'completed':
          completedRuns++;
          break;
        case 'failed':
          failedRuns++;
          break;
        case 'aborted':
          abortedRuns++;
          break;
      }
    }

    return {
      totalRuns: this.runs.size,
      activeRuns,
      completedRuns,
      failedRuns,
      abortedRuns,
    };
  }

  /**
   * Clear all runs (for testing)
   */
  clear(): void {
    this.runs.clear();
    this.sessionRuns.clear();
    this.currentSessionRuns.clear();
    this.insertionOrder.clear();
    this.insertionCounter = 0;
  }

  // Private helpers

  private enforceSessionLimit(sessionId: string): void {
    const runIds = this.sessionRuns.get(sessionId);
    if (!runIds || runIds.length <= this.config.maxRunsPerSession) {
      return;
    }

    // Get runs sorted by start time
    const runs = runIds
      .map((id) => this.runs.get(id))
      .filter((r): r is RunInfo => r !== undefined)
      .filter((r) => r.status !== 'pending' && r.status !== 'running') // Don't remove active
      .sort((a, b) => a.startedAt.localeCompare(b.startedAt));

    // Remove oldest until under limit
    const toRemove = runIds.length - this.config.maxRunsPerSession;
    for (let i = 0; i < toRemove && i < runs.length; i++) {
      const run = runs[i];
      if (!run) continue; // TypeScript guard - runs are filtered above
      this.runs.delete(run.runId);
      this.insertionOrder.delete(run.runId);
      const idx = runIds.indexOf(run.runId);
      if (idx >= 0) {
        runIds.splice(idx, 1);
      }
    }
  }
}

/**
 * Create a run tracker instance
 */
export function createRunTracker(config?: RunTrackerConfig): RunTracker {
  return new RunTracker(config);
}

/**
 * Singleton instance for global use
 */
let globalTracker: RunTracker | null = null;

/**
 * Get the global run tracker
 */
export function getRunTracker(): RunTracker {
  if (!globalTracker) {
    globalTracker = new RunTracker();
  }
  return globalTracker;
}

/**
 * Reset the global run tracker (for testing)
 */
export function resetRunTracker(): void {
  globalTracker = null;
}
