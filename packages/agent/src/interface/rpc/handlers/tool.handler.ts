/**
 * @fileoverview Tool RPC Handlers
 *
 * Handlers for tool.* RPC methods:
 * - tool.result: Submit a result for a pending tool call
 */

import { RpcHandlerError } from '@core/utils/index.js';
import type {
  RpcRequest,
  RpcResponse,
  ToolResultParams,
} from '../types.js';
import type { RpcContext } from '../context-types.js';
import { MethodRegistry, type MethodRegistration, type MethodHandler } from '../registry.js';

// =============================================================================
// Handler Implementations
// =============================================================================

/**
 * Handle tool.result request
 *
 * Submits a result for a pending tool call.
 */
export async function handleToolResult(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.toolCallTracker) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Tool call tracker not available');
  }

  const params = request.params as ToolResultParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }
  if (!params?.toolCallId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'toolCallId is required');
  }
  if (params.result === undefined) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'result is required');
  }

  // Check if the tool call is pending
  if (!context.toolCallTracker.hasPending(params.toolCallId)) {
    return MethodRegistry.errorResponse(
      request.id,
      'NOT_FOUND',
      `No pending tool call found with ID: ${params.toolCallId}`
    );
  }

  // Resolve the pending tool call
  const resolved = context.toolCallTracker.resolve(params.toolCallId, params.result);

  if (!resolved) {
    return MethodRegistry.errorResponse(
      request.id,
      'TOOL_RESULT_FAILED',
      'Failed to resolve tool call'
    );
  }

  return MethodRegistry.successResponse(request.id, {
    success: true,
    toolCallId: params.toolCallId,
  });
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create tool handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createToolHandlers(): MethodRegistration[] {
  const resultHandler: MethodHandler = async (request, context) => {
    const response = await handleToolResult(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    throw RpcHandlerError.fromResponse(response);
  };

  return [
    {
      method: 'tool.result',
      handler: resultHandler,
      options: {
        requiredParams: ['sessionId', 'toolCallId', 'result'],
        requiredManagers: ['toolCallTracker'],
        description: 'Submit a result for a pending tool call',
      },
    },
  ];
}
