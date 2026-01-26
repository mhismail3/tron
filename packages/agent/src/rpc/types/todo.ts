/**
 * @fileoverview Todo RPC Types
 *
 * Types for todo list methods.
 */

// =============================================================================
// Todo Types
// =============================================================================

export interface TodoListParams {
  sessionId: string;
}

export interface TodoListResult {
  todos: RpcTodoItemResult[];
  summary: string;
}

export interface RpcTodoItemResult {
  id: string;
  content: string;
  activeForm: string;
  status: 'pending' | 'in_progress' | 'completed';
  source: 'agent' | 'user' | 'skill';
  createdAt: string;
  completedAt?: string;
  metadata?: Record<string, unknown>;
}

export interface TodoGetBacklogParams {
  workspaceId: string;
  includeRestored?: boolean;
  limit?: number;
}

export interface TodoGetBacklogResult {
  tasks: RpcBackloggedTaskResult[];
  totalCount: number;
}

export interface RpcBackloggedTaskResult extends RpcTodoItemResult {
  backloggedAt: string;
  backlogReason: 'session_clear' | 'context_compact' | 'session_end';
  sourceSessionId: string;
  workspaceId: string;
  restoredToSessionId?: string;
  restoredAt?: string;
}

export interface TodoRestoreParams {
  sessionId: string;
  taskIds: string[];
}

export interface TodoRestoreResult {
  restoredTodos: RpcTodoItemResult[];
  restoredCount: number;
}

export interface TodoGetBacklogCountParams {
  workspaceId: string;
}

export interface TodoGetBacklogCountResult {
  count: number;
}
