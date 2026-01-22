/**
 * @fileoverview Session module exports
 *
 * Session management is event-sourced via the events module.
 * This module provides:
 * - WorktreeCoordinator: Orchestrates session ↔ worktree lifecycle
 * - WorkingDirectory: Abstraction for session's working directory
 * - WorktreeManager: Low-level git worktree operations (legacy, use Coordinator)
 * - TmuxManager: Terminal multiplexer integration for agent sessions
 */

export * from './types.js';

// Tmux integration
export {
  TmuxManager,
  createTmuxManager,
  type TmuxManagerConfig,
  type TmuxSession,
  type TmuxWindow,
  type TmuxPane,
  type SpawnOptions,
  type SendKeysOptions,
} from './tmux-manager.js';

// New event-integrated worktree system
export {
  WorktreeCoordinator,
  createWorktreeCoordinator,
  type WorktreeCoordinatorConfig,
  type AcquireOptions,
  type ReleaseOptions,
} from './worktree-coordinator.js';

export {
  WorkingDirectory,
  createWorkingDirectory,
  type WorkingDirectoryInfo,
  type FileModification,
  type GitStatus,
  type CommitResult,
} from './working-directory.js';

// Legacy worktree manager (for standalone use without event store)
export {
  WorktreeManager,
  createWorktreeManager,
  type WorktreeManagerConfig,
  type Worktree,
  type WorktreeStatus,
} from './worktree.js';
