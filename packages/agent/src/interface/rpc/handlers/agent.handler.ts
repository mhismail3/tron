/**
 * @fileoverview Agent RPC Handlers
 *
 * Handlers for agent.* RPC methods:
 * - agent.prompt: Send a prompt to the agent
 * - agent.abort: Abort the current agent operation
 * - agent.getState: Get the current agent state
 *
 * Validation is handled by the registry via requiredParams/requiredManagers options.
 */

import type {
  AgentPromptParams,
  AgentAbortParams,
  AgentGetStateParams,
} from '../types.js';
import type { MethodRegistration, MethodHandler } from '../registry.js';

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create agent handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createAgentHandlers(): MethodRegistration[] {
  const promptHandler: MethodHandler<AgentPromptParams> = async (request, context) => {
    const params = request.params!;
    return context.agentManager.prompt(params);
  };

  const abortHandler: MethodHandler<AgentAbortParams> = async (request, context) => {
    const params = request.params!;
    return context.agentManager.abort(params.sessionId);
  };

  const getStateHandler: MethodHandler<AgentGetStateParams> = async (request, context) => {
    const params = request.params!;
    return context.agentManager.getState(params.sessionId);
  };

  return [
    {
      method: 'agent.prompt',
      handler: promptHandler,
      options: {
        requiredParams: ['sessionId', 'prompt'],
        requiredManagers: ['agentManager'],
        description: 'Send a prompt to the agent',
      },
    },
    {
      method: 'agent.abort',
      handler: abortHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['agentManager'],
        description: 'Abort the current agent operation',
      },
    },
    {
      method: 'agent.getState',
      handler: getStateHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['agentManager'],
        description: 'Get the current agent state',
      },
    },
  ];
}
