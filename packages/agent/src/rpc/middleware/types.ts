/**
 * @fileoverview Middleware Type Definitions
 *
 * Extracted to break circular dependencies between middleware/index.ts,
 * middleware/validation.ts, and registry.ts.
 */

import type { RpcRequest, RpcResponse } from '../types.js';

// =============================================================================
// Core Types
// =============================================================================

/**
 * Next function in the middleware chain
 */
export type MiddlewareNext = (request: RpcRequest) => Promise<RpcResponse>;

/**
 * Middleware function signature
 *
 * Middleware receives the request and a next function to call the rest of
 * the chain. It can:
 * - Modify the request before calling next
 * - Modify the response after next completes
 * - Short-circuit and return a response without calling next
 * - Handle errors from next
 */
export type Middleware = (
  request: RpcRequest,
  next: MiddlewareNext
) => Promise<RpcResponse>;

/**
 * Middleware factory that receives configuration
 */
export type MiddlewareFactory<TConfig = unknown> = (config: TConfig) => Middleware;

// =============================================================================
// Chain Options
// =============================================================================

/**
 * Options for middleware chain
 */
export interface MiddlewareChainOptions {
  /** Error handler for unhandled middleware errors */
  onError?: (error: Error, request: RpcRequest) => RpcResponse;
}
