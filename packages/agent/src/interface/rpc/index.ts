/**
 * @fileoverview RPC module exports
 *
 * This module provides the RPC infrastructure for handling JSON-RPC requests.
 * The architecture is being refactored to use a registry-based approach:
 *
 * - handler.ts: Main RpcHandler class (being migrated to use registry)
 * - registry.ts: Method registration and dispatch system
 * - handlers/: Individual handler implementations by namespace
 * - middleware/: Cross-cutting concerns (logging, validation, etc.)
 */

// Types
export * from './types.js';

// Handler (legacy, being migrated)
export {
  RpcHandler,
  type RpcContext,
  type RpcMiddleware,
  type EventStoreManager,
  type WorktreeRpcManager,
  type ContextRpcManager,
  type BrowserRpcManager,
  type SkillRpcManager,
  type ToolCallTrackerManager,
  type CanvasRpcManager,
  type TodoRpcManager,
  type RpcTodoItem,
  type RpcBackloggedTask,
  type DeviceTokenRpcManager,
  type RpcDeviceToken,
  type SandboxRpcManager,
} from './handler.js';

// Registry (new approach)
export {
  MethodRegistry,
  type MethodHandler,
  type MethodOptions,
  type MethodRegistration,
  type HandlerContext,
} from './registry.js';

// Handler utilities
export {
  extractParams,
  extractRequiredParams,
  requireManager,
  createHandler,
  withErrorHandling,
  notFoundError,
  type TypedHandler,
  type ParamsOf,
  type CreateHandlerOptions,
} from './handlers/index.js';

// Middleware utilities
export {
  buildMiddlewareChain,
  createTimingMiddleware,
  createLoggingMiddleware,
  createErrorBoundaryMiddleware,
  type Middleware,
  type MiddlewareNext,
  type MiddlewareFactory,
  type MiddlewareChainOptions,
} from './middleware/index.js';
