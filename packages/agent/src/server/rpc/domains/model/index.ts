/**
 * @fileoverview Model domain - Model selection and switching
 *
 * Handles model listing and switching.
 *
 * @migration Re-exports from rpc/handlers during transition
 */

// Re-export handlers
export {
  handleModelSwitch,
  handleModelList,
  createModelHandlers,
} from '../../../../rpc/handlers/model.handler.js';

// Re-export types
export type {
  ModelSwitchParams,
  ModelSwitchResult,
  ModelListParams,
  ModelListResult,
} from '../../../../rpc/types/model.js';
