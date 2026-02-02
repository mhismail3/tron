/**
 * @fileoverview System RPC Handlers
 *
 * Handlers for system.* RPC methods:
 * - system.ping: Health check returning pong with timestamp
 * - system.getInfo: System information (version, uptime, memory)
 *
 * These are simple, stateless handlers that don't require any managers.
 */

import type { RpcRequest, RpcResponse, SystemPingResult, SystemGetInfoResult } from '../types.js';
import type { RpcContext } from '../context-types.js';
import { MethodRegistry, type MethodRegistration, type MethodHandler } from '../registry.js';
import { VERSION } from '@core/constants.js';

// Module-level start time for uptime calculation
const startTime = Date.now();

// =============================================================================
// Handler Implementations
// =============================================================================

/**
 * Handle system.ping request
 *
 * Returns a simple pong response with current timestamp.
 * Used for health checks and latency measurement.
 */
export async function handleSystemPing(
  request: RpcRequest,
  _context: RpcContext
): Promise<RpcResponse> {
  const result: SystemPingResult = {
    pong: true,
    timestamp: new Date().toISOString(),
  };
  return MethodRegistry.successResponse(request.id, result);
}

/**
 * Handle system.getInfo request
 *
 * Returns system information including:
 * - version: Package version
 * - uptime: Time since module load (ms)
 * - activeSessions: Currently 0 (would need session manager query)
 * - memoryUsage: Node.js heap statistics
 */
export async function handleSystemGetInfo(
  request: RpcRequest,
  _context: RpcContext
): Promise<RpcResponse> {
  const memory = process.memoryUsage();

  const result: SystemGetInfoResult = {
    version: VERSION,
    uptime: Date.now() - startTime,
    activeSessions: 0,
    memoryUsage: {
      heapUsed: memory.heapUsed,
      heapTotal: memory.heapTotal,
    },
  };

  return MethodRegistry.successResponse(request.id, result);
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create system handler registrations
 *
 * @returns Array of method registrations for bulk registration
 *
 * @example
 * ```typescript
 * const registry = new MethodRegistry();
 * registry.registerAll(createSystemHandlers());
 * ```
 */
export function createSystemHandlers(): MethodRegistration[] {
  // Wrap handlers to return just the result (not RpcResponse)
  // The registry will wrap with successResponse
  const pingHandler: MethodHandler = async () => ({
    pong: true,
    timestamp: new Date().toISOString(),
  });

  const getInfoHandler: MethodHandler = async () => {
    const memory = process.memoryUsage();
    return {
      version: VERSION,
      uptime: Date.now() - startTime,
      activeSessions: 0,
      memoryUsage: {
        heapUsed: memory.heapUsed,
        heapTotal: memory.heapTotal,
      },
    };
  };

  return [
    {
      method: 'system.ping',
      handler: pingHandler,
      options: {
        description: 'Health check returning pong with timestamp',
      },
    },
    {
      method: 'system.getInfo',
      handler: getInfoHandler,
      options: {
        description: 'System information (version, uptime, memory)',
      },
    },
  ];
}
