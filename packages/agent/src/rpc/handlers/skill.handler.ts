/**
 * @fileoverview Skill RPC Handlers
 *
 * Handlers for skill.* RPC methods:
 * - skill.list: List available skills
 * - skill.get: Get a specific skill
 * - skill.refresh: Refresh skill cache
 * - skill.remove: Remove a skill from a session
 */

import { createLogger, categorizeError, LogErrorCategory } from '../../logging/index.js';
import type {
  RpcRequest,
  RpcResponse,
  SkillListParams,
  SkillGetParams,
  SkillRefreshParams,
  SkillRemoveParams,
} from '../types.js';
import type { RpcContext } from '../context-types.js';
import { MethodRegistry, type MethodRegistration, type MethodHandler } from '../registry.js';

const logger = createLogger('rpc:skill');

// =============================================================================
// Handler Implementations
// =============================================================================

/**
 * Handle skill.list request
 *
 * Lists available skills.
 */
export async function handleSkillList(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.skillManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Skill manager not available');
  }

  const params = (request.params || {}) as SkillListParams;

  try {
    const result = await context.skillManager.listSkills(params);
    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    const structured = categorizeError(error, { operation: 'list' });
    logger.error('Failed to list skills', {
      code: structured.code,
      category: LogErrorCategory.SKILL_LOAD,
      error: structured.message,
      retryable: structured.retryable,
    });
    const message = error instanceof Error ? error.message : 'Failed to list skills';
    return MethodRegistry.errorResponse(request.id, 'SKILL_ERROR', message);
  }
}

/**
 * Handle skill.get request
 *
 * Gets a specific skill by name.
 */
export async function handleSkillGet(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.skillManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Skill manager not available');
  }

  const params = request.params as SkillGetParams | undefined;

  if (!params?.name) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'name is required');
  }

  try {
    const result = await context.skillManager.getSkill(params);
    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    const structured = categorizeError(error, { skillName: params.name, operation: 'get' });
    logger.error('Failed to get skill', {
      skillName: params.name,
      code: structured.code,
      category: LogErrorCategory.SKILL_LOAD,
      error: structured.message,
      retryable: structured.retryable,
    });
    const message = error instanceof Error ? error.message : 'Failed to get skill';
    return MethodRegistry.errorResponse(request.id, 'SKILL_ERROR', message);
  }
}

/**
 * Handle skill.refresh request
 *
 * Refreshes the skill cache.
 */
export async function handleSkillRefresh(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.skillManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Skill manager not available');
  }

  const params = (request.params || {}) as SkillRefreshParams;

  try {
    const result = await context.skillManager.refreshSkills(params);
    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    const structured = categorizeError(error, { operation: 'refresh' });
    logger.error('Failed to refresh skills', {
      code: structured.code,
      category: LogErrorCategory.SKILL_LOAD,
      error: structured.message,
      retryable: structured.retryable,
    });
    const message = error instanceof Error ? error.message : 'Failed to refresh skills';
    return MethodRegistry.errorResponse(request.id, 'SKILL_ERROR', message);
  }
}

/**
 * Handle skill.remove request
 *
 * Removes a skill from a session.
 */
export async function handleSkillRemove(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  if (!context.skillManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Skill manager not available');
  }

  const params = request.params as SkillRemoveParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }
  if (!params?.skillName) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'skillName is required');
  }

  try {
    const result = await context.skillManager.removeSkill(params);
    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    const structured = categorizeError(error, { sessionId: params.sessionId, skillName: params.skillName, operation: 'remove' });
    logger.error('Failed to remove skill', {
      sessionId: params.sessionId,
      skillName: params.skillName,
      code: structured.code,
      category: LogErrorCategory.SKILL_LOAD,
      error: structured.message,
      retryable: structured.retryable,
    });
    const message = error instanceof Error ? error.message : 'Failed to remove skill';
    return MethodRegistry.errorResponse(request.id, 'SKILL_ERROR', message);
  }
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create skill handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createSkillHandlers(): MethodRegistration[] {
  const listHandler: MethodHandler = async (request, context) => {
    const response = await handleSkillList(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const getHandler: MethodHandler = async (request, context) => {
    const response = await handleSkillGet(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const refreshHandler: MethodHandler = async (request, context) => {
    const response = await handleSkillRefresh(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const removeHandler: MethodHandler = async (request, context) => {
    const response = await handleSkillRemove(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  return [
    {
      method: 'skill.list',
      handler: listHandler,
      options: {
        requiredManagers: ['skillManager'],
        description: 'List available skills',
      },
    },
    {
      method: 'skill.get',
      handler: getHandler,
      options: {
        requiredParams: ['name'],
        requiredManagers: ['skillManager'],
        description: 'Get a specific skill',
      },
    },
    {
      method: 'skill.refresh',
      handler: refreshHandler,
      options: {
        requiredManagers: ['skillManager'],
        description: 'Refresh skill cache',
      },
    },
    {
      method: 'skill.remove',
      handler: removeHandler,
      options: {
        requiredParams: ['sessionId', 'skillName'],
        requiredManagers: ['skillManager'],
        description: 'Remove a skill from a session',
      },
    },
  ];
}
