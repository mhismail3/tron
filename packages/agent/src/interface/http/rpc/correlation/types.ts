/**
 * @fileoverview Run correlation types
 *
 * Types for tracking agent runs through the system.
 */

/**
 * Run status
 */
export type RunStatus = 'pending' | 'running' | 'completed' | 'failed' | 'aborted';

/**
 * Information about an agent run
 */
export interface RunInfo {
  /** Unique run identifier */
  runId: string;
  /** Session this run belongs to */
  sessionId: string;
  /** Client-provided request ID for correlation */
  clientRequestId?: string;
  /** Current status */
  status: RunStatus;
  /** When the run started */
  startedAt: string;
  /** When the run completed (if finished) */
  completedAt?: string;
  /** Result data (if completed) */
  result?: unknown;
  /** Error message (if failed) */
  error?: string;
  /** Number of turns executed */
  turnCount?: number;
  /** Token usage */
  tokenUsage?: {
    input: number;
    output: number;
  };
}

/**
 * Options for querying runs
 */
export interface RunQueryOptions {
  /** Maximum runs to return */
  limit?: number;
  /** Only include runs with these statuses */
  status?: RunStatus[];
  /** Only include runs after this time */
  since?: string;
}

/**
 * Run statistics
 */
export interface RunStats {
  /** Total number of tracked runs */
  totalRuns: number;
  /** Currently active runs */
  activeRuns: number;
  /** Completed runs */
  completedRuns: number;
  /** Failed runs */
  failedRuns: number;
  /** Aborted runs */
  abortedRuns: number;
}

/**
 * Run tracker configuration
 */
export interface RunTrackerConfig {
  /** How long to retain completed runs (ms) - default 24 hours */
  retentionMs?: number;
  /** Maximum runs to store per session - default 100 */
  maxRunsPerSession?: number;
}

/**
 * Default configuration
 */
export const DEFAULT_RUN_TRACKER_CONFIG: Required<RunTrackerConfig> = {
  retentionMs: 24 * 60 * 60 * 1000, // 24 hours
  maxRunsPerSession: 100,
};
