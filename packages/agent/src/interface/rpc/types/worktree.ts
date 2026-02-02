/**
 * @fileoverview Worktree RPC Types
 *
 * Types for git worktree operations methods.
 */

// =============================================================================
// Worktree Methods
// =============================================================================

/**
 * Worktree information returned by worktree operations
 */
export interface WorktreeInfoRpc {
  /** Whether this session uses an isolated worktree */
  isolated: boolean;
  /** Git branch name */
  branch: string;
  /** Base commit hash when worktree was created */
  baseCommit: string;
  /** Filesystem path to the working directory */
  path: string;
  /** Whether there are uncommitted changes */
  hasUncommittedChanges?: boolean;
  /** Number of commits since base */
  commitCount?: number;
}

/** Get worktree status for a session */
export interface WorktreeGetStatusParams {
  sessionId: string;
}

export interface WorktreeGetStatusResult {
  /** Session has a worktree */
  hasWorktree: boolean;
  /** Worktree info if available */
  worktree?: WorktreeInfoRpc;
}

/** Commit changes in a session's worktree */
export interface WorktreeCommitParams {
  sessionId: string;
  /** Commit message */
  message: string;
}

export interface WorktreeCommitResult {
  success: boolean;
  /** Commit hash if successful */
  commitHash?: string;
  /** Files that were changed */
  filesChanged?: string[];
  /** Error message if failed */
  error?: string;
}

/** Merge a session's worktree to a target branch */
export interface WorktreeMergeParams {
  sessionId: string;
  /** Target branch to merge into */
  targetBranch: string;
  /** Merge strategy */
  strategy?: 'merge' | 'rebase' | 'squash';
}

export interface WorktreeMergeResult {
  success: boolean;
  /** Merge commit hash if successful */
  mergeCommit?: string;
  /** Conflicting files if merge failed due to conflicts */
  conflicts?: string[];
  /** Error message if failed */
  error?: string;
}

/** List all worktrees */
export interface WorktreeListParams {}

export interface WorktreeListResult {
  worktrees: Array<{
    path: string;
    branch: string;
    sessionId?: string;
  }>;
}
