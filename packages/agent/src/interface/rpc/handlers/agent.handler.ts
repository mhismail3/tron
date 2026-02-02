/**
 * @fileoverview Agent RPC Handlers
 *
 * Handlers for agent.* RPC methods:
 * - agent.prompt: Send a prompt to the agent
 * - agent.abort: Abort the current agent operation
 * - agent.getState: Get the current agent state
 */

import { RpcHandlerError } from '@core/utils/index.js';
import type {
  RpcRequest,
  RpcResponse,
  AgentPromptParams,
  AgentAbortParams,
  AgentGetStateParams,
} from '../types.js';
import type { RpcContext } from '../context-types.js';
import { MethodRegistry, type MethodRegistration, type MethodHandler } from '../registry.js';

// =============================================================================
// Handler Implementations
// =============================================================================

/**
 * Handle agent.prompt request
 *
 * Sends a prompt to the agent for processing.
 */
export async function handleAgentPrompt(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  const params = request.params as AgentPromptParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }
  if (!params?.prompt) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'prompt is required');
  }

  const result = await context.agentManager.prompt(params);
  return MethodRegistry.successResponse(request.id, result);
}

/**
 * Handle agent.abort request
 *
 * Aborts the current agent operation for a session.
 */
export async function handleAgentAbort(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  const params = request.params as AgentAbortParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }

  const result = await context.agentManager.abort(params.sessionId);
  return MethodRegistry.successResponse(request.id, result);
}

/**
 * Handle agent.getState request
 *
 * Gets the current state of the agent for a session.
 */
export async function handleAgentGetState(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  const params = request.params as AgentGetStateParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }

  const result = await context.agentManager.getState(params.sessionId);
  return MethodRegistry.successResponse(request.id, result);
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create agent handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createAgentHandlers(): MethodRegistration[] {
  const promptHandler: MethodHandler = async (request, context) => {
    const response = await handleAgentPrompt(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    throw RpcHandlerError.fromResponse(response);
  };

  const abortHandler: MethodHandler = async (request, context) => {
    const response = await handleAgentAbort(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    throw RpcHandlerError.fromResponse(response);
  };

  const getStateHandler: MethodHandler = async (request, context) => {
    const response = await handleAgentGetState(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    throw RpcHandlerError.fromResponse(response);
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
