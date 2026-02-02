/**
 * @fileoverview Base Handler Utilities
 *
 * Shared utilities for RPC method handlers. Provides common patterns
 * for parameter extraction, error handling, and response formatting.
 *
 * These utilities are designed to reduce boilerplate in individual handlers
 * while maintaining type safety.
 */

import type { RpcRequest, RpcResponse } from '../types.js';
import type { RpcContext } from '../context-types.js';
import { MethodRegistry } from '../registry.js';
import { RpcErrorCode, isRpcError } from '@core/errors/rpc-errors.js';

// Re-export error types for handler convenience
export { RpcErrorCode, isRpcError } from '@core/errors/rpc-errors.js';
export {
  RpcError,
  SessionNotFoundError,
  SessionNotActiveError,
  ManagerNotAvailableError,
  InvalidParamsError,
  FileNotFoundError,
  InternalError,
} from '@core/errors/rpc-errors.js';

// =============================================================================
// Types
// =============================================================================

/**
 * Type-safe parameter extractor
 */
export type ParamsOf<T> = T extends { params?: infer P } ? P : unknown;

/**
 * Handler function with typed params
 */
export type TypedHandler<TParams, TResult> = (
  params: TParams,
  context: RpcContext,
  request: RpcRequest
) => Promise<TResult>;

// =============================================================================
// Parameter Extraction
// =============================================================================

/**
 * Extract and cast params from request
 *
 * @param request - The RPC request
 * @returns The params object (may be undefined)
 */
export function extractParams<T>(request: RpcRequest): T | undefined {
  return request.params as T | undefined;
}

/**
 * Extract params with required field validation
 *
 * @param request - The RPC request
 * @param requiredFields - Field names that must be present
 * @returns Success with params or error response
 */
export function extractRequiredParams<T extends Record<string, unknown>>(
  request: RpcRequest,
  requiredFields: (keyof T)[]
): { success: true; params: T } | { success: false; response: RpcResponse } {
  const params = request.params as T | undefined;

  for (const field of requiredFields) {
    if (!params || params[field] === undefined) {
      return {
        success: false,
        response: MethodRegistry.errorResponse(
          request.id,
          'INVALID_PARAMS',
          `${String(field)} is required`
        ),
      };
    }
  }

  return { success: true, params: params as T };
}

// =============================================================================
// Manager Access
// =============================================================================

/**
 * Get a required manager from context, returning error response if not available
 *
 * @param context - The RPC context
 * @param managerName - The manager to access
 * @param requestId - The request ID for error response
 */
export function requireManager<K extends keyof RpcContext>(
  context: RpcContext,
  managerName: K,
  requestId: string | number
): { success: true; manager: NonNullable<RpcContext[K]> } | { success: false; response: RpcResponse } {
  const manager = context[managerName];
  if (!manager) {
    return {
      success: false,
      response: MethodRegistry.errorResponse(
        requestId,
        'NOT_AVAILABLE',
        `${managerName} is not available`
      ),
    };
  }
  return { success: true, manager: manager as NonNullable<RpcContext[K]> };
}

// =============================================================================
// Error Handling
// =============================================================================

/**
 * Standard error codes (re-exported from core/errors for backwards compatibility)
 * @deprecated Use RpcErrorCode from @core/errors/rpc-errors.js instead
 */
export const ErrorCodes = RpcErrorCode;

/**
 * Create an error response for a "not found" scenario
 */
export function notFoundError(
  requestId: string | number,
  entity: string,
  identifier?: string
): RpcResponse {
  const message = identifier
    ? `${entity} not found: ${identifier}`
    : `${entity} not found`;
  return MethodRegistry.errorResponse(requestId, 'SESSION_NOT_FOUND', message);
}

/**
 * Wrap a handler with try/catch for consistent error handling
 */
export function withErrorHandling<TParams, TResult>(
  handler: TypedHandler<TParams, TResult>
): (params: TParams, context: RpcContext, request: RpcRequest) => Promise<RpcResponse> {
  return async (params, context, request) => {
    try {
      const result = await handler(params, context, request);
      return MethodRegistry.successResponse(request.id, result);
    } catch (error) {
      // Handle typed RPC errors
      if (isRpcError(error)) {
        return MethodRegistry.errorResponse(request.id, error.code, error.message);
      }
      // Handle generic errors
      if (error instanceof Error) {
        return MethodRegistry.errorResponse(request.id, RpcErrorCode.INTERNAL_ERROR, error.message);
      }
      return MethodRegistry.errorResponse(request.id, RpcErrorCode.INTERNAL_ERROR, 'Unknown error');
    }
  };
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Options for creating a handler
 */
export interface CreateHandlerOptions<TParams> {
  /** Required parameter fields */
  requiredParams?: (keyof TParams)[];
  /** Required managers */
  requiredManagers?: (keyof RpcContext)[];
}

/**
 * Create a type-safe handler with built-in validation
 *
 * @example
 * ```typescript
 * const handleSessionCreate = createHandler<SessionCreateParams, SessionCreateResult>(
 *   { requiredParams: ['workingDirectory'], requiredManagers: ['sessionManager'] },
 *   async (params, context) => {
 *     return context.sessionManager.createSession(params);
 *   }
 * );
 * ```
 */
export function createHandler<TParams extends Record<string, unknown>, TResult>(
  options: CreateHandlerOptions<TParams>,
  impl: TypedHandler<TParams, TResult>
): (request: RpcRequest, context: RpcContext) => Promise<RpcResponse> {
  return async (request, context) => {
    // Validate required params
    if (options.requiredParams?.length) {
      const validation = extractRequiredParams<TParams>(
        request,
        options.requiredParams as (keyof TParams)[]
      );
      if (!validation.success) {
        return validation.response;
      }
    }

    // Validate required managers
    if (options.requiredManagers?.length) {
      for (const manager of options.requiredManagers) {
        if (!context[manager]) {
          return MethodRegistry.errorResponse(
            request.id,
            'NOT_AVAILABLE',
            `${manager} is not available`
          );
        }
      }
    }

    const params = (request.params ?? {}) as TParams;

    // Execute with error handling
    try {
      const result = await impl(params, context, request);
      return MethodRegistry.successResponse(request.id, result);
    } catch (error) {
      // Handle typed RPC errors
      if (isRpcError(error)) {
        return MethodRegistry.errorResponse(request.id, error.code, error.message);
      }
      // Handle generic errors
      if (error instanceof Error) {
        return MethodRegistry.errorResponse(request.id, RpcErrorCode.INTERNAL_ERROR, error.message);
      }
      return MethodRegistry.errorResponse(request.id, RpcErrorCode.INTERNAL_ERROR, 'Unknown error');
    }
  };
}
