/**
 * @fileoverview Worktree RPC Handlers
 *
 * Handlers for worktree.* RPC methods:
 * - worktree.getStatus: Get worktree status for a session
 * - worktree.commit: Commit worktree changes
 * - worktree.merge: Merge worktree to target branch
 * - worktree.list: List all worktrees
 *
 * Validation is handled by the registry via requiredParams/requiredManagers options.
 */

import type {
  WorktreeGetStatusParams,
  WorktreeGetStatusResult,
  WorktreeCommitParams,
  WorktreeCommitResult,
  WorktreeMergeParams,
  WorktreeMergeResult,
  WorktreeListResult,
} from '../types.js';
import type { MethodRegistration, MethodHandler } from '../registry.js';

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create worktree handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createWorktreeHandlers(): MethodRegistration[] {
  const getStatusHandler: MethodHandler<WorktreeGetStatusParams> = async (request, context) => {
    const params = request.params!;
    const worktree = await context.worktreeManager!.getWorktreeStatus(params.sessionId);

    const result: WorktreeGetStatusResult = {
      hasWorktree: worktree !== null,
      worktree: worktree ?? undefined,
    };
    return result;
  };

  const commitHandler: MethodHandler<WorktreeCommitParams> = async (request, context) => {
    const params = request.params!;
    const result: WorktreeCommitResult = await context.worktreeManager!.commitWorktree(
      params.sessionId,
      params.message
    );
    return result;
  };

  const mergeHandler: MethodHandler<WorktreeMergeParams> = async (request, context) => {
    const params = request.params!;
    const result: WorktreeMergeResult = await context.worktreeManager!.mergeWorktree(
      params.sessionId,
      params.targetBranch,
      params.strategy
    );
    return result;
  };

  const listHandler: MethodHandler = async (_request, context) => {
    const worktrees = await context.worktreeManager!.listWorktrees();
    const result: WorktreeListResult = { worktrees };
    return result;
  };

  return [
    {
      method: 'worktree.getStatus',
      handler: getStatusHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['worktreeManager'],
        description: 'Get worktree status for a session',
      },
    },
    {
      method: 'worktree.commit',
      handler: commitHandler,
      options: {
        requiredParams: ['sessionId', 'message'],
        requiredManagers: ['worktreeManager'],
        description: 'Commit worktree changes',
      },
    },
    {
      method: 'worktree.merge',
      handler: mergeHandler,
      options: {
        requiredParams: ['sessionId', 'targetBranch'],
        requiredManagers: ['worktreeManager'],
        description: 'Merge worktree to target branch',
      },
    },
    {
      method: 'worktree.list',
      handler: listHandler,
      options: {
        requiredManagers: ['worktreeManager'],
        description: 'List all worktrees',
      },
    },
  ];
}
