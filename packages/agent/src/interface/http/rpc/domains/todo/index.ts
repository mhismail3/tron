/**
 * @fileoverview Todo domain - Task management
 *
 * Handles todo listing, summaries, backlog, and restoration.
 */

// Re-export handler factory
export { createTodoHandlers } from '@interface/rpc/handlers/todo.handler.js';

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
} from '@interface/rpc/types/todo.js';
