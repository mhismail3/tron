/**
 * @fileoverview RPC Handlers Module
 *
 * Exports handler utilities and handler implementations.
 * Individual handler modules will be added as they are extracted.
 */

// Base utilities
export {
  extractParams,
  extractRequiredParams,
  requireManager,
  withErrorHandling,
  createHandler,
  ErrorCodes,
  notFoundError,
  type TypedHandler,
  type ParamsOf,
  type CreateHandlerOptions,
} from './base.js';

// Handler implementations
export {
  handleSystemPing,
  handleSystemGetInfo,
  createSystemHandlers,
} from './system.handler.js';
