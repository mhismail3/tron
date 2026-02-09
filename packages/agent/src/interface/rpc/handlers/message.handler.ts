/**
 * @fileoverview Message RPC Handlers
 *
 * Handlers for message.* RPC methods:
 * - message.delete: Delete a message from a session
 *
 * Validation is handled by the registry via requiredParams/requiredManagers options.
 */

import type {
  MessageDeleteParams,
  MessageDeleteResult,
} from '../types.js';
import type { MethodRegistration, MethodHandler } from '../registry.js';
import { RpcError, RpcErrorCode } from './base.js';
import { hasErrorCode } from '@core/utils/errors.js';

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create message handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createMessageHandlers(): MethodRegistration[] {
  const deleteHandler: MethodHandler<MessageDeleteParams> = async (request, context) => {
    const params = request.params!;

    try {
      const deletionEvent = await context.eventStore!.deleteMessage(
        params.sessionId,
        params.targetEventId,
        params.reason
      );

      const result: MessageDeleteResult = {
        success: true,
        deletionEventId: deletionEvent.id,
        targetType: (deletionEvent.payload as { targetType: 'message.user' | 'message.assistant' | 'tool.result' }).targetType,
      };
      return result;
    } catch (error) {
      if (hasErrorCode(error, 'EVENT_NOT_FOUND') || hasErrorCode(error, 'SESSION_NOT_FOUND')) {
        throw new RpcError(RpcErrorCode.NOT_FOUND, (error as Error).message);
      }
      if (hasErrorCode(error, 'INVALID_OPERATION')) {
        throw new RpcError(RpcErrorCode.INVALID_OPERATION, (error as Error).message);
      }
      const message = error instanceof Error ? error.message : 'Failed to delete message';
      throw new RpcError(RpcErrorCode.MESSAGE_ERROR, message);
    }
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
