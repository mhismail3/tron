/**
 * @fileoverview Device Token RPC Handlers
 *
 * Handlers for device.* RPC methods:
 * - device.register: Register a device token for push notifications
 * - device.unregister: Unregister a device token
 *
 * Validation is handled by the registry via requiredParams/requiredManagers options.
 */

import { createLogger, categorizeError, LogErrorCategory } from '@infrastructure/logging/index.js';
import type { MethodRegistration, MethodHandler } from '../registry.js';
import { RpcError, RpcErrorCode } from './base.js';

const logger = createLogger('rpc:device');

// =============================================================================
// Types
// =============================================================================

interface DeviceRegisterParams {
  deviceToken: string;
  sessionId?: string;
  workspaceId?: string;
  environment?: 'sandbox' | 'production';
}

interface DeviceUnregisterParams {
  deviceToken: string;
}

// =============================================================================
// Error Types
// =============================================================================

class RegistrationFailedError extends RpcError {
  constructor(message: string) {
    super('REGISTRATION_FAILED' as typeof RpcErrorCode[keyof typeof RpcErrorCode], message);
  }
}

class UnregistrationFailedError extends RpcError {
  constructor(message: string) {
    super('UNREGISTRATION_FAILED' as typeof RpcErrorCode[keyof typeof RpcErrorCode], message);
  }
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Get all device method registrations
 */
export function getDeviceHandlers(): MethodRegistration[] {
  const registerHandler: MethodHandler<DeviceRegisterParams> = async (request, context) => {
    const params = request.params!;

    try {
      return await context.deviceManager!.registerToken({
        deviceToken: params.deviceToken,
        sessionId: params.sessionId,
        workspaceId: params.workspaceId,
        environment: params.environment,
      });
    } catch (error) {
      const structured = categorizeError(error, { operation: 'register' });
      logger.error('Failed to register device token', {
        code: structured.code,
        category: LogErrorCategory.DATABASE,
        error: structured.message,
        retryable: structured.retryable,
      });
      if (error instanceof Error) {
        throw new RegistrationFailedError(error.message);
      }
      throw error;
    }
  };

  const unregisterHandler: MethodHandler<DeviceUnregisterParams> = async (request, context) => {
    const params = request.params!;

    try {
      return await context.deviceManager!.unregisterToken(params.deviceToken);
    } catch (error) {
      const structured = categorizeError(error, { operation: 'unregister' });
      logger.error('Failed to unregister device token', {
        code: structured.code,
        category: LogErrorCategory.DATABASE,
        error: structured.message,
        retryable: structured.retryable,
      });
      if (error instanceof Error) {
        throw new UnregistrationFailedError(error.message);
      }
      throw error;
    }
  };

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
