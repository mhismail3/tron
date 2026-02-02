/**
 * @fileoverview RPC Handler
 *
 * Processes RPC requests and dispatches to appropriate handlers.
 * Supports middleware for cross-cutting concerns like auth and logging.
 *
 * All method handlers are now registered via the MethodRegistry system.
 * See handlers/ directory for individual handler implementations.
 */
import { EventEmitter } from 'events';
import { createLogger, categorizeError } from '@infrastructure/logging/index.js';
import type { RpcRequest, RpcResponse, RpcEvent, RpcError } from './types.js';

// Import and re-export context types for backward compatibility
export type {
  RpcContext,
  RpcMiddleware,
  ToolCallTrackerManager,
  WorktreeRpcManager,
  ContextRpcManager,
  PlanRpcManager,
  TodoRpcManager,
  RpcTodoItem,
  RpcBackloggedTask,
  EventStoreManager,
  SessionManager,
  SessionInfo,
  AgentManager,
  MemoryStore,
  TranscriptionManager,
  BrowserRpcManager,
  SkillRpcManager,
  CanvasRpcManager,
  DeviceTokenRpcManager,
  RpcDeviceToken,
} from './context-types.js';

import type { RpcContext, RpcMiddleware } from './context-types.js';

const logger = createLogger('rpc');

// =============================================================================
// Handler Implementation
// =============================================================================

import { MethodRegistry } from './registry.js';
import { createSystemHandlers } from './handlers/system.handler.js';
import { createFilesystemHandlers } from './handlers/filesystem.handler.js';
import { createGitHandlers } from './handlers/git.handler.js';
import { createModelHandlers } from './handlers/model.handler.js';
import { createMemoryHandlers } from './handlers/memory.handler.js';
import { createTranscribeHandlers } from './handlers/transcribe.handler.js';
import { createSessionHandlers } from './handlers/session.handler.js';
import { createAgentHandlers } from './handlers/agent.handler.js';
import { createEventsHandlers } from './handlers/events.handler.js';
import { createTreeHandlers } from './handlers/tree.handler.js';
import { createSearchHandlers } from './handlers/search.handler.js';
import { createWorktreeHandlers } from './handlers/worktree.handler.js';
import { createContextHandlers } from './handlers/context.handler.js';
import { createMessageHandlers } from './handlers/message.handler.js';
import { createBrowserHandlers } from './handlers/browser.handler.js';
import { createSkillHandlers } from './handlers/skill.handler.js';
import { createFileHandlers } from './handlers/file.handler.js';
import { createToolHandlers } from './handlers/tool.handler.js';
import { createVoiceNotesHandlers } from './handlers/voiceNotes.handler.js';
import { createCanvasHandlers } from './handlers/canvas.handler.js';
import { createPlanHandlers } from './handlers/plan.handler.js';
import { createTodoHandlers } from './handlers/todo.handler.js';
import { getDeviceHandlers } from './handlers/device.handler.js';

export class RpcHandler extends EventEmitter {
  private context: RpcContext;
  private middleware: RpcMiddleware[] = [];
  private registry: MethodRegistry;

  constructor(context: RpcContext) {
    super();
    this.context = context;

    // Initialize method registry with extracted handlers
    this.registry = new MethodRegistry();
    this.registry.registerAll(createSystemHandlers());
    this.registry.registerAll(createFilesystemHandlers());
    this.registry.registerAll(createGitHandlers());
    this.registry.registerAll(createModelHandlers());
    this.registry.registerAll(createMemoryHandlers());
    this.registry.registerAll(createTranscribeHandlers());
    this.registry.registerAll(createSessionHandlers());
    this.registry.registerAll(createAgentHandlers());
    this.registry.registerAll(createEventsHandlers());
    this.registry.registerAll(createTreeHandlers());
    this.registry.registerAll(createSearchHandlers());
    this.registry.registerAll(createWorktreeHandlers());
    this.registry.registerAll(createContextHandlers());
    this.registry.registerAll(createMessageHandlers());
    this.registry.registerAll(createBrowserHandlers());
    this.registry.registerAll(createSkillHandlers());
    this.registry.registerAll(createFileHandlers());
    this.registry.registerAll(createToolHandlers());
    this.registry.registerAll(createVoiceNotesHandlers());
    this.registry.registerAll(createCanvasHandlers());
    this.registry.registerAll(createPlanHandlers());
    this.registry.registerAll(createTodoHandlers());
    this.registry.registerAll(getDeviceHandlers());

    logger.debug('RPC handler initialized', {
      registeredMethods: this.registry.list(),
    });
  }

  /**
   * Get the method registry (for testing or advanced usage)
   */
  getRegistry(): MethodRegistry {
    return this.registry;
  }

  /**
   * Register middleware
   */
  use(middleware: RpcMiddleware): void {
    this.middleware.push(middleware);
  }

  /**
   * Handle an RPC request
   */
  async handle(request: RpcRequest): Promise<RpcResponse> {
    logger.debug('Handling request', { method: request.method, id: request.id });

    try {
      // Build middleware chain
      const chain = this.buildMiddlewareChain();
      return await chain(request);
    } catch (error) {
      // Top-level error handling with structured categorization
      const structured = categorizeError(error, {
        method: request.method,
        requestId: request.id,
        operation: 'rpc_request',
      });
      logger.error('Request handling error', {
        code: structured.code,
        category: structured.category,
        error: structured.message,
        method: request.method,
        retryable: structured.retryable,
      });
      return this.errorResponse(
        request.id,
        'INTERNAL_ERROR',
        structured.message
      );
    }
  }

  /**
   * Emit an event to all listeners
   */
  emitEvent(event: RpcEvent): boolean {
    return super.emit('event', event);
  }

  /**
   * Add event listener
   */
  on(event: 'event', listener: (event: RpcEvent) => void): this {
    return super.on(event, listener);
  }

  /**
   * Remove event listener
   */
  off(event: 'event', listener: (event: RpcEvent) => void): this {
    return super.off(event, listener);
  }

  // ===========================================================================
  // Private Methods
  // ===========================================================================

  private buildMiddlewareChain(): (req: RpcRequest) => Promise<RpcResponse> {
    // Start with the actual handler
    let chain = (req: RpcRequest) => this.dispatch(req);

    // Wrap with middleware in reverse order
    for (let i = this.middleware.length - 1; i >= 0; i--) {
      const middleware = this.middleware[i];
      if (!middleware) continue;
      const next = chain;
      chain = (req) => middleware(req, next);
    }

    return chain;
  }

  private async dispatch(request: RpcRequest): Promise<RpcResponse> {
    try {
      // All methods are now handled by the registry
      return this.registry.dispatch(request, this.context);
    } catch (error) {
      const structured = categorizeError(error, {
        method: request.method,
        requestId: request.id,
        operation: 'rpc_dispatch',
      });
      logger.error('Handler dispatch error', {
        code: structured.code,
        category: structured.category,
        error: structured.message,
        method: request.method,
        retryable: structured.retryable,
      });
      return this.errorResponse(
        request.id,
        'INTERNAL_ERROR',
        structured.message
      );
    }
  }

  // ===========================================================================
  // Response Helpers
  // ===========================================================================

  private errorResponse(id: string, code: string, message: string, details?: unknown): RpcResponse {
    const error: RpcError = { code, message };
    if (details !== undefined) {
      error.details = details;
    }
    return {
      id,
      success: false,
      error,
    };
  }
}
