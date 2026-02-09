/**
 * @fileoverview Session module exports
 *
 * Session management is event-sourced via the events module.
 * This module provides:
 * - WorktreeCoordinator: Orchestrates session ↔ worktree lifecycle
 * - WorkingDirectory: Abstraction for session's working directory
 * - GitExecutor: Low-level git command execution (canonical implementation)
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

// Worktree system (recommended)
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

// Git command execution (canonical implementation)
export {
  GitExecutor,
  createGitExecutor,
} from './worktree/git-executor.js';

