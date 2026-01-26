/**
 * @fileoverview Plan RPC Handlers
 *
 * Handlers for plan.* RPC methods:
 * - plan.enter: Enter plan mode for a session
 * - plan.exit: Exit plan mode for a session
 * - plan.getState: Get plan mode state for a session
 */

import { createLogger, categorizeError, LogErrorCategory } from '../../logging/index.js';
import type {
  RpcRequest,
  RpcResponse,
  PlanEnterParams,
  PlanExitParams,
  PlanGetStateParams,
} from '../types.js';
import type { RpcContext } from '../handler.js';
import { MethodRegistry, type MethodRegistration, type MethodHandler } from '../registry.js';

const logger = createLogger('rpc:plan');

// =============================================================================
// Handler Implementations
// =============================================================================

/**
 * Handle plan.enter request
 *
 * Enters plan mode for a session, blocking write operations until plan is approved.
 */
export async function handlePlanEnter(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.planManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Plan manager not available');
  }

  const params = request.params as PlanEnterParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }

  if (!params?.skillName) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'skillName is required');
  }

  try {
    const result = await context.planManager.enterPlanMode(
      params.sessionId,
      params.skillName,
      params.blockedTools
    );
    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    if (error instanceof Error) {
      if (error.message.includes('Already in plan mode')) {
        return MethodRegistry.errorResponse(request.id, 'ALREADY_IN_PLAN_MODE', 'Session is already in plan mode');
      }
      if (error.message.includes('not found')) {
        return MethodRegistry.errorResponse(request.id, 'SESSION_NOT_FOUND', 'Session does not exist');
      }
    }
    const structured = categorizeError(error, { sessionId: params.sessionId, skillName: params.skillName, operation: 'enter' });
    logger.error('Failed to enter plan mode', {
      sessionId: params.sessionId,
      skillName: params.skillName,
      code: structured.code,
      category: LogErrorCategory.SESSION_STATE,
      error: structured.message,
      retryable: structured.retryable,
    });
    throw error;
  }
}

/**
 * Handle plan.exit request
 *
 * Exits plan mode for a session, unblocking write operations.
 */
export async function handlePlanExit(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.planManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Plan manager not available');
  }

  const params = request.params as PlanExitParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }

  if (!params?.reason) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'reason is required');
  }

  try {
    const result = await context.planManager.exitPlanMode(
      params.sessionId,
      params.reason,
      params.planPath
    );
    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    if (error instanceof Error) {
      if (error.message.includes('Not in plan mode')) {
        return MethodRegistry.errorResponse(request.id, 'NOT_IN_PLAN_MODE', 'Session is not in plan mode');
      }
      if (error.message.includes('not found')) {
        return MethodRegistry.errorResponse(request.id, 'SESSION_NOT_FOUND', 'Session does not exist');
      }
    }
    const structured = categorizeError(error, { sessionId: params.sessionId, reason: params.reason, operation: 'exit' });
    logger.error('Failed to exit plan mode', {
      sessionId: params.sessionId,
      reason: params.reason,
      code: structured.code,
      category: LogErrorCategory.SESSION_STATE,
      error: structured.message,
      retryable: structured.retryable,
    });
    throw error;
  }
}

/**
 * Handle plan.getState request
 *
 * Gets the current plan mode state for a session.
 */
export async function handlePlanGetState(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.planManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Plan manager not available');
  }

  const params = request.params as PlanGetStateParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }

  try {
    const result = context.planManager.getPlanModeState(params.sessionId);
    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    if (error instanceof Error) {
      if (error.message.includes('not found')) {
        return MethodRegistry.errorResponse(request.id, 'SESSION_NOT_FOUND', 'Session does not exist');
      }
    }
    const structured = categorizeError(error, { sessionId: params.sessionId, operation: 'getState' });
    logger.error('Failed to get plan mode state', {
      sessionId: params.sessionId,
      code: structured.code,
      category: LogErrorCategory.SESSION_STATE,
      error: structured.message,
      retryable: structured.retryable,
    });
    throw error;
  }
}

// =============================================================================
// Handler Registration
// =============================================================================

/**
 * Create method registrations for all plan handlers.
 */
export function createPlanHandlers(): MethodRegistration[] {
  return [
    {
      method: 'plan.enter',
      handler: handlePlanEnter as MethodHandler,
    },
    {
      method: 'plan.exit',
      handler: handlePlanExit as MethodHandler,
    },
    {
      method: 'plan.getState',
      handler: handlePlanGetState as MethodHandler,
    },
  ];
}
