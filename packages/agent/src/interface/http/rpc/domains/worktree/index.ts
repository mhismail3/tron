/**
 * @fileoverview Worktree domain - Git worktree operations
 *
 * Handles worktree status, commits, merges, and listing.
 */

// Re-export handler factory
export { createWorktreeHandlers } from '@interface/rpc/handlers/worktree.handler.js';

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
} from '@interface/rpc/types/worktree.js';
