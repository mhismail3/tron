/**
 * @fileoverview Tool domain - Tool result handling
 *
 * Handles tool execution results from external sources.
 *
 * @migration Re-exports from rpc/handlers during transition
 */

// Re-export handlers
export {
  handleToolResult,
  createToolHandlers,
} from '../../../../rpc/handlers/tool.handler.js';

// Re-export types
export type {
  ToolResultParams,
  ToolResultResult,
} from '../../../../rpc/types/tool-result.js';
