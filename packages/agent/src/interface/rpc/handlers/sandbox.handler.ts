/**
 * @fileoverview Sandbox RPC Handlers
 *
 * Handlers for sandbox.* RPC methods:
 * - sandbox.listContainers: List all tracked containers with live status
 */

import type { MethodRegistration, MethodHandler } from '../registry.js';

// =============================================================================
// Handler Factory
// =============================================================================

export function createSandboxHandlers(): MethodRegistration[] {
  const listContainersHandler: MethodHandler = async (_request, context) => {
    return context.sandboxManager!.listContainers();
  };

  return [
    {
      method: 'sandbox.listContainers',
      handler: listContainersHandler,
      options: {
        requiredManagers: ['sandboxManager'],
        description: 'List all tracked containers with live status',
      },
    },
  ];
}
