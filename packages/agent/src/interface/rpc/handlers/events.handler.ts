/**
 * @fileoverview Events RPC Handlers
 *
 * Handlers for events.* RPC methods:
 * - events.getHistory: Get event history for a session
 * - events.getSince: Get events since a timestamp or event ID
 * - events.append: Append a new event to a session
 *
 * Validation is handled by the registry via requiredParams/requiredManagers options.
 */

import type { MethodRegistration, MethodHandler } from '../registry.js';

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
// Handler Factory
// =============================================================================

/**
 * Create events handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createEventsHandlers(): MethodRegistration[] {
  const getHistoryHandler: MethodHandler<EventsGetHistoryParams> = async (request, context) => {
    const params = request.params!;
    return context.eventStore!.getEventHistory(params.sessionId, {
      types: params.types,
      limit: params.limit,
      beforeEventId: params.beforeEventId,
    });
  };

  const getSinceHandler: MethodHandler<EventsGetSinceParams> = async (request, context) => {
    const params = request.params ?? {};
    return context.eventStore!.getEventsSince({
      sessionId: params.sessionId,
      workspaceId: params.workspaceId,
      afterEventId: params.afterEventId,
      afterTimestamp: params.afterTimestamp,
      limit: params.limit,
    });
  };

  const appendHandler: MethodHandler<EventsAppendParams> = async (request, context) => {
    const params = request.params!;
    return context.eventStore!.appendEvent(
      params.sessionId,
      params.type,
      params.payload,
      params.parentId
    );
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
