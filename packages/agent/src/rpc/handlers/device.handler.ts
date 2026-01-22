/**
 * @fileoverview Device Token RPC Handlers
 *
 * Handlers for device.* RPC methods:
 * - device.register: Register a device token for push notifications
 * - device.unregister: Unregister a device token
 */

import type { RpcRequest, RpcResponse } from '../types.js';
import type { RpcContext } from '../handler.js';
import { MethodRegistry, type MethodRegistration, type MethodHandler } from '../registry.js';

// =============================================================================
// Handler Implementations
// =============================================================================

/**
 * Handle device.register request
 *
 * Registers or updates a device token for push notifications.
 */
export async function handleDeviceRegister(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.deviceManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Device manager not available');
  }

  const params = request.params as {
    deviceToken?: string;
    sessionId?: string;
    workspaceId?: string;
    environment?: 'sandbox' | 'production';
  } | undefined;

  if (!params?.deviceToken) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'deviceToken is required');
  }

  try {
    const result = await context.deviceManager.registerToken({
      deviceToken: params.deviceToken,
      sessionId: params.sessionId,
      workspaceId: params.workspaceId,
      environment: params.environment,
    });

    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    if (error instanceof Error) {
      return MethodRegistry.errorResponse(request.id, 'REGISTRATION_FAILED', error.message);
    }
    throw error;
  }
}

/**
 * Handle device.unregister request
 *
 * Unregisters (deactivates) a device token.
 */
export async function handleDeviceUnregister(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.deviceManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Device manager not available');
  }

  const params = request.params as { deviceToken?: string } | undefined;

  if (!params?.deviceToken) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'deviceToken is required');
  }

  try {
    const result = await context.deviceManager.unregisterToken(params.deviceToken);
    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    if (error instanceof Error) {
      return MethodRegistry.errorResponse(request.id, 'UNREGISTRATION_FAILED', error.message);
    }
    throw error;
  }
}

// =============================================================================
// Handler Wrappers for Registry
// =============================================================================

const registerHandler: MethodHandler = async (request, context) => {
  return handleDeviceRegister(request, context);
};

const unregisterHandler: MethodHandler = async (request, context) => {
  return handleDeviceUnregister(request, context);
};

// =============================================================================
// Method Registrations
// =============================================================================

/**
 * Get all device method registrations
 */
export function getDeviceHandlers(): MethodRegistration[] {
  return [
    {
      method: 'device.register',
      handler: registerHandler,
      options: {
        requiredParams: ['deviceToken'],
        requiredManagers: ['deviceManager'],
        description: 'Register a device token for push notifications',
      },
    },
    {
      method: 'device.unregister',
      handler: unregisterHandler,
      options: {
        requiredParams: ['deviceToken'],
        requiredManagers: ['deviceManager'],
        description: 'Unregister a device token',
      },
    },
  ];
}
