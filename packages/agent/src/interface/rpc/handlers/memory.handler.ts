/**
 * @fileoverview Memory RPC Handlers
 *
 * Handlers for memory.* RPC methods:
 * - memory.search: Search memory entries
 * - memory.addEntry: Add a new memory entry
 * - memory.getHandoffs: List session handoffs
 */

import { RpcHandlerError } from '@core/utils/index.js';
import type {
  RpcRequest,
  RpcResponse,
  MemorySearchParams,
  RpcMemorySearchResult,
  MemoryAddEntryParams,
  MemoryAddEntryResult,
  MemoryGetHandoffsParams,
  MemoryGetHandoffsResult,
} from '../types.js';
import type { RpcContext } from '../context-types.js';
import { MethodRegistry, type MethodRegistration, type MethodHandler } from '../registry.js';

// =============================================================================
// Handler Implementations
// =============================================================================

/**
 * Handle memory.search request
 *
 * Searches memory entries based on query parameters.
 */
export async function handleMemorySearch(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  const params = (request.params || {}) as MemorySearchParams;

  const searchResult = await context.memoryStore.searchEntries(params);

  const result: RpcMemorySearchResult = {
    entries: searchResult.entries.map((e: unknown) => {
      const entry = e as Record<string, unknown>;
      return {
        id: entry.id as string,
        type: entry.type as string,
        content: entry.content as string,
        source: entry.source as string,
        relevance: (entry.relevance as number) ?? 1.0,
        timestamp: entry.timestamp as string,
      };
    }),
    totalCount: searchResult.totalCount,
  };

  return MethodRegistry.successResponse(request.id, result);
}

/**
 * Handle memory.addEntry request
 *
 * Adds a new entry to the memory store.
 */
export async function handleMemoryAddEntry(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  const params = request.params as MemoryAddEntryParams | undefined;

  if (!params?.type) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'type is required');
  }
  if (!params?.content) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'content is required');
  }

  const addResult = await context.memoryStore.addEntry(params);

  const result: MemoryAddEntryResult = {
    id: addResult.id,
    created: true,
  };

  return MethodRegistry.successResponse(request.id, result);
}

/**
 * Handle memory.getHandoffs request
 *
 * Lists session handoffs, optionally filtered by working directory.
 */
export async function handleMemoryGetHandoffs(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  const params = (request.params || {}) as MemoryGetHandoffsParams;

  const handoffs = await context.memoryStore.listHandoffs(
    params.workingDirectory,
    params.limit
  );

  const result: MemoryGetHandoffsResult = {
    handoffs: handoffs.map((h: unknown) => {
      const handoff = h as Record<string, unknown>;
      return {
        id: handoff.id as string,
        sessionId: handoff.sessionId as string,
        summary: handoff.summary as string,
        createdAt: handoff.createdAt as string,
      };
    }),
  };

  return MethodRegistry.successResponse(request.id, result);
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create memory handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createMemoryHandlers(): MethodRegistration[] {
  const searchHandler: MethodHandler = async (request, context) => {
    const response = await handleMemorySearch(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    throw RpcHandlerError.fromResponse(response);
  };

  const addEntryHandler: MethodHandler = async (request, context) => {
    const response = await handleMemoryAddEntry(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    throw RpcHandlerError.fromResponse(response);
  };

  const getHandoffsHandler: MethodHandler = async (request, context) => {
    const response = await handleMemoryGetHandoffs(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    throw RpcHandlerError.fromResponse(response);
  };

  return [
    {
      method: 'memory.search',
      handler: searchHandler,
      options: {
        requiredManagers: ['memoryStore'],
        description: 'Search memory entries',
      },
    },
    {
      method: 'memory.addEntry',
      handler: addEntryHandler,
      options: {
        requiredParams: ['type', 'content'],
        requiredManagers: ['memoryStore'],
        description: 'Add a memory entry',
      },
    },
    {
      method: 'memory.getHandoffs',
      handler: getHandoffsHandler,
      options: {
        requiredManagers: ['memoryStore'],
        description: 'List session handoffs',
      },
    },
  ];
}
