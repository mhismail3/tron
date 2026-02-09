/**
 * @fileoverview Sandbox RPC Handlers
 *
 * Handlers for sandbox.* RPC methods:
 * - sandbox.listContainers: List all tracked containers with live status
 * - sandbox.stopContainer: Stop a running container
 * - sandbox.startContainer: Start a stopped container
 * - sandbox.killContainer: Kill a container (SIGKILL)
 */

import type { MethodRegistration, MethodHandler } from '../registry.js';

// =============================================================================
// Handler Factory
// =============================================================================

export function createSandboxHandlers(): MethodRegistration[] {
  const listContainersHandler: MethodHandler = async (_request, context) => {
    return context.sandboxManager!.listContainers();
  };

  const stopContainerHandler: MethodHandler<{ name: string }> = async (request, context) => {
    return context.sandboxManager!.stopContainer(request.params!.name);
  };

  const startContainerHandler: MethodHandler<{ name: string }> = async (request, context) => {
    return context.sandboxManager!.startContainer(request.params!.name);
  };

  const killContainerHandler: MethodHandler<{ name: string }> = async (request, context) => {
    return context.sandboxManager!.killContainer(request.params!.name);
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
    {
      method: 'sandbox.stopContainer',
      handler: stopContainerHandler,
      options: {
        requiredManagers: ['sandboxManager'],
        requiredParams: ['name'],
        description: 'Stop a running container',
      },
    },
    {
      method: 'sandbox.startContainer',
      handler: startContainerHandler,
      options: {
        requiredManagers: ['sandboxManager'],
        requiredParams: ['name'],
        description: 'Start a stopped container',
      },
    },
    {
      method: 'sandbox.killContainer',
      handler: killContainerHandler,
      options: {
        requiredManagers: ['sandboxManager'],
        requiredParams: ['name'],
        description: 'Kill a container (SIGKILL)',
      },
    },
  ];
}
