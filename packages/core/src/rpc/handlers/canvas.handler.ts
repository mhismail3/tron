/**
 * @fileoverview Canvas RPC Handlers
 *
 * Handlers for canvas.* RPC methods:
 * - canvas.get: Get a canvas artifact by ID
 */

import type { RpcRequest, CanvasGetParams } from '../types.js';
import type { RpcContext } from '../handler.js';
import { MethodRegistry, type MethodRegistration, type MethodHandler } from '../registry.js';

// =============================================================================
// Handler Implementations
// =============================================================================

/**
 * Handle canvas.get request
 *
 * Retrieves a canvas artifact from the server's disk storage.
 * Used by iOS clients to load canvas data on session resume.
 */
export async function handleCanvasGet(
  request: RpcRequest,
  context: RpcContext
): Promise<ReturnType<typeof MethodRegistry.successResponse | typeof MethodRegistry.errorResponse>> {
  if (!context.canvasManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Canvas manager not available');
  }

  const params = request.params as CanvasGetParams | undefined;

  if (!params?.canvasId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'canvasId is required');
  }

  try {
    const result = await context.canvasManager.getCanvas(params.canvasId);
    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Failed to get canvas';
    return MethodRegistry.errorResponse(request.id, 'CANVAS_ERROR', message);
  }
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create canvas handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createCanvasHandlers(): MethodRegistration[] {
  const getHandler: MethodHandler = async (request, context) => {
    const response = await handleCanvasGet(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as Error & { code?: string }).code = response.error?.code;
    throw err;
  };

  return [
    {
      method: 'canvas.get',
      handler: getHandler,
      options: {
        requiredParams: ['canvasId'],
        requiredManagers: ['canvasManager'],
        description: 'Get a canvas artifact by ID',
      },
    },
  ];
}
