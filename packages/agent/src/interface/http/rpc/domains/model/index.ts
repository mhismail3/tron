/**
 * @fileoverview Model domain - Model selection and switching
 *
 * Handles model listing and switching.
 */

// Re-export handler factory
export { createModelHandlers } from '@interface/rpc/handlers/model.handler.js';

// Re-export types
export type {
  ModelSwitchParams,
  ModelSwitchResult,
  ModelListParams,
  ModelListResult,
} from '@interface/rpc/types/model.js';
