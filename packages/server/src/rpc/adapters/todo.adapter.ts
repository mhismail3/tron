/**
 * @fileoverview Todo Adapter
 *
 * Adapts todo operations from the orchestrator to the TodoRpcManager interface.
 * Provides access to session task lists, todo summaries, and backlog operations.
 */

import type { TodoRpcManager, RpcTodoItem, RpcBackloggedTask } from '@tron/core';
import type { AdapterDependencies } from '../types.js';

// =============================================================================
// Todo Adapter Factory
// =============================================================================

/**
 * Creates a todo manager adapter for RPC operations
 *
 * @param deps - Adapter dependencies including the orchestrator
 * @returns TodoRpcManager implementation
 */
export function createTodoAdapter(deps: AdapterDependencies): TodoRpcManager {
  const { orchestrator } = deps;

  return {
    /**
     * Get todos for a session
     */
    getTodos(sessionId: string): RpcTodoItem[] {
      const todos = orchestrator.getTodos(sessionId);
      return todos.map(todo => ({
        id: todo.id,
        content: todo.content,
        activeForm: todo.activeForm,
        status: todo.status,
        source: todo.source,
        createdAt: todo.createdAt,
        completedAt: todo.completedAt,
        metadata: todo.metadata,
      }));
    },

    /**
     * Get todo summary string for a session
     */
    getTodoSummary(sessionId: string): string {
      return orchestrator.getTodoSummary(sessionId);
    },

    /**
     * Get backlogged tasks for a workspace
     */
    getBacklog(workspaceId: string, options?: { includeRestored?: boolean; limit?: number }): RpcBackloggedTask[] {
      const tasks = orchestrator.getBacklog(workspaceId, options);
      return tasks.map(task => ({
        id: task.id,
        content: task.content,
        activeForm: task.activeForm,
        status: task.status,
        source: task.source,
        createdAt: task.createdAt,
        completedAt: task.completedAt,
        metadata: task.metadata,
        backloggedAt: task.backloggedAt,
        backlogReason: task.backlogReason,
        sourceSessionId: task.sourceSessionId,
        workspaceId: task.workspaceId,
        restoredToSessionId: task.restoredToSessionId,
        restoredAt: task.restoredAt,
      }));
    },

    /**
     * Restore tasks from backlog to a session
     */
    async restoreFromBacklog(sessionId: string, taskIds: string[]): Promise<RpcTodoItem[]> {
      const todos = await orchestrator.restoreFromBacklog(sessionId, taskIds);
      return todos.map(todo => ({
        id: todo.id,
        content: todo.content,
        activeForm: todo.activeForm,
        status: todo.status,
        source: todo.source,
        createdAt: todo.createdAt,
        completedAt: todo.completedAt,
        metadata: todo.metadata,
      }));
    },

    /**
     * Get count of unrestored backlogged tasks for a workspace
     */
    getBacklogCount(workspaceId: string): number {
      return orchestrator.getBacklogCount(workspaceId);
    },
  };
}
