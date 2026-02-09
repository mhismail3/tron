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
      throw new RpcError(RpcErrorCode.NOT_FOUND, `No pending tool call found with ID: ${params.toolCallId}`);
    }

    // Resolve the pending tool call
    const resolved = context.toolCallTracker!.resolve(params.toolCallId, params.result);

    if (!resolved) {
      throw new RpcError(RpcErrorCode.TOOL_RESULT_FAILED, 'Failed to resolve tool call');
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
