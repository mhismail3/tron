/**
 * @fileoverview Todo RPC Handlers
 *
 * Handlers for todo.* RPC methods:
 * - todo.list: Get todos for a session
 * - todo.getSummary: Get todo summary string for a session
 * - todo.getBacklog: Get backlogged tasks for a workspace
 * - todo.restore: Restore tasks from backlog to a session
 * - todo.getBacklogCount: Get count of unrestored backlogged tasks
 */

import type { RpcRequest, RpcResponse } from '../types.js';
import type { RpcContext } from '../handler.js';
import { MethodRegistry, type MethodRegistration, type MethodHandler } from '../registry.js';

// =============================================================================
// Handler Implementations
// =============================================================================

/**
 * Handle todo.list request
 *
 * Gets the current todo list for a session.
 */
export async function handleTodoList(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.todoManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Todo manager not available');
  }

  const params = request.params as { sessionId?: string } | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }

  try {
    const todos = context.todoManager.getTodos(params.sessionId);
    const summary = context.todoManager.getTodoSummary(params.sessionId);
    return MethodRegistry.successResponse(request.id, { todos, summary });
  } catch (error) {
    if (error instanceof Error && error.message.includes('not active')) {
      return MethodRegistry.errorResponse(request.id, 'SESSION_NOT_ACTIVE', 'Session is not active');
    }
    throw error;
  }
}

/**
 * Handle todo.getSummary request
 *
 * Gets the todo summary string for a session.
 */
export async function handleTodoGetSummary(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.todoManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Todo manager not available');
  }

  const params = request.params as { sessionId?: string } | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }

  try {
    const summary = context.todoManager.getTodoSummary(params.sessionId);
    return MethodRegistry.successResponse(request.id, { summary });
  } catch (error) {
    if (error instanceof Error && error.message.includes('not active')) {
      return MethodRegistry.errorResponse(request.id, 'SESSION_NOT_ACTIVE', 'Session is not active');
    }
    throw error;
  }
}

/**
 * Handle todo.getBacklog request
 *
 * Gets backlogged tasks for a workspace.
 */
export async function handleTodoGetBacklog(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.todoManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Todo manager not available');
  }

  const params = request.params as {
    workspaceId?: string;
    includeRestored?: boolean;
    limit?: number;
  } | undefined;

  if (!params?.workspaceId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'workspaceId is required');
  }

  try {
    const tasks = context.todoManager.getBacklog(params.workspaceId, {
      includeRestored: params.includeRestored,
      limit: params.limit,
    });
    return MethodRegistry.successResponse(request.id, {
      tasks,
      totalCount: tasks.length,
    });
  } catch (error) {
    throw error;
  }
}

/**
 * Handle todo.restore request
 *
 * Restores tasks from backlog to a session.
 */
export async function handleTodoRestore(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.todoManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Todo manager not available');
  }

  const params = request.params as {
    sessionId?: string;
    taskIds?: string[];
  } | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }
  if (!params?.taskIds || !Array.isArray(params.taskIds) || params.taskIds.length === 0) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'taskIds is required and must be a non-empty array');
  }

  try {
    const restoredTodos = await context.todoManager.restoreFromBacklog(params.sessionId, params.taskIds);
    return MethodRegistry.successResponse(request.id, {
      restoredTodos,
      restoredCount: restoredTodos.length,
    });
  } catch (error) {
    if (error instanceof Error && error.message.includes('not active')) {
      return MethodRegistry.errorResponse(request.id, 'SESSION_NOT_ACTIVE', 'Session is not active');
    }
    throw error;
  }
}

/**
 * Handle todo.getBacklogCount request
 *
 * Gets count of unrestored backlogged tasks for a workspace.
 */
export async function handleTodoGetBacklogCount(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.todoManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Todo manager not available');
  }

  const params = request.params as { workspaceId?: string } | undefined;

  if (!params?.workspaceId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'workspaceId is required');
  }

  try {
    const count = context.todoManager.getBacklogCount(params.workspaceId);
    return MethodRegistry.successResponse(request.id, { count });
  } catch (error) {
    throw error;
  }
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create todo handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createTodoHandlers(): MethodRegistration[] {
  const listHandler: MethodHandler = async (request, context) => {
    const response = await handleTodoList(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const getSummaryHandler: MethodHandler = async (request, context) => {
    const response = await handleTodoGetSummary(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const getBacklogHandler: MethodHandler = async (request, context) => {
    const response = await handleTodoGetBacklog(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const restoreHandler: MethodHandler = async (request, context) => {
    const response = await handleTodoRestore(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const getBacklogCountHandler: MethodHandler = async (request, context) => {
    const response = await handleTodoGetBacklogCount(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  return [
    {
      method: 'todo.list',
      handler: listHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['todoManager'],
        description: 'Get todos for a session',
      },
    },
    {
      method: 'todo.getSummary',
      handler: getSummaryHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['todoManager'],
        description: 'Get todo summary string for a session',
      },
    },
    {
      method: 'todo.getBacklog',
      handler: getBacklogHandler,
      options: {
        requiredParams: ['workspaceId'],
        requiredManagers: ['todoManager'],
        description: 'Get backlogged tasks for a workspace',
      },
    },
    {
      method: 'todo.restore',
      handler: restoreHandler,
      options: {
        requiredParams: ['sessionId', 'taskIds'],
        requiredManagers: ['todoManager'],
        description: 'Restore tasks from backlog to a session',
      },
    },
    {
      method: 'todo.getBacklogCount',
      handler: getBacklogCountHandler,
      options: {
        requiredParams: ['workspaceId'],
        requiredManagers: ['todoManager'],
        description: 'Get count of unrestored backlogged tasks',
      },
    },
  ];
}
