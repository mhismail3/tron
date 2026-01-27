/**
 * @fileoverview Events RPC Handlers
 *
 * Handlers for events.* RPC methods:
 * - events.getHistory: Get event history for a session
 * - events.getSince: Get events since a timestamp or event ID
 * - events.append: Append a new event to a session
 */

import type { RpcRequest, RpcResponse } from '../types.js';
import type { RpcContext } from '../context-types.js';
import { MethodRegistry, type MethodRegistration, type MethodHandler } from '../registry.js';

// =============================================================================
// Types
// =============================================================================

interface EventsGetHistoryParams {
  sessionId: string;
  types?: string[];
  limit?: number;
  beforeEventId?: string;
}

interface EventsGetSinceParams {
  sessionId?: string;
  workspaceId?: string;
  afterEventId?: string;
  afterTimestamp?: string;
  limit?: number;
}

interface EventsAppendParams {
  sessionId: string;
  type: string;
  payload: Record<string, unknown>;
  parentId?: string;
}

// =============================================================================
// Handler Implementations
// =============================================================================

/**
 * Handle events.getHistory request
 *
 * Gets event history for a session, optionally filtered by type.
 */
export async function handleEventsGetHistory(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.eventStore) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'EventStore not available');
  }

  const params = request.params as EventsGetHistoryParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }

  const result = await context.eventStore.getEventHistory(params.sessionId, {
    types: params.types,
    limit: params.limit,
    beforeEventId: params.beforeEventId,
  });

  return MethodRegistry.successResponse(request.id, result);
}

/**
 * Handle events.getSince request
 *
 * Gets events since a specific timestamp or event ID.
 */
export async function handleEventsGetSince(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.eventStore) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'EventStore not available');
  }

  const params = (request.params || {}) as EventsGetSinceParams;

  const result = await context.eventStore.getEventsSince({
    sessionId: params.sessionId,
    workspaceId: params.workspaceId,
    afterEventId: params.afterEventId,
    afterTimestamp: params.afterTimestamp,
    limit: params.limit,
  });

  return MethodRegistry.successResponse(request.id, result);
}

/**
 * Handle events.append request
 *
 * Appends a new event to a session.
 */
export async function handleEventsAppend(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.eventStore) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'EventStore not available');
  }

  const params = request.params as EventsAppendParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }
  if (!params?.type) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'type is required');
  }
  if (!params?.payload) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'payload is required');
  }

  const result = await context.eventStore.appendEvent(
    params.sessionId,
    params.type,
    params.payload,
    params.parentId
  );

  return MethodRegistry.successResponse(request.id, result);
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create events handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createEventsHandlers(): MethodRegistration[] {
  const getHistoryHandler: MethodHandler = async (request, context) => {
    const response = await handleEventsGetHistory(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const getSinceHandler: MethodHandler = async (request, context) => {
    const response = await handleEventsGetSince(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const appendHandler: MethodHandler = async (request, context) => {
    const response = await handleEventsAppend(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  return [
    {
      method: 'events.getHistory',
      handler: getHistoryHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['eventStore'],
        description: 'Get event history for a session',
      },
    },
    {
      method: 'events.getSince',
      handler: getSinceHandler,
      options: {
        requiredManagers: ['eventStore'],
        description: 'Get events since a timestamp or event ID',
      },
    },
    {
      method: 'events.append',
      handler: appendHandler,
      options: {
        requiredParams: ['sessionId', 'type', 'payload'],
        requiredManagers: ['eventStore'],
        description: 'Append a new event to a session',
      },
    },
  ];
}
