/**
 * @fileoverview Todo RPC Handlers
 *
 * Handlers for todo.* RPC methods:
 * - todo.list: Get todos for a session
 * - todo.getSummary: Get todo summary string for a session
 * - todo.getBacklog: Get backlogged tasks for a workspace
 * - todo.restore: Restore tasks from backlog to a session
 * - todo.getBacklogCount: Get count of unrestored backlogged tasks
 *
 * Validation is handled by the registry via requiredParams/requiredManagers options.
 */

import { createLogger, categorizeError, LogErrorCategory } from '@infrastructure/logging/index.js';
import type { MethodRegistration, MethodHandler } from '../registry.js';
import { SessionNotActiveError, InvalidParamsError } from './base.js';

const logger = createLogger('rpc:todo');

// =============================================================================
// Types
// =============================================================================

interface TodoListParams {
  sessionId: string;
}

interface TodoGetSummaryParams {
  sessionId: string;
}

interface TodoGetBacklogParams {
  workspaceId: string;
  includeRestored?: boolean;
  limit?: number;
}

interface TodoRestoreParams {
  sessionId: string;
  taskIds: string[];
}

interface TodoGetBacklogCountParams {
  workspaceId: string;
}

/**
 * Wrap operations that may throw "not active" errors
 */
async function withSessionActiveCheck<T>(
  sessionId: string,
  operation: string,
  fn: () => T | Promise<T>
): Promise<T> {
  try {
    return await fn();
  } catch (error) {
    if (error instanceof Error && error.message.includes('not active')) {
      throw new SessionNotActiveError(sessionId);
    }
    const structured = categorizeError(error, { sessionId, operation });
    logger.error(`Failed to ${operation}`, {
      sessionId,
      code: structured.code,
      category: LogErrorCategory.SESSION_STATE,
      error: structured.message,
      retryable: structured.retryable,
    });
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
  const listHandler: MethodHandler<TodoListParams> = async (request, context) => {
    const params = request.params!;
    return withSessionActiveCheck(params.sessionId, 'list todos', () => {
      const todos = context.todoManager!.getTodos(params.sessionId);
      const summary = context.todoManager!.getTodoSummary(params.sessionId);
      return { todos, summary };
    });
  };

  const getSummaryHandler: MethodHandler<TodoGetSummaryParams> = async (request, context) => {
    const params = request.params!;
    return withSessionActiveCheck(params.sessionId, 'get todo summary', () => {
      const summary = context.todoManager!.getTodoSummary(params.sessionId);
      return { summary };
    });
  };

  const getBacklogHandler: MethodHandler<TodoGetBacklogParams> = async (request, context) => {
    const params = request.params!;
    try {
      const tasks = context.todoManager!.getBacklog(params.workspaceId, {
        includeRestored: params.includeRestored,
        limit: params.limit,
      });
      return {
        tasks,
        totalCount: tasks.length,
      };
    } catch (error) {
      const structured = categorizeError(error, { workspaceId: params.workspaceId, operation: 'getBacklog' });
      logger.error('Failed to get backlog', {
        workspaceId: params.workspaceId,
        code: structured.code,
        category: LogErrorCategory.DATABASE,
        error: structured.message,
        retryable: structured.retryable,
      });
      throw error;
    }
  };

  const restoreHandler: MethodHandler<TodoRestoreParams> = async (request, context) => {
    const params = request.params!;

    // Additional validation for array
    if (!Array.isArray(params.taskIds) || params.taskIds.length === 0) {
      throw new InvalidParamsError('taskIds must be a non-empty array');
    }

    return withSessionActiveCheck(params.sessionId, 'restore from backlog', async () => {
      const restoredTodos = await context.todoManager!.restoreFromBacklog(params.sessionId, params.taskIds);
      return {
        restoredTodos,
        restoredCount: restoredTodos.length,
      };
    });
  };

  const getBacklogCountHandler: MethodHandler<TodoGetBacklogCountParams> = async (request, context) => {
    const params = request.params!;
    try {
      const count = context.todoManager!.getBacklogCount(params.workspaceId);
      return { count };
    } catch (error) {
      const structured = categorizeError(error, { workspaceId: params.workspaceId, operation: 'getBacklogCount' });
      logger.error('Failed to get backlog count', {
        workspaceId: params.workspaceId,
        code: structured.code,
        category: LogErrorCategory.DATABASE,
        error: structured.message,
        retryable: structured.retryable,
      });
      throw error;
    }
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
