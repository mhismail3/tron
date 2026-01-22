/**
 * @fileoverview Tree RPC Handlers
 *
 * Handlers for tree.* RPC methods:
 * - tree.getVisualization: Get tree visualization for a session
 * - tree.getBranches: Get branches for a session
 * - tree.getSubtree: Get subtree from an event
 * - tree.getAncestors: Get ancestors of an event
 */

import type { RpcRequest, RpcResponse } from '../types.js';
import type { RpcContext } from '../handler.js';
import { MethodRegistry, type MethodRegistration, type MethodHandler } from '../registry.js';

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
// Handler Implementations
// =============================================================================

/**
 * Handle tree.getVisualization request
 *
 * Gets a tree visualization for a session's event history.
 */
export async function handleTreeGetVisualization(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.eventStore) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'EventStore not available');
  }

  const params = request.params as TreeGetVisualizationParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }

  const result = await context.eventStore.getTreeVisualization(params.sessionId, {
    maxDepth: params.maxDepth,
    messagesOnly: params.messagesOnly,
  });

  return MethodRegistry.successResponse(request.id, result);
}

/**
 * Handle tree.getBranches request
 *
 * Gets branch information for a session.
 */
export async function handleTreeGetBranches(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.eventStore) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'EventStore not available');
  }

  const params = request.params as TreeGetBranchesParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }

  const result = await context.eventStore.getBranches(params.sessionId);
  return MethodRegistry.successResponse(request.id, result);
}

/**
 * Handle tree.getSubtree request
 *
 * Gets a subtree starting from a specific event.
 */
export async function handleTreeGetSubtree(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.eventStore) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'EventStore not available');
  }

  const params = request.params as TreeGetSubtreeParams | undefined;

  if (!params?.eventId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'eventId is required');
  }

  const result = await context.eventStore.getSubtree(params.eventId, {
    maxDepth: params.maxDepth,
    direction: params.direction,
  });

  return MethodRegistry.successResponse(request.id, result);
}

/**
 * Handle tree.getAncestors request
 *
 * Gets all ancestors of a specific event.
 */
export async function handleTreeGetAncestors(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.eventStore) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'EventStore not available');
  }

  const params = request.params as TreeGetAncestorsParams | undefined;

  if (!params?.eventId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'eventId is required');
  }

  const result = await context.eventStore.getAncestors(params.eventId);
  return MethodRegistry.successResponse(request.id, result);
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
  const getVisualizationHandler: MethodHandler = async (request, context) => {
    const response = await handleTreeGetVisualization(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const getBranchesHandler: MethodHandler = async (request, context) => {
    const response = await handleTreeGetBranches(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const getSubtreeHandler: MethodHandler = async (request, context) => {
    const response = await handleTreeGetSubtree(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const getAncestorsHandler: MethodHandler = async (request, context) => {
    const response = await handleTreeGetAncestors(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
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
