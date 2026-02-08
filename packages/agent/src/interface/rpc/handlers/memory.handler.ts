/**
 * @fileoverview Memory RPC Handlers
 *
 * Handlers for memory.* RPC methods:
 * - memory.getLedger: Get paginated ledger entries for a workspace
 */

import type { MethodRegistration, MethodHandler } from '../registry.js';

// =============================================================================
// Types
// =============================================================================

interface MemoryGetLedgerParams {
  workingDirectory: string;
  limit?: number;
  offset?: number;
  tags?: string[];
}

// =============================================================================
// Handler Factory
// =============================================================================

export function createMemoryHandlers(): MethodRegistration[] {
  const getLedgerHandler: MethodHandler<MemoryGetLedgerParams> = async (request, context) => {
    const params = request.params!;
    return context.eventStore!.getLedgerEntries(params.workingDirectory, {
      limit: params.limit,
      offset: params.offset,
      tags: params.tags,
    });
  };

  return [
    {
      method: 'memory.getLedger',
      handler: getLedgerHandler,
      options: {
        requiredParams: ['workingDirectory'],
        requiredManagers: ['eventStore'],
        description: 'Get paginated ledger entries for a workspace',
      },
    },
  ];
}
