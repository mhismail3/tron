/**
 * @fileoverview Message RPC Handlers
 *
 * Handlers for message.* RPC methods:
 * - message.delete: Delete a message from a session
 */

import { RpcHandlerError } from '../../utils/index.js';
import type {
  RpcRequest,
  RpcResponse,
  MessageDeleteParams,
  MessageDeleteResult,
} from '../types.js';
import type { RpcContext } from '../context-types.js';
import { MethodRegistry, type MethodRegistration, type MethodHandler } from '../registry.js';

// =============================================================================
// Handler Implementations
// =============================================================================

/**
 * Handle message.delete request
 *
 * Deletes a message from a session by creating a deletion event.
 */
export async function handleMessageDelete(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  const params = request.params as MessageDeleteParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }

  if (!params?.targetEventId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'targetEventId is required');
  }

  if (!context.eventStore) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Event store not available');
  }

  try {
    const deletionEvent = await context.eventStore.deleteMessage(
      params.sessionId,
      params.targetEventId,
      params.reason
    );

    const result: MessageDeleteResult = {
      success: true,
      deletionEventId: deletionEvent.id,
      targetType: (deletionEvent.payload as { targetType: 'message.user' | 'message.assistant' | 'tool.result' }).targetType,
    };

    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    if (error instanceof Error) {
      if (error.message.includes('not found')) {
        return MethodRegistry.errorResponse(request.id, 'NOT_FOUND', error.message);
      }
      if (error.message.includes('Cannot delete')) {
        return MethodRegistry.errorResponse(request.id, 'INVALID_OPERATION', error.message);
      }
    }
    const message = error instanceof Error ? error.message : 'Failed to delete message';
    return MethodRegistry.errorResponse(request.id, 'MESSAGE_DELETE_FAILED', message);
  }
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create message handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createMessageHandlers(): MethodRegistration[] {
  const deleteHandler: MethodHandler = async (request, context) => {
    const response = await handleMessageDelete(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    throw RpcHandlerError.fromResponse(response);
  };

  return [
    {
      method: 'message.delete',
      handler: deleteHandler,
      options: {
        requiredParams: ['sessionId', 'targetEventId'],
        requiredManagers: ['eventStore'],
        description: 'Delete a message from a session',
      },
    },
  ];
}
