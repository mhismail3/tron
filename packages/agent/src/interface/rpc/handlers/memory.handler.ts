/**
 * @fileoverview Memory RPC Handlers
 *
 * Handlers for memory.* RPC methods:
 * - memory.search: Search memory entries
 * - memory.addEntry: Add a new memory entry
 * - memory.getHandoffs: List session handoffs
 *
 * Validation is handled by the registry via requiredParams/requiredManagers options.
 */

import type {
  MemorySearchParams,
  RpcMemorySearchResult,
  MemoryAddEntryParams,
  MemoryAddEntryResult,
  MemoryGetHandoffsParams,
  MemoryGetHandoffsResult,
} from '../types.js';
import type { MethodRegistration, MethodHandler } from '../registry.js';

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create memory handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createMemoryHandlers(): MethodRegistration[] {
  const searchHandler: MethodHandler<MemorySearchParams> = async (request, context) => {
    const params = request.params ?? {};
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
    return result;
  };

  const addEntryHandler: MethodHandler<MemoryAddEntryParams> = async (request, context) => {
    const params = request.params!;
    const addResult = await context.memoryStore.addEntry(params);

    const result: MemoryAddEntryResult = {
      id: addResult.id,
      created: true,
    };
    return result;
  };

  const getHandoffsHandler: MethodHandler<MemoryGetHandoffsParams> = async (request, context) => {
    const params = request.params ?? {};
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
    return result;
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
