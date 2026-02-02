/**
 * @fileoverview Plan RPC Handlers
 *
 * Handlers for plan.* RPC methods:
 * - plan.enter: Enter plan mode for a session
 * - plan.exit: Exit plan mode for a session
 * - plan.getState: Get plan mode state for a session
 *
 * Validation is handled by the registry via requiredParams/requiredManagers options.
 */

import { createLogger, categorizeError, LogErrorCategory } from '@infrastructure/logging/index.js';
import type {
  PlanEnterParams,
  PlanExitParams,
  PlanGetStateParams,
} from '../types.js';
import type { MethodRegistration, MethodHandler } from '../registry.js';
import { RpcError, RpcErrorCode, SessionNotFoundError } from './base.js';

const logger = createLogger('rpc:plan');

// =============================================================================
// Error Types
// =============================================================================

class AlreadyInPlanModeError extends RpcError {
  constructor() {
    super('ALREADY_IN_PLAN_MODE' as typeof RpcErrorCode[keyof typeof RpcErrorCode], 'Session is already in plan mode');
  }
}

class NotInPlanModeError extends RpcError {
  constructor() {
    super('NOT_IN_PLAN_MODE' as typeof RpcErrorCode[keyof typeof RpcErrorCode], 'Session is not in plan mode');
  }
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create method registrations for all plan handlers.
 */
export function createPlanHandlers(): MethodRegistration[] {
  const enterHandler: MethodHandler<PlanEnterParams> = async (request, context) => {
    const params = request.params!;

    try {
      return await context.planManager!.enterPlanMode(
        params.sessionId,
        params.skillName,
        params.blockedTools
      );
    } catch (error) {
      if (error instanceof Error) {
        if (error.message.includes('Already in plan mode')) {
          throw new AlreadyInPlanModeError();
        }
        if (error.message.includes('not found')) {
          throw new SessionNotFoundError(params.sessionId);
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
  };

  const exitHandler: MethodHandler<PlanExitParams> = async (request, context) => {
    const params = request.params!;

    try {
      return await context.planManager!.exitPlanMode(
        params.sessionId,
        params.reason,
        params.planPath
      );
    } catch (error) {
      if (error instanceof Error) {
        if (error.message.includes('Not in plan mode')) {
          throw new NotInPlanModeError();
        }
        if (error.message.includes('not found')) {
          throw new SessionNotFoundError(params.sessionId);
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
  };

  const getStateHandler: MethodHandler<PlanGetStateParams> = async (request, context) => {
    const params = request.params!;

    try {
      return context.planManager!.getPlanModeState(params.sessionId);
    } catch (error) {
      if (error instanceof Error && error.message.includes('not found')) {
        throw new SessionNotFoundError(params.sessionId);
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
  };

  return [
    {
      method: 'plan.enter',
      handler: enterHandler,
      options: {
        requiredParams: ['sessionId', 'skillName'],
        requiredManagers: ['planManager'],
        description: 'Enter plan mode for a session',
      },
    },
    {
      method: 'plan.exit',
      handler: exitHandler,
      options: {
        requiredParams: ['sessionId', 'reason'],
        requiredManagers: ['planManager'],
        description: 'Exit plan mode for a session',
      },
    },
    {
      method: 'plan.getState',
      handler: getStateHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['planManager'],
        description: 'Get plan mode state for a session',
      },
    },
  ];
}
