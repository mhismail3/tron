/**
 * @fileoverview Worktree RPC Handlers
 *
 * Handlers for worktree.* RPC methods:
 * - worktree.getStatus: Get worktree status for a session
 * - worktree.commit: Commit worktree changes
 * - worktree.merge: Merge worktree to target branch
 * - worktree.list: List all worktrees
 */

import type {
  RpcRequest,
  RpcResponse,
  WorktreeGetStatusParams,
  WorktreeGetStatusResult,
  WorktreeCommitParams,
  WorktreeCommitResult,
  WorktreeMergeParams,
  WorktreeMergeResult,
  WorktreeListResult,
} from '../types.js';
import type { RpcContext } from '../context-types.js';
import { MethodRegistry, type MethodRegistration, type MethodHandler } from '../registry.js';

// =============================================================================
// Handler Implementations
// =============================================================================

/**
 * Handle worktree.getStatus request
 *
 * Gets the worktree status for a session.
 */
export async function handleWorktreeGetStatus(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.worktreeManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Worktree manager not available');
  }

  const params = request.params as WorktreeGetStatusParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }

  const worktree = await context.worktreeManager.getWorktreeStatus(params.sessionId);

  const result: WorktreeGetStatusResult = {
    hasWorktree: worktree !== null,
    worktree: worktree ?? undefined,
  };

  return MethodRegistry.successResponse(request.id, result);
}

/**
 * Handle worktree.commit request
 *
 * Commits worktree changes.
 */
export async function handleWorktreeCommit(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.worktreeManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Worktree manager not available');
  }

  const params = request.params as WorktreeCommitParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }
  if (!params?.message) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'message is required');
  }

  const result: WorktreeCommitResult = await context.worktreeManager.commitWorktree(
    params.sessionId,
    params.message
  );

  return MethodRegistry.successResponse(request.id, result);
}

/**
 * Handle worktree.merge request
 *
 * Merges worktree to target branch.
 */
export async function handleWorktreeMerge(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.worktreeManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Worktree manager not available');
  }

  const params = request.params as WorktreeMergeParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }
  if (!params?.targetBranch) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'targetBranch is required');
  }

  const result: WorktreeMergeResult = await context.worktreeManager.mergeWorktree(
    params.sessionId,
    params.targetBranch,
    params.strategy
  );

  return MethodRegistry.successResponse(request.id, result);
}

/**
 * Handle worktree.list request
 *
 * Lists all worktrees.
 */
export async function handleWorktreeList(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.worktreeManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Worktree manager not available');
  }

  const worktrees = await context.worktreeManager.listWorktrees();

  const result: WorktreeListResult = { worktrees };

  return MethodRegistry.successResponse(request.id, result);
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create worktree handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createWorktreeHandlers(): MethodRegistration[] {
  const getStatusHandler: MethodHandler = async (request, context) => {
    const response = await handleWorktreeGetStatus(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const commitHandler: MethodHandler = async (request, context) => {
    const response = await handleWorktreeCommit(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const mergeHandler: MethodHandler = async (request, context) => {
    const response = await handleWorktreeMerge(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const listHandler: MethodHandler = async (request, context) => {
    const response = await handleWorktreeList(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
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
