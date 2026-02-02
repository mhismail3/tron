/**
 * @fileoverview System RPC Handlers
 *
 * Handlers for system.* RPC methods:
 * - system.ping: Health check returning pong with timestamp
 * - system.getInfo: System information (version, uptime, memory)
 *
 * These are simple, stateless handlers that don't require any managers.
 */

import type { MethodRegistration, MethodHandler } from '../registry.js';
import { VERSION } from '@core/constants.js';

// Module-level start time for uptime calculation
const startTime = Date.now();

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create system handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createSystemHandlers(): MethodRegistration[] {
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
