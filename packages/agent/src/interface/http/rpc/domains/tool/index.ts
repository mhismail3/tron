/**
 * @fileoverview Tool domain - Tool result handling
 *
 * Handles tool execution results from external sources.
 */

// Re-export handler factory
export { createToolHandlers } from '@interface/rpc/handlers/tool.handler.js';

// Re-export types
export type {
  ToolResultParams,
  ToolResultResult,
} from '@interface/rpc/types/tool-result.js';
