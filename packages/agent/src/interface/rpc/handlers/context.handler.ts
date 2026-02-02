/**
 * @fileoverview Context RPC Handlers
 *
 * Handlers for context.* RPC methods:
 * - context.getSnapshot: Get context snapshot for a session
 * - context.getDetailedSnapshot: Get detailed context snapshot
 * - context.shouldCompact: Check if session should compact
 * - context.previewCompaction: Preview compaction result
 * - context.confirmCompaction: Confirm and execute compaction
 * - context.canAcceptTurn: Check if session can accept a turn
 * - context.clear: Clear session context
 *
 * Validation is handled by the registry via requiredParams/requiredManagers options.
 */

import { createLogger, categorizeError } from '@infrastructure/logging/index.js';
import type {
  ContextGetSnapshotParams,
  ContextGetDetailedSnapshotParams,
  ContextShouldCompactParams,
  ContextShouldCompactResult,
  ContextPreviewCompactionParams,
  ContextConfirmCompactionParams,
  ContextCanAcceptTurnParams,
  ContextClearParams,
} from '../types.js';
import type { MethodRegistration, MethodHandler } from '../registry.js';
import { SessionNotActiveError } from './base.js';

const logger = createLogger('rpc:context');

/**
 * Wrap operations that may throw "not active" errors
 */
async function withSessionActiveCheck<T>(
  sessionId: string,
  operation: string,
  fn: () => T | Promise<T>
): Promise<T> {
  try {
    return await fn();
  } catch (error) {
    if (error instanceof Error && error.message.includes('not active')) {
      throw new SessionNotActiveError(sessionId);
    }
    const structured = categorizeError(error, { sessionId, operation });
    logger.error(`Failed to ${operation}`, {
      sessionId,
      code: structured.code,
      category: structured.category,
      error: structured.message,
      retryable: structured.retryable,
    });
    throw error;
  }
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create context handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createContextHandlers(): MethodRegistration[] {
  const getSnapshotHandler: MethodHandler<ContextGetSnapshotParams> = async (request, context) => {
    const params = request.params!;
    return withSessionActiveCheck(params.sessionId, 'getSnapshot', () =>
      context.contextManager!.getContextSnapshot(params.sessionId)
    );
  };

  const getDetailedSnapshotHandler: MethodHandler<ContextGetDetailedSnapshotParams> = async (request, context) => {
    const params = request.params!;
    return withSessionActiveCheck(params.sessionId, 'getDetailedSnapshot', () =>
      context.contextManager!.getDetailedContextSnapshot(params.sessionId)
    );
  };

  const shouldCompactHandler: MethodHandler<ContextShouldCompactParams> = async (request, context) => {
    const params = request.params!;
    return withSessionActiveCheck(params.sessionId, 'shouldCompact', () => {
      const shouldCompact = context.contextManager!.shouldCompact(params.sessionId);
      const result: ContextShouldCompactResult = { shouldCompact };
      return result;
    });
  };

  const previewCompactionHandler: MethodHandler<ContextPreviewCompactionParams> = async (request, context) => {
    const params = request.params!;
    return withSessionActiveCheck(params.sessionId, 'previewCompaction', () =>
      context.contextManager!.previewCompaction(params.sessionId)
    );
  };

  const confirmCompactionHandler: MethodHandler<ContextConfirmCompactionParams> = async (request, context) => {
    const params = request.params!;
    return withSessionActiveCheck(params.sessionId, 'confirmCompaction', () =>
      context.contextManager!.confirmCompaction(params.sessionId, {
        editedSummary: params.editedSummary,
      })
    );
  };

  const canAcceptTurnHandler: MethodHandler<ContextCanAcceptTurnParams> = async (request, context) => {
    const params = request.params!;
    return withSessionActiveCheck(params.sessionId, 'canAcceptTurn', () =>
      context.contextManager!.canAcceptTurn(params.sessionId, {
        estimatedResponseTokens: params.estimatedResponseTokens,
      })
    );
  };

  const clearHandler: MethodHandler<ContextClearParams> = async (request, context) => {
    const params = request.params!;
    return withSessionActiveCheck(params.sessionId, 'clear', () =>
      context.contextManager!.clearContext(params.sessionId)
    );
  };

  return [
    {
      method: 'context.getSnapshot',
      handler: getSnapshotHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['contextManager'],
        description: 'Get context snapshot for a session',
      },
    },
    {
      method: 'context.getDetailedSnapshot',
      handler: getDetailedSnapshotHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['contextManager'],
        description: 'Get detailed context snapshot',
      },
    },
    {
      method: 'context.shouldCompact',
      handler: shouldCompactHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['contextManager'],
        description: 'Check if session should compact',
      },
    },
    {
      method: 'context.previewCompaction',
      handler: previewCompactionHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['contextManager'],
        description: 'Preview compaction result',
      },
    },
    {
      method: 'context.confirmCompaction',
      handler: confirmCompactionHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['contextManager'],
        description: 'Confirm and execute compaction',
      },
    },
    {
      method: 'context.canAcceptTurn',
      handler: canAcceptTurnHandler,
      options: {
        requiredParams: ['sessionId', 'estimatedResponseTokens'],
        requiredManagers: ['contextManager'],
        description: 'Check if session can accept a turn',
      },
    },
    {
      method: 'context.clear',
      handler: clearHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['contextManager'],
        description: 'Clear session context',
      },
    },
    // Legacy alias for context.confirmCompaction
    {
      method: 'context.compact',
      handler: confirmCompactionHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['contextManager'],
        description: 'Confirm and execute compaction (legacy alias)',
      },
    },
  ];
}
