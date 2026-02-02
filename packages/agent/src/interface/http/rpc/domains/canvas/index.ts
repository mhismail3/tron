/**
 * @fileoverview Canvas domain - UI canvas operations
 *
 * Handles canvas retrieval and management.
 *
 * @migration Re-exports from rpc/handlers during transition
 */

// Re-export handlers
export {
  handleCanvasGet,
  createCanvasHandlers,
} from '../../../../rpc/handlers/canvas.handler.js';

// Re-export types
export type {
  CanvasGetParams,
  CanvasGetResult,
} from '../../../../rpc/types/canvas.js';
