/**
 * @fileoverview Worktree domain - Git worktree operations
 *
 * Handles worktree status, commits, merges, and listing.
 *
 * @migration Re-exports from rpc/handlers during transition
 */

// Re-export handlers
export {
  handleWorktreeGetStatus,
  handleWorktreeCommit,
  handleWorktreeMerge,
  handleWorktreeList,
  createWorktreeHandlers,
} from '../../../../rpc/handlers/worktree.handler.js';

// Re-export types
export type {
  WorktreeGetStatusParams,
  WorktreeGetStatusResult,
  WorktreeCommitParams,
  WorktreeCommitResult,
  WorktreeMergeParams,
  WorktreeMergeResult,
  WorktreeListParams,
  WorktreeListResult,
} from '../../../../rpc/types/worktree.js';
