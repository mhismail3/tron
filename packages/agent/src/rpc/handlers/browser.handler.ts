/**
 * @fileoverview Browser RPC Handlers
 *
 * Handlers for browser.* RPC methods:
 * - browser.startStream: Start browser streaming for a session
 * - browser.stopStream: Stop browser streaming
 * - browser.getStatus: Get browser streaming status
 */

import { createLogger, categorizeError, LogErrorCategory } from '../../logging/index.js';
import type {
  RpcRequest,
  RpcResponse,
  BrowserStartStreamParams,
  BrowserStopStreamParams,
  BrowserGetStatusParams,
} from '../types.js';
import type { RpcContext } from '../handler.js';
import { MethodRegistry, type MethodRegistration, type MethodHandler } from '../registry.js';

const logger = createLogger('rpc:browser');

// =============================================================================
// Handler Implementations
// =============================================================================

/**
 * Handle browser.startStream request
 *
 * Starts browser streaming for a session.
 */
export async function handleBrowserStartStream(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.browserManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Browser manager not available');
  }

  const params = request.params as BrowserStartStreamParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }

  try {
    const result = await context.browserManager.startStream(params);
    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    const structured = categorizeError(error, { sessionId: params.sessionId, operation: 'startStream' });
    logger.error('Failed to start browser stream', {
      sessionId: params.sessionId,
      code: structured.code,
      category: LogErrorCategory.TOOL_EXECUTION,
      error: structured.message,
      retryable: structured.retryable,
    });
    const message = error instanceof Error ? error.message : 'Failed to start browser stream';
    return MethodRegistry.errorResponse(request.id, 'BROWSER_ERROR', message);
  }
}

/**
 * Handle browser.stopStream request
 *
 * Stops browser streaming for a session.
 */
export async function handleBrowserStopStream(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.browserManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Browser manager not available');
  }

  const params = request.params as BrowserStopStreamParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }

  try {
    const result = await context.browserManager.stopStream(params);
    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    const structured = categorizeError(error, { sessionId: params.sessionId, operation: 'stopStream' });
    logger.error('Failed to stop browser stream', {
      sessionId: params.sessionId,
      code: structured.code,
      category: LogErrorCategory.TOOL_EXECUTION,
      error: structured.message,
      retryable: structured.retryable,
    });
    const message = error instanceof Error ? error.message : 'Failed to stop browser stream';
    return MethodRegistry.errorResponse(request.id, 'BROWSER_ERROR', message);
  }
}

/**
 * Handle browser.getStatus request
 *
 * Gets browser streaming status for a session.
 */
export async function handleBrowserGetStatus(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.browserManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Browser manager not available');
  }

  const params = request.params as BrowserGetStatusParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }

  try {
    const result = await context.browserManager.getStatus(params);
    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    const structured = categorizeError(error, { sessionId: params.sessionId, operation: 'getStatus' });
    logger.error('Failed to get browser status', {
      sessionId: params.sessionId,
      code: structured.code,
      category: LogErrorCategory.TOOL_EXECUTION,
      error: structured.message,
      retryable: structured.retryable,
    });
    const message = error instanceof Error ? error.message : 'Failed to get browser status';
    return MethodRegistry.errorResponse(request.id, 'BROWSER_ERROR', message);
  }
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create browser handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createBrowserHandlers(): MethodRegistration[] {
  const startStreamHandler: MethodHandler = async (request, context) => {
    const response = await handleBrowserStartStream(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const stopStreamHandler: MethodHandler = async (request, context) => {
    const response = await handleBrowserStopStream(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const getStatusHandler: MethodHandler = async (request, context) => {
    const response = await handleBrowserGetStatus(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  return [
    {
      method: 'browser.startStream',
      handler: startStreamHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['browserManager'],
        description: 'Start browser streaming for a session',
      },
    },
    {
      method: 'browser.stopStream',
      handler: stopStreamHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['browserManager'],
        description: 'Stop browser streaming',
      },
    },
    {
      method: 'browser.getStatus',
      handler: getStatusHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['browserManager'],
        description: 'Get browser streaming status',
      },
    },
  ];
}
