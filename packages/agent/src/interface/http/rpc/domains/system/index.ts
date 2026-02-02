/**
 * @fileoverview System domain - System information and control
 *
 * Handles system ping and info queries.
 */

// Re-export handler factory
export { createSystemHandlers } from '@interface/rpc/handlers/system.handler.js';

// Re-export types
export type {
  SystemPingParams,
  SystemPingResult,
  SystemGetInfoParams,
  SystemGetInfoResult,
} from '@interface/rpc/types/system.js';
