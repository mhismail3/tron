/**
 * @fileoverview Memory RPC Handlers
 *
 * Handlers for memory.* RPC methods:
 * - memory.getLedger: Get paginated ledger entries for a workspace
 * - memory.updateLedger: Trigger a one-shot memory ledger update for a session
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

interface MemoryUpdateLedgerParams {
  sessionId: string;
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

  const updateLedgerHandler: MethodHandler<MemoryUpdateLedgerParams> = async (request, context) => {
    const params = request.params!;
    return context.agentManager.triggerLedgerUpdate(params.sessionId);
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
    {
      method: 'memory.updateLedger',
      handler: updateLedgerHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['agentManager'],
        description: 'Trigger a one-shot memory ledger update for the current session',
      },
    },
  ];
}
