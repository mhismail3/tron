/**
 * @fileoverview Tool RPC Handlers
 *
 * Handlers for tool.* RPC methods:
 * - tool.result: Submit a result for a pending tool call
 *
 * Validation is handled by the registry via requiredParams/requiredManagers options.
 */

import type { ToolResultParams } from '../types.js';
import type { MethodRegistration, MethodHandler } from '../registry.js';
import { RpcError, RpcErrorCode } from './base.js';

/**
 * Tool call not found error
 */
class ToolCallNotFoundError extends RpcError {
  constructor(toolCallId: string) {
    super('NOT_FOUND' as typeof RpcErrorCode[keyof typeof RpcErrorCode], `No pending tool call found with ID: ${toolCallId}`);
  }
}

/**
 * Tool result failed error
 */
class ToolResultFailedError extends RpcError {
  constructor() {
    super('TOOL_RESULT_FAILED' as typeof RpcErrorCode[keyof typeof RpcErrorCode], 'Failed to resolve tool call');
  }
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
  const resultHandler: MethodHandler<ToolResultParams> = async (request, context) => {
    const params = request.params!;

    // Check if the tool call is pending
    if (!context.toolCallTracker!.hasPending(params.toolCallId)) {
      throw new ToolCallNotFoundError(params.toolCallId);
    }

    // Resolve the pending tool call
    const resolved = context.toolCallTracker!.resolve(params.toolCallId, params.result);

    if (!resolved) {
      throw new ToolResultFailedError();
    }

    return {
      success: true,
      toolCallId: params.toolCallId,
    };
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
