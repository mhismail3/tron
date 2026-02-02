/**
 * @fileoverview Skill RPC Handlers
 *
 * Handlers for skill.* RPC methods:
 * - skill.list: List available skills
 * - skill.get: Get a specific skill
 * - skill.refresh: Refresh skill cache
 * - skill.remove: Remove a skill from a session
 *
 * Validation is handled by the registry via requiredParams/requiredManagers options.
 */

import { createLogger, categorizeError, LogErrorCategory } from '@infrastructure/logging/index.js';
import type {
  SkillListParams,
  SkillGetParams,
  SkillRefreshParams,
  SkillRemoveParams,
} from '../types.js';
import type { MethodRegistration, MethodHandler } from '../registry.js';
import { SkillError } from './base.js';

const logger = createLogger('rpc:skill');

/**
 * Wrap skill operations with consistent error handling
 */
async function withSkillErrorHandling<T>(
  operation: string,
  context: Record<string, unknown>,
  fn: () => Promise<T>
): Promise<T> {
  try {
    return await fn();
  } catch (error) {
    const structured = categorizeError(error, { ...context, operation });
    logger.error(`Failed to ${operation}`, {
      ...context,
      code: structured.code,
      category: LogErrorCategory.SKILL_LOAD,
      error: structured.message,
      retryable: structured.retryable,
    });
    const message = error instanceof Error ? error.message : `Failed to ${operation}`;
    throw new SkillError(message);
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
  const listHandler: MethodHandler<SkillListParams> = async (request, context) => {
    const params = request.params ?? {};
    return withSkillErrorHandling('list skills', {}, () =>
      context.skillManager!.listSkills(params)
    );
  };

  const getHandler: MethodHandler<SkillGetParams> = async (request, context) => {
    const params = request.params!;
    return withSkillErrorHandling('get skill', { skillName: params.name }, () =>
      context.skillManager!.getSkill(params)
    );
  };

  const refreshHandler: MethodHandler<SkillRefreshParams> = async (request, context) => {
    const params = request.params ?? {};
    return withSkillErrorHandling('refresh skills', {}, () =>
      context.skillManager!.refreshSkills(params)
    );
  };

  const removeHandler: MethodHandler<SkillRemoveParams> = async (request, context) => {
    const params = request.params!;
    return withSkillErrorHandling(
      'remove skill',
      { sessionId: params.sessionId, skillName: params.skillName },
      () => context.skillManager!.removeSkill(params)
    );
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
