/**
 * @fileoverview Canvas RPC Handlers
 *
 * Handlers for canvas.* RPC methods:
 * - canvas.get: Get a canvas artifact by ID
 *
 * Validation is handled by the registry via requiredParams/requiredManagers options.
 */

import type { CanvasGetParams } from '../types.js';
import type { MethodRegistration, MethodHandler } from '../registry.js';
import { RpcError, RpcErrorCode } from './base.js';

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create canvas handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createCanvasHandlers(): MethodRegistration[] {
  const getHandler: MethodHandler<CanvasGetParams> = async (request, context) => {
    const params = request.params!;

    try {
      return await context.canvasManager!.getCanvas(params.canvasId);
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Failed to get canvas';
      throw new RpcError(RpcErrorCode.CANVAS_ERROR, message);
    }
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
