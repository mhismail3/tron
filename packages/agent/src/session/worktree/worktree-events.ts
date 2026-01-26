/**
 * @fileoverview Worktree Events
 *
 * Handles event emission for worktree operations.
 * Extracted from WorktreeCoordinator for modularity and testability.
 */

import type { SessionId } from '../../events/types.js';
import type { MergeStrategy } from './types.js';

// =============================================================================
// Types
// =============================================================================

/**
 * Event store interface (minimal for dependency injection).
 */
export interface EventStoreInterface {
  append(sessionId: SessionId, type: string, payload: unknown): Promise<string>;
}

/**
 * Dependencies for WorktreeEvents.
 */
export interface WorktreeEventsDeps {
  eventStore: EventStoreInterface;
}

/**
 * Payload for worktree acquired event.
 */
export interface WorktreeAcquiredPayload {
  path: string;
  branch: string;
  baseCommit: string;
  isolated: boolean;
  forkedFrom?: {
    sessionId: SessionId;
    commit: string;
  };
}

/**
 * Payload for worktree released event.
 */
export interface WorktreeReleasedPayload {
  path: string;
  branch: string;
  finalCommit?: string;
  branchDeleted?: boolean;
  worktreeDeleted?: boolean;
}

/**
 * Payload for worktree commit event.
 */
export interface WorktreeCommitPayload {
  hash: string;
  message: string;
  filesChanged?: string[];
  insertions?: number;
  deletions?: number;
}

/**
 * Payload for worktree merged event.
 */
export interface WorktreeMergedPayload {
  success: boolean;
  strategy: MergeStrategy;
  targetBranch: string;
  sourceBranch: string;
  commitHash?: string;
  conflicts?: string[];
}

// =============================================================================
// WorktreeEvents
// =============================================================================

/**
 * Handles event emission for worktree operations.
 */
export class WorktreeEvents {
  private eventStore: EventStoreInterface;

  constructor(deps: WorktreeEventsDeps) {
    this.eventStore = deps.eventStore;
  }

  /**
   * Emit worktree.acquired event.
   */
  async emitAcquired(sessionId: SessionId, payload: WorktreeAcquiredPayload): Promise<void> {
    await this.eventStore.append(sessionId, 'worktree.acquired', payload);
  }

  /**
   * Emit worktree.released event.
   */
  async emitReleased(sessionId: SessionId, payload: WorktreeReleasedPayload): Promise<void> {
    await this.eventStore.append(sessionId, 'worktree.released', {
      path: payload.path,
      branch: payload.branch,
      finalCommit: payload.finalCommit,
      deleted: payload.worktreeDeleted ?? false,
      branchPreserved: !payload.branchDeleted,
      branchDeleted: payload.branchDeleted,
      worktreeDeleted: payload.worktreeDeleted,
    });
  }

  /**
   * Emit worktree.commit event.
   */
  async emitCommit(sessionId: SessionId, payload: WorktreeCommitPayload): Promise<void> {
    await this.eventStore.append(sessionId, 'worktree.commit', {
      commitHash: payload.hash,
      message: payload.message,
      hash: payload.hash,
      filesChanged: payload.filesChanged ?? [],
      insertions: payload.insertions,
      deletions: payload.deletions,
    });
  }

  /**
   * Emit worktree.merged event.
   */
  async emitMerged(sessionId: SessionId, payload: WorktreeMergedPayload): Promise<void> {
    await this.eventStore.append(sessionId, 'worktree.merged', {
      success: payload.success,
      strategy: payload.strategy,
      targetBranch: payload.targetBranch,
      sourceBranch: payload.sourceBranch,
      commitHash: payload.commitHash,
      mergeCommit: payload.commitHash,
      conflicts: payload.conflicts,
    });
  }
}

// =============================================================================
// Factory
// =============================================================================

/**
 * Create a WorktreeEvents instance.
 */
export function createWorktreeEvents(deps: WorktreeEventsDeps): WorktreeEvents {
  return new WorktreeEvents(deps);
}
