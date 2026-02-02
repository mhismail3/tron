/**
 * @fileoverview Canvas domain - UI canvas operations
 *
 * Handles canvas retrieval and management.
 */

// Re-export handler factory
export { createCanvasHandlers } from '@interface/rpc/handlers/canvas.handler.js';

// Re-export types
export type {
  CanvasGetParams,
  CanvasGetResult,
} from '@interface/rpc/types/canvas.js';
