/**
 * @fileoverview WorktreeController
 *
 * Manages git worktree operations for agent sessions. Handles status queries,
 * commits, merges, and listing of worktrees.
 *
 * Part of Phase 3 of EventStoreOrchestrator refactoring.
 */

import type { WorktreeCoordinator } from '@platform/session/worktree-coordinator.js';
import type { SessionId } from '@infrastructure/events/types.js';
import type { WorktreeInfo } from '../types.js';
import type { ActiveSessionStore } from '../session/active-session-store.js';
import {
  buildWorktreeInfoWithStatus,
  commitWorkingDirectory,
} from '../operations/worktree-ops.js';

// =============================================================================
// Types
// =============================================================================

export interface WorktreeControllerConfig {
  worktreeCoordinator: WorktreeCoordinator;
  sessionStore: ActiveSessionStore;
}

export interface CommitResult {
  success: boolean;
  commitHash?: string;
  filesChanged?: string[];
  error?: string;
}

export interface MergeResult {
  success: boolean;
  mergeCommit?: string;
  conflicts?: string[];
}

export type MergeStrategy = 'merge' | 'rebase' | 'squash';

export interface WorktreeListItem {
  path: string;
  branch: string;
  sessionId?: string;
}

// =============================================================================
// WorktreeController
// =============================================================================

/**
 * Controller for git worktree operations.
 *
 * Provides a clean interface for:
 * - Getting worktree status for a session
 * - Committing changes in a session's worktree
 * - Merging a session's worktree to a target branch
 * - Listing all worktrees
 */
export class WorktreeController {
  private readonly worktreeCoordinator: WorktreeCoordinator;
  private readonly sessionStore: ActiveSessionStore;

  constructor(config: WorktreeControllerConfig) {
    this.worktreeCoordinator = config.worktreeCoordinator;
    this.sessionStore = config.sessionStore;
  }

  /**
   * Get worktree status for a session.
   * Returns null if session not found or has no worktree.
   */
  async getStatus(sessionId: string): Promise<WorktreeInfo | null> {
    const active = this.sessionStore.get(sessionId);
    if (!active?.workingDir) {
      return null;
    }

    return buildWorktreeInfoWithStatus(active.workingDir);
  }

  /**
   * Commit changes in a session's worktree.
   */
  async commit(sessionId: string, message: string): Promise<CommitResult> {
    const active = this.sessionStore.get(sessionId);
    if (!active?.workingDir) {
      return { success: false, error: 'Session not found or no worktree' };
    }

    return commitWorkingDirectory(active.workingDir, message);
  }

  /**
   * Merge a session's worktree to a target branch.
   */
  async merge(
    sessionId: string,
    targetBranch: string,
    strategy: MergeStrategy = 'merge'
  ): Promise<MergeResult> {
    return this.worktreeCoordinator.mergeSession(
      sessionId as SessionId,
      targetBranch,
      strategy
    );
  }

  /**
   * List all worktrees.
   */
  async list(): Promise<WorktreeListItem[]> {
    return this.worktreeCoordinator.listWorktrees();
  }

  /**
   * Get the WorktreeCoordinator (for advanced use cases).
   */
  getCoordinator(): WorktreeCoordinator {
    return this.worktreeCoordinator;
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a WorktreeController instance.
 */
export function createWorktreeController(config: WorktreeControllerConfig): WorktreeController {
  return new WorktreeController(config);
}
