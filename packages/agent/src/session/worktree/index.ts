/**
 * @fileoverview Worktree Module Exports
 *
 * This module provides git worktree management functionality,
 * decomposed into focused handlers for maintainability.
 */

// Types
export * from './types.js';

// Git execution
export {
  GitExecutor,
  createGitExecutor,
} from './git-executor.js';

// Worktree lifecycle
export {
  WorktreeLifecycle,
  createWorktreeLifecycle,
  type WorktreeLifecycleDeps,
  type RemoveWorktreeOptions,
} from './worktree-lifecycle.js';

// Merge operations
export {
  MergeHandler,
  createMergeHandler,
  type MergeHandlerDeps,
} from './merge-handler.js';

// Event emission
export {
  WorktreeEvents,
  createWorktreeEvents,
  type WorktreeEventsDeps,
  type EventStoreInterface,
  type WorktreeAcquiredPayload,
  type WorktreeReleasedPayload,
  type WorktreeCommitPayload,
  type WorktreeMergedPayload,
} from './worktree-events.js';
