/**
 * @fileoverview Todo domain - Task management
 *
 * Handles todo listing, summaries, backlog, and restoration.
 *
 * @migration Re-exports from rpc/handlers during transition
 */

// Re-export handlers
export {
  handleTodoList,
  handleTodoGetSummary,
  handleTodoGetBacklog,
  handleTodoRestore,
  handleTodoGetBacklogCount,
  createTodoHandlers,
} from '../../../../rpc/handlers/todo.handler.js';

// Re-export types
export type {
  TodoListParams,
  TodoListResult,
  RpcTodoItemResult,
  TodoGetBacklogParams,
  TodoGetBacklogResult,
  RpcBackloggedTaskResult,
  TodoRestoreParams,
  TodoRestoreResult,
  TodoGetBacklogCountParams,
  TodoGetBacklogCountResult,
} from '../../../../rpc/types/todo.js';
