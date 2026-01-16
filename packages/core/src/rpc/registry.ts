/**
 * @fileoverview RPC Method Registry
 *
 * Provides a registration system for RPC method handlers with:
 * - Method registration with options (required params, required managers)
 * - Validation before dispatch
 * - Middleware support for cross-cutting concerns
 * - Response helpers for consistent formatting
 * - Namespace-based organization
 *
 * This module is designed to gradually replace the monolithic switch
 * statement in RpcHandler.dispatch() with a more maintainable registry.
 */

import type { RpcRequest, RpcResponse } from './types.js';
import type { RpcContext } from './handler.js';
import { buildMiddlewareChain, type Middleware, type MiddlewareNext } from './middleware/index.js';

// =============================================================================
// Types
// =============================================================================

/**
 * Handler context is the RpcContext with potential optional managers
 */
export type HandlerContext = RpcContext;

/**
 * Method handler function signature
 *
 * @param request - The incoming RPC request
 * @param context - The handler context with managers
 * @returns The result to be wrapped in a success response
 */
export type MethodHandler<TParams = unknown, TResult = unknown> = (
  request: RpcRequest & { params?: TParams },
  context: HandlerContext
) => Promise<TResult>;

/**
 * Options for method registration
 */
export interface MethodOptions {
  /** Required parameter names that must be present in request.params */
  requiredParams?: string[];
  /** Required manager names that must be present in context */
  requiredManagers?: (keyof RpcContext)[];
  /** Allow overwriting existing registration */
  force?: boolean;
  /** Optional description for documentation */
  description?: string;
}

/**
 * Full registration record for a method
 */
export interface MethodRegistration {
  method: string;
  handler: MethodHandler;
  options?: MethodOptions;
}

/**
 * Internal storage format
 */
interface RegistrationEntry {
  handler: MethodHandler;
  options?: MethodOptions;
}

// =============================================================================
// Registry Implementation
// =============================================================================

/**
 * Registry for RPC method handlers
 *
 * Manages method registration, validation, and dispatch. Designed to work
 * alongside the existing RpcHandler during the migration period.
 *
 * @example
 * ```typescript
 * const registry = new MethodRegistry();
 *
 * // Register a simple handler
 * registry.register('system.ping', async () => ({ pong: true }));
 *
 * // Register with validation options
 * registry.register('session.create', handleSessionCreate, {
 *   requiredParams: ['workingDirectory'],
 *   requiredManagers: ['sessionManager'],
 * });
 *
 * // Dispatch a request
 * const response = await registry.dispatch(request, context);
 * ```
 */
export class MethodRegistry {
  private readonly handlers: Map<string, RegistrationEntry> = new Map();
  private readonly middleware: Middleware[] = [];

  // ===========================================================================
  // Registration
  // ===========================================================================

  /**
   * Register a method handler
   *
   * @param method - The method name (e.g., 'system.ping')
   * @param handler - The handler function
   * @param options - Optional registration options
   * @throws If method is already registered (unless force: true)
   */
  register(method: string, handler: MethodHandler, options?: MethodOptions): void {
    if (this.handlers.has(method) && !options?.force) {
      throw new Error(`Method "${method}" is already registered`);
    }

    this.handlers.set(method, { handler, options });
  }

  /**
   * Register multiple methods at once
   *
   * @param registrations - Array of method registrations
   */
  registerAll(registrations: MethodRegistration[]): void {
    for (const { method, handler, options } of registrations) {
      this.register(method, handler, options);
    }
  }

  /**
   * Unregister a method
   *
   * @param method - The method name to unregister
   * @returns true if the method was registered, false otherwise
   */
  unregister(method: string): boolean {
    return this.handlers.delete(method);
  }

  /**
   * Clear all registrations
   */
  clear(): void {
    this.handlers.clear();
  }

  // ===========================================================================
  // Middleware
  // ===========================================================================

  /**
   * Register middleware to be executed on every request
   *
   * Middleware are executed in the order they are registered.
   * Each middleware can:
   * - Modify the request before passing to the next middleware
   * - Short-circuit and return a response without calling next
   * - Modify the response after next completes
   * - Handle errors from subsequent middleware/handlers
   *
   * @param mw - The middleware function
   */
  use(mw: Middleware): void {
    this.middleware.push(mw);
  }

  /**
   * Get the number of registered middleware
   */
  get middlewareCount(): number {
    return this.middleware.length;
  }

  // ===========================================================================
  // Lookup
  // ===========================================================================

  /**
   * Check if a method is registered
   */
  has(method: string): boolean {
    return this.handlers.has(method);
  }

  /**
   * Get registration details for a method
   */
  get(method: string): RegistrationEntry | undefined {
    return this.handlers.get(method);
  }

  /**
   * List all registered methods
   */
  list(): string[] {
    return Array.from(this.handlers.keys());
  }

  /**
   * List methods by namespace prefix
   *
   * @param namespace - The namespace prefix (e.g., 'system', 'session')
   */
  listByNamespace(namespace: string): string[] {
    const prefix = `${namespace}.`;
    return Array.from(this.handlers.keys()).filter((m) => m.startsWith(prefix));
  }

  /**
   * Get all unique namespaces
   */
  get namespaces(): string[] {
    const ns = new Set<string>();
    for (const method of this.handlers.keys()) {
      const dot = method.indexOf('.');
      if (dot > 0) {
        ns.add(method.slice(0, dot));
      }
    }
    return Array.from(ns);
  }

  /**
   * Get the number of registered methods
   */
  get size(): number {
    return this.handlers.size;
  }

  // ===========================================================================
  // Dispatch
  // ===========================================================================

  /**
   * Dispatch a request to the appropriate handler
   *
   * If middleware are registered, they are executed in order before the handler.
   * The middleware chain wraps the core dispatch logic.
   *
   * @param request - The incoming RPC request
   * @param context - The handler context
   * @returns The RPC response
   */
  async dispatch(request: RpcRequest, context: HandlerContext): Promise<RpcResponse> {
    // Core handler logic
    const coreHandler: MiddlewareNext = (req) => this.dispatchCore(req, context);

    // If no middleware, dispatch directly
    if (this.middleware.length === 0) {
      return coreHandler(request);
    }

    // Build middleware chain and execute
    const chain = buildMiddlewareChain(this.middleware, coreHandler);
    return chain(request);
  }

  /**
   * Core dispatch logic without middleware
   *
   * @internal
   */
  private async dispatchCore(request: RpcRequest, context: HandlerContext): Promise<RpcResponse> {
    const entry = this.handlers.get(request.method);

    // Method not found
    if (!entry) {
      return MethodRegistry.errorResponse(
        request.id,
        'METHOD_NOT_FOUND',
        `Unknown method: ${request.method}`
      );
    }

    const { handler, options } = entry;

    // Validate required params
    if (options?.requiredParams?.length) {
      const params = request.params as Record<string, unknown> | undefined;
      for (const param of options.requiredParams) {
        if (!params || params[param] === undefined) {
          return MethodRegistry.errorResponse(
            request.id,
            'INVALID_PARAMS',
            `${param} is required`
          );
        }
      }
    }

    // Validate required managers
    if (options?.requiredManagers?.length) {
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

    // Execute handler
    try {
      const result = await handler(request, context);
      return MethodRegistry.successResponse(request.id, result);
    } catch (error) {
      // Preserve error code if provided by handler, otherwise use INTERNAL_ERROR
      const errorCode = (error as { code?: string })?.code || 'INTERNAL_ERROR';
      return MethodRegistry.errorResponse(
        request.id,
        errorCode,
        error instanceof Error ? error.message : 'Unknown error'
      );
    }
  }

  // ===========================================================================
  // Response Helpers (static for use without registry instance)
  // ===========================================================================

  /**
   * Create a success response
   */
  static successResponse(id: string | number, result: unknown): RpcResponse {
    return {
      id: String(id),
      success: true,
      result,
    };
  }

  /**
   * Create an error response
   */
  static errorResponse(
    id: string | number,
    code: string,
    message: string,
    details?: unknown
  ): RpcResponse {
    return {
      id: String(id),
      success: false,
      error: {
        code,
        message,
        ...(details !== undefined ? { details } : {}),
      },
    };
  }
}
