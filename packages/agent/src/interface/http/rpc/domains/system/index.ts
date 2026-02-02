/**
 * @fileoverview System domain - System information and control
 *
 * Handles system ping and info queries.
 *
 * @migration Re-exports from rpc/handlers during transition
 */

// Re-export handlers
export {
  handleSystemPing,
  handleSystemGetInfo,
  createSystemHandlers,
} from '../../../../rpc/handlers/system.handler.js';

// Re-export types
export type {
  SystemPingParams,
  SystemPingResult,
  SystemGetInfoParams,
  SystemGetInfoResult,
} from '../../../../rpc/types/system.js';
