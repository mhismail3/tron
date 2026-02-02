/**
 * @fileoverview Search RPC Handlers
 *
 * Handlers for search.* RPC methods:
 * - search.content: Search content in events
 * - search.events: Search events (alias for search.content)
 *
 * Validation is handled by the registry via requiredParams/requiredManagers options.
 */

import type { MethodRegistration, MethodHandler } from '../registry.js';

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
// Handler Factory
// =============================================================================

/**
 * Create search handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createSearchHandlers(): MethodRegistration[] {
  const contentHandler: MethodHandler<SearchParams> = async (request, context) => {
    const params = request.params!;
    return context.eventStore!.searchContent(params.query, {
      sessionId: params.sessionId,
      workspaceId: params.workspaceId,
      types: params.types,
      limit: params.limit,
    });
  };

  // Events handler is same as content handler
  const eventsHandler = contentHandler;

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
