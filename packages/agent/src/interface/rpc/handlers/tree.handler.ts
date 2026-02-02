/**
 * @fileoverview Tree RPC Handlers
 *
 * Handlers for tree.* RPC methods:
 * - tree.getVisualization: Get tree visualization for a session
 * - tree.getBranches: Get branches for a session
 * - tree.getSubtree: Get subtree from an event
 * - tree.getAncestors: Get ancestors of an event
 *
 * Validation is handled by the registry via requiredParams/requiredManagers options.
 */

import type { MethodRegistration, MethodHandler } from '../registry.js';

// =============================================================================
// Types
// =============================================================================

interface TreeGetVisualizationParams {
  sessionId: string;
  maxDepth?: number;
  messagesOnly?: boolean;
}

interface TreeGetBranchesParams {
  sessionId: string;
}

interface TreeGetSubtreeParams {
  eventId: string;
  maxDepth?: number;
  direction?: 'descendants' | 'ancestors';
}

interface TreeGetAncestorsParams {
  eventId: string;
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create tree handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createTreeHandlers(): MethodRegistration[] {
  const getVisualizationHandler: MethodHandler<TreeGetVisualizationParams> = async (request, context) => {
    const params = request.params!;
    return context.eventStore!.getTreeVisualization(params.sessionId, {
      maxDepth: params.maxDepth,
      messagesOnly: params.messagesOnly,
    });
  };

  const getBranchesHandler: MethodHandler<TreeGetBranchesParams> = async (request, context) => {
    const params = request.params!;
    return context.eventStore!.getBranches(params.sessionId);
  };

  const getSubtreeHandler: MethodHandler<TreeGetSubtreeParams> = async (request, context) => {
    const params = request.params!;
    return context.eventStore!.getSubtree(params.eventId, {
      maxDepth: params.maxDepth,
      direction: params.direction,
    });
  };

  const getAncestorsHandler: MethodHandler<TreeGetAncestorsParams> = async (request, context) => {
    const params = request.params!;
    return context.eventStore!.getAncestors(params.eventId);
  };

  return [
    {
      method: 'tree.getVisualization',
      handler: getVisualizationHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['eventStore'],
        description: 'Get tree visualization for a session',
      },
    },
    {
      method: 'tree.getBranches',
      handler: getBranchesHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['eventStore'],
        description: 'Get branches for a session',
      },
    },
    {
      method: 'tree.getSubtree',
      handler: getSubtreeHandler,
      options: {
        requiredParams: ['eventId'],
        requiredManagers: ['eventStore'],
        description: 'Get subtree from an event',
      },
    },
    {
      method: 'tree.getAncestors',
      handler: getAncestorsHandler,
      options: {
        requiredParams: ['eventId'],
        requiredManagers: ['eventStore'],
        description: 'Get ancestors of an event',
      },
    },
  ];
}
