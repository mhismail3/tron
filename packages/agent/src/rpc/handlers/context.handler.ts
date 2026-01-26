/**
 * @fileoverview Context RPC Handlers
 *
 * Handlers for context.* RPC methods:
 * - context.getSnapshot: Get context snapshot for a session
 * - context.getDetailedSnapshot: Get detailed context snapshot
 * - context.shouldCompact: Check if session should compact
 * - context.previewCompaction: Preview compaction result
 * - context.confirmCompaction: Confirm and execute compaction
 * - context.canAcceptTurn: Check if session can accept a turn
 * - context.clear: Clear session context
 */

import { createLogger, categorizeError, LogErrorCategory } from '../../logging/index.js';
import type {
  RpcRequest,
  RpcResponse,
  ContextGetSnapshotParams,
  ContextGetDetailedSnapshotParams,
  ContextShouldCompactParams,
  ContextShouldCompactResult,
  ContextPreviewCompactionParams,
  ContextConfirmCompactionParams,
  ContextCanAcceptTurnParams,
  ContextClearParams,
} from '../types.js';
import type { RpcContext } from '../handler.js';
import { MethodRegistry, type MethodRegistration, type MethodHandler } from '../registry.js';

const logger = createLogger('rpc:context');

// =============================================================================
// Handler Implementations
// =============================================================================

/**
 * Handle context.getSnapshot request
 *
 * Gets a snapshot of the context for a session.
 */
export async function handleContextGetSnapshot(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.contextManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Context manager not available');
  }

  const params = request.params as ContextGetSnapshotParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }

  try {
    const result = context.contextManager.getContextSnapshot(params.sessionId);
    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    if (error instanceof Error && error.message.includes('not active')) {
      return MethodRegistry.errorResponse(request.id, 'SESSION_NOT_ACTIVE', 'Session is not active');
    }
    const structured = categorizeError(error, { sessionId: params.sessionId, operation: 'getSnapshot' });
    logger.error('Failed to get context snapshot', {
      sessionId: params.sessionId,
      code: structured.code,
      category: structured.category,
      error: structured.message,
      retryable: structured.retryable,
    });
    throw error;
  }
}

/**
 * Handle context.getDetailedSnapshot request
 *
 * Gets a detailed snapshot of the context for a session.
 */
export async function handleContextGetDetailedSnapshot(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.contextManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Context manager not available');
  }

  const params = request.params as ContextGetDetailedSnapshotParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }

  try {
    const result = context.contextManager.getDetailedContextSnapshot(params.sessionId);
    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    if (error instanceof Error && error.message.includes('not active')) {
      return MethodRegistry.errorResponse(request.id, 'SESSION_NOT_ACTIVE', 'Session is not active');
    }
    const structured = categorizeError(error, { sessionId: params.sessionId, operation: 'getDetailedSnapshot' });
    logger.error('Failed to get detailed context snapshot', {
      sessionId: params.sessionId,
      code: structured.code,
      category: structured.category,
      error: structured.message,
      retryable: structured.retryable,
    });
    throw error;
  }
}

/**
 * Handle context.shouldCompact request
 *
 * Checks if a session should be compacted.
 */
export async function handleContextShouldCompact(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.contextManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Context manager not available');
  }

  const params = request.params as ContextShouldCompactParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }

  try {
    const shouldCompact = context.contextManager.shouldCompact(params.sessionId);
    const result: ContextShouldCompactResult = { shouldCompact };
    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    if (error instanceof Error && error.message.includes('not active')) {
      return MethodRegistry.errorResponse(request.id, 'SESSION_NOT_ACTIVE', 'Session is not active');
    }
    const structured = categorizeError(error, { sessionId: params.sessionId, operation: 'shouldCompact' });
    logger.error('Failed to check if session should compact', {
      sessionId: params.sessionId,
      code: structured.code,
      category: structured.category,
      error: structured.message,
      retryable: structured.retryable,
    });
    throw error;
  }
}

/**
 * Handle context.previewCompaction request
 *
 * Previews the compaction result for a session.
 */
export async function handleContextPreviewCompaction(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.contextManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Context manager not available');
  }

  const params = request.params as ContextPreviewCompactionParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }

  try {
    const result = await context.contextManager.previewCompaction(params.sessionId);
    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    if (error instanceof Error && error.message.includes('not active')) {
      return MethodRegistry.errorResponse(request.id, 'SESSION_NOT_ACTIVE', 'Session is not active');
    }
    const structured = categorizeError(error, { sessionId: params.sessionId, operation: 'previewCompaction' });
    logger.error('Failed to preview compaction', {
      sessionId: params.sessionId,
      code: structured.code,
      category: structured.category,
      error: structured.message,
      retryable: structured.retryable,
    });
    throw error;
  }
}

/**
 * Handle context.confirmCompaction request
 *
 * Confirms and executes compaction for a session.
 */
export async function handleContextConfirmCompaction(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.contextManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Context manager not available');
  }

  const params = request.params as ContextConfirmCompactionParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }

  try {
    const result = await context.contextManager.confirmCompaction(
      params.sessionId,
      { editedSummary: params.editedSummary }
    );
    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    if (error instanceof Error && error.message.includes('not active')) {
      return MethodRegistry.errorResponse(request.id, 'SESSION_NOT_ACTIVE', 'Session is not active');
    }
    const structured = categorizeError(error, { sessionId: params.sessionId, operation: 'confirmCompaction' });
    logger.error('Failed to confirm compaction', {
      sessionId: params.sessionId,
      code: structured.code,
      category: LogErrorCategory.COMPACTION,
      error: structured.message,
      retryable: structured.retryable,
    });
    throw error;
  }
}

/**
 * Handle context.canAcceptTurn request
 *
 * Checks if a session can accept another turn.
 */
export async function handleContextCanAcceptTurn(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.contextManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Context manager not available');
  }

  const params = request.params as ContextCanAcceptTurnParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }
  if (params.estimatedResponseTokens === undefined) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'estimatedResponseTokens is required');
  }

  try {
    const result = context.contextManager.canAcceptTurn(
      params.sessionId,
      { estimatedResponseTokens: params.estimatedResponseTokens }
    );
    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    if (error instanceof Error && error.message.includes('not active')) {
      return MethodRegistry.errorResponse(request.id, 'SESSION_NOT_ACTIVE', 'Session is not active');
    }
    const structured = categorizeError(error, { sessionId: params.sessionId, operation: 'canAcceptTurn' });
    logger.error('Failed to check if session can accept turn', {
      sessionId: params.sessionId,
      code: structured.code,
      category: LogErrorCategory.TOKEN_LIMIT,
      error: structured.message,
      retryable: structured.retryable,
    });
    throw error;
  }
}

/**
 * Handle context.clear request
 *
 * Clears the context for a session.
 */
export async function handleContextClear(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.contextManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Context manager not available');
  }

  const params = request.params as ContextClearParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }

  try {
    const result = await context.contextManager.clearContext(params.sessionId);
    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    if (error instanceof Error && error.message.includes('not active')) {
      return MethodRegistry.errorResponse(request.id, 'SESSION_NOT_ACTIVE', 'Session is not active');
    }
    const structured = categorizeError(error, { sessionId: params.sessionId, operation: 'clear' });
    logger.error('Failed to clear context', {
      sessionId: params.sessionId,
      code: structured.code,
      category: structured.category,
      error: structured.message,
      retryable: structured.retryable,
    });
    throw error;
  }
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create context handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createContextHandlers(): MethodRegistration[] {
  const getSnapshotHandler: MethodHandler = async (request, context) => {
    const response = await handleContextGetSnapshot(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const getDetailedSnapshotHandler: MethodHandler = async (request, context) => {
    const response = await handleContextGetDetailedSnapshot(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const shouldCompactHandler: MethodHandler = async (request, context) => {
    const response = await handleContextShouldCompact(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const previewCompactionHandler: MethodHandler = async (request, context) => {
    const response = await handleContextPreviewCompaction(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const confirmCompactionHandler: MethodHandler = async (request, context) => {
    const response = await handleContextConfirmCompaction(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const canAcceptTurnHandler: MethodHandler = async (request, context) => {
    const response = await handleContextCanAcceptTurn(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const clearHandler: MethodHandler = async (request, context) => {
    const response = await handleContextClear(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  return [
    {
      method: 'context.getSnapshot',
      handler: getSnapshotHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['contextManager'],
        description: 'Get context snapshot for a session',
      },
    },
    {
      method: 'context.getDetailedSnapshot',
      handler: getDetailedSnapshotHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['contextManager'],
        description: 'Get detailed context snapshot',
      },
    },
    {
      method: 'context.shouldCompact',
      handler: shouldCompactHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['contextManager'],
        description: 'Check if session should compact',
      },
    },
    {
      method: 'context.previewCompaction',
      handler: previewCompactionHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['contextManager'],
        description: 'Preview compaction result',
      },
    },
    {
      method: 'context.confirmCompaction',
      handler: confirmCompactionHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['contextManager'],
        description: 'Confirm and execute compaction',
      },
    },
    {
      method: 'context.canAcceptTurn',
      handler: canAcceptTurnHandler,
      options: {
        requiredParams: ['sessionId', 'estimatedResponseTokens'],
        requiredManagers: ['contextManager'],
        description: 'Check if session can accept a turn',
      },
    },
    {
      method: 'context.clear',
      handler: clearHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['contextManager'],
        description: 'Clear session context',
      },
    },
    // Legacy alias for context.confirmCompaction
    {
      method: 'context.compact',
      handler: confirmCompactionHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['contextManager'],
        description: 'Confirm and execute compaction (legacy alias)',
      },
    },
  ];
}
