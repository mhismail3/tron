/**
 * @fileoverview RPC Middleware Types and Utilities
 *
 * Defines the middleware interface and provides utilities for
 * building middleware chains. Middleware can intercept requests
 * and responses for cross-cutting concerns like logging, validation,
 * and error handling.
 */

import type { RpcRequest, RpcResponse } from '../types.js';

// =============================================================================
// Types
// =============================================================================

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
 * Next function in the middleware chain
 */
export type MiddlewareNext = (request: RpcRequest) => Promise<RpcResponse>;

/**
 * Middleware factory that receives configuration
 */
export type MiddlewareFactory<TConfig = unknown> = (config: TConfig) => Middleware;

// =============================================================================
// Middleware Builder
// =============================================================================

/**
 * Options for middleware chain
 */
export interface MiddlewareChainOptions {
  /** Error handler for unhandled middleware errors */
  onError?: (error: Error, request: RpcRequest) => RpcResponse;
}

/**
 * Build a middleware chain from an array of middleware
 *
 * Middleware are executed in order: first middleware wraps second, etc.
 * The final handler is wrapped by all middleware.
 *
 * @param middleware - Array of middleware functions
 * @param handler - The final request handler
 * @param options - Chain options
 * @returns A function that processes requests through the full chain
 */
export function buildMiddlewareChain(
  middleware: Middleware[],
  handler: MiddlewareNext,
  options?: MiddlewareChainOptions
): MiddlewareNext {
  // Start with the handler
  let chain: MiddlewareNext = handler;

  // Wrap with middleware in reverse order (so first middleware executes first)
  for (let i = middleware.length - 1; i >= 0; i--) {
    const mw = middleware[i];
    if (!mw) continue;
    const next = chain;
    chain = (request) => mw(request, next);
  }

  // Wrap with error handling if provided
  if (options?.onError) {
    const innerChain = chain;
    chain = async (request) => {
      try {
        return await innerChain(request);
      } catch (error) {
        return options.onError!(error instanceof Error ? error : new Error(String(error)), request);
      }
    };
  }

  return chain;
}

// =============================================================================
// Common Middleware Patterns
// =============================================================================

/**
 * Create a timing middleware that adds execution time to response
 *
 * @param logger - Optional logging function
 */
export function createTimingMiddleware(
  logger?: (method: string, durationMs: number) => void
): Middleware {
  return async (request, next) => {
    const start = Date.now();
    const response = await next(request);
    const duration = Date.now() - start;

    if (logger) {
      logger(request.method, duration);
    }

    return response;
  };
}

/**
 * Create a logging middleware
 *
 * @param log - Logging function
 */
export function createLoggingMiddleware(
  log: (level: 'debug' | 'info' | 'warn' | 'error', message: string, data?: unknown) => void
): Middleware {
  return async (request, next) => {
    log('debug', `RPC request: ${request.method}`, { id: request.id });

    try {
      const response = await next(request);

      if (response.error) {
        log('warn', `RPC error: ${request.method}`, {
          id: request.id,
          error: response.error,
        });
      } else {
        log('debug', `RPC success: ${request.method}`, { id: request.id });
      }

      return response;
    } catch (error) {
      log('error', `RPC exception: ${request.method}`, {
        id: request.id,
        error: error instanceof Error ? error.message : String(error),
      });
      throw error;
    }
  };
}

/**
 * Create an error boundary middleware that catches and formats errors
 *
 * @param formatError - Function to format errors into RpcResponse
 */
export function createErrorBoundaryMiddleware(
  formatError: (error: Error, requestId: string | number) => RpcResponse
): Middleware {
  return async (request, next) => {
    try {
      return await next(request);
    } catch (error) {
      return formatError(
        error instanceof Error ? error : new Error(String(error)),
        request.id
      );
    }
  };
}

// =============================================================================
// Re-exports
// =============================================================================

export {
  createValidationMiddleware,
  createSchemaRegistry,
  mergeSchemaRegistries,
  zodErrorToValidationErrors,
  formatValidationMessage,
  commonSchemas,
  type SchemaRegistry,
  type ValidationResult,
  type ValidationError,
  type ValidationMiddlewareOptions,
} from './validation.js';
