/**
 * @fileoverview Shared Types for Worktree Module
 *
 * Defines common interfaces used by worktree handlers.
 * Types are defined here to avoid circular imports.
 *
 * Note: Handler-specific deps interfaces are defined in their respective files
 * (e.g., WorktreeLifecycleDeps in worktree-lifecycle.ts) to keep dependencies
 * close to their usage.
 */

// =============================================================================
// Git Execution Types
// =============================================================================

/**
 * Result of executing a git command.
 */
export interface GitExecResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

/**
 * Options for git command execution.
 */
export interface GitExecOptions {
  timeout?: number;
}

// =============================================================================
// Worktree Types
// =============================================================================

/**
 * Information about a git worktree.
 */
export interface WorktreeInfo {
  path: string;
  branch: string;
  sessionId?: string;
  commit?: string;
}

// =============================================================================
// Merge Types
// =============================================================================

/**
 * Supported merge strategies.
 */
export type MergeStrategy = 'merge' | 'rebase' | 'squash';

/**
 * Result of a merge operation.
 */
export interface MergeResult {
  success: boolean;
  strategy: MergeStrategy;
  commitHash?: string;
  conflicts?: string[];
  error?: string;
}

/**
 * Options for merge operations.
 */
export interface MergeOptions {
  strategy: MergeStrategy;
  commitMessage?: string;
}
