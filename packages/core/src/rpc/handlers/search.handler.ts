/**
 * @fileoverview Search RPC Handlers
 *
 * Handlers for search.* RPC methods:
 * - search.content: Search content in events
 * - search.events: Search events (alias for search.content)
 */

import type { RpcRequest, RpcResponse } from '../types.js';
import type { RpcContext } from '../handler.js';
import { MethodRegistry, type MethodRegistration, type MethodHandler } from '../registry.js';

// =============================================================================
// Types
// =============================================================================

interface SearchParams {
  query: string;
  sessionId?: string;
  workspaceId?: string;
  types?: string[];
  limit?: number;
}

// =============================================================================
// Handler Implementations
// =============================================================================

/**
 * Handle search.content request
 *
 * Searches content within events.
 */
export async function handleSearchContent(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.eventStore) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'EventStore not available');
  }

  const params = request.params as SearchParams | undefined;

  if (!params?.query) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'query is required');
  }

  const result = await context.eventStore.searchContent(params.query, {
    sessionId: params.sessionId,
    workspaceId: params.workspaceId,
    types: params.types,
    limit: params.limit,
  });

  return MethodRegistry.successResponse(request.id, result);
}

/**
 * Handle search.events request
 *
 * Searches events (alias for search.content).
 */
export async function handleSearchEvents(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.eventStore) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'EventStore not available');
  }

  const params = request.params as SearchParams | undefined;

  if (!params?.query) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'query is required');
  }

  const result = await context.eventStore.searchContent(params.query, {
    sessionId: params.sessionId,
    workspaceId: params.workspaceId,
    types: params.types,
    limit: params.limit,
  });

  return MethodRegistry.successResponse(request.id, result);
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create search handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createSearchHandlers(): MethodRegistration[] {
  const contentHandler: MethodHandler = async (request, context) => {
    const response = await handleSearchContent(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const eventsHandler: MethodHandler = async (request, context) => {
    const response = await handleSearchEvents(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  return [
    {
      method: 'search.content',
      handler: contentHandler,
      options: {
        requiredParams: ['query'],
        requiredManagers: ['eventStore'],
        description: 'Search content in events',
      },
    },
    {
      method: 'search.events',
      handler: eventsHandler,
      options: {
        requiredParams: ['query'],
        requiredManagers: ['eventStore'],
        description: 'Search events',
      },
    },
  ];
}
