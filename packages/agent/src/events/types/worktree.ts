/**
 * @fileoverview Worktree Events
 *
 * Events for git worktree operations.
 */

import type { SessionId } from './branded.js';
import type { BaseEvent } from './base.js';

// =============================================================================
// Worktree Events
// =============================================================================

/**
 * Worktree acquired event - session has a working directory
 */
export interface WorktreeAcquiredEvent extends BaseEvent {
  type: 'worktree.acquired';
  payload: {
    /** Filesystem path to working directory */
    path: string;
    /** Git branch name */
    branch: string;
    /** Starting commit hash */
    baseCommit: string;
    /** Whether this is isolated (worktree) or shared (main directory) */
    isolated: boolean;
    /** If forked, the parent session's info */
    forkedFrom?: {
      sessionId: SessionId;
      commit: string;
    };
  };
}

/**
 * Worktree commit event - changes committed in session's worktree
 */
export interface WorktreeCommitEvent extends BaseEvent {
  type: 'worktree.commit';
  payload: {
    /** Git commit hash */
    commitHash: string;
    /** Commit message */
    message: string;
    /** Files changed in this commit */
    filesChanged: string[];
    /** Number of insertions */
    insertions?: number;
    /** Number of deletions */
    deletions?: number;
  };
}

/**
 * Worktree released event - session released its working directory
 */
export interface WorktreeReleasedEvent extends BaseEvent {
  type: 'worktree.released';
  payload: {
    /** Final commit hash (if changes were committed) */
    finalCommit?: string;
    /** Whether worktree was deleted */
    deleted: boolean;
    /** Whether branch was preserved */
    branchPreserved: boolean;
  };
}

/**
 * Worktree merged event - session's branch was merged
 */
export interface WorktreeMergedEvent extends BaseEvent {
  type: 'worktree.merged';
  payload: {
    /** Branch that was merged */
    sourceBranch: string;
    /** Target branch */
    targetBranch: string;
    /** Merge commit hash */
    mergeCommit: string;
    /** Merge strategy used */
    strategy: 'merge' | 'rebase' | 'squash';
  };
}
