/**
 * @fileoverview Session RPC Handlers
 *
 * Handlers for session.* RPC methods:
 * - session.create: Create a new session
 * - session.resume: Resume an existing session
 * - session.list: List all sessions
 * - session.delete: Delete a session
 * - session.fork: Fork a session from a specific point
 *
 * Validation is handled by the registry via requiredParams/requiredManagers options.
 */

import type {
  SessionCreateParams,
  SessionResumeParams,
  SessionResumeResult,
  SessionListParams,
  SessionListResult,
  SessionDeleteParams,
  SessionDeleteResult,
  SessionForkParams,
} from '../types.js';
import type { MethodRegistration, MethodHandler } from '../registry.js';
import { SessionNotFoundError } from './base.js';

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create session handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createSessionHandlers(): MethodRegistration[] {
  const createHandler: MethodHandler<SessionCreateParams> = async (request, context) => {
    const params = request.params!;
    return context.sessionManager.createSession(params);
  };

  const resumeHandler: MethodHandler<SessionResumeParams> = async (request, context) => {
    const params = request.params!;
    try {
      const session = await context.sessionManager.resumeSession(params.sessionId);
      const result: SessionResumeResult = {
        sessionId: session.sessionId,
        model: session.model,
        messageCount: session.messages.length,
        lastActivity: session.lastActivity,
      };
      return result;
    } catch (error) {
      if (error instanceof Error && error.message.includes('not found')) {
        throw new SessionNotFoundError(params.sessionId);
      }
      throw error;
    }
  };

  const listHandler: MethodHandler<SessionListParams> = async (request, context) => {
    const params = request.params ?? {};
    const sessions = await context.sessionManager.listSessions(params);

    const result: SessionListResult = {
      sessions: sessions.map((s) => ({
        sessionId: s.sessionId,
        workingDirectory: s.workingDirectory,
        model: s.model,
        messageCount: s.messageCount,
        inputTokens: s.inputTokens,
        outputTokens: s.outputTokens,
        lastTurnInputTokens: s.lastTurnInputTokens,
        cacheReadTokens: s.cacheReadTokens,
        cacheCreationTokens: s.cacheCreationTokens,
        cost: s.cost,
        createdAt: s.createdAt,
        lastActivity: s.lastActivity,
        isActive: s.isActive,
        lastUserPrompt: s.lastUserPrompt,
        lastAssistantResponse: s.lastAssistantResponse,
      })),
    };
    return result;
  };

  const deleteHandler: MethodHandler<SessionDeleteParams> = async (request, context) => {
    const params = request.params!;
    const deleted = await context.sessionManager.deleteSession(params.sessionId);
    const result: SessionDeleteResult = { deleted };
    return result;
  };

  const forkHandler: MethodHandler<SessionForkParams> = async (request, context) => {
    const params = request.params!;
    return context.sessionManager.forkSession(params.sessionId, params.fromEventId);
  };

  return [
    {
      method: 'session.create',
      handler: createHandler,
      options: {
        requiredParams: ['workingDirectory'],
        requiredManagers: ['sessionManager'],
        description: 'Create a new session',
      },
    },
    {
      method: 'session.resume',
      handler: resumeHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['sessionManager'],
        description: 'Resume an existing session',
      },
    },
    {
      method: 'session.list',
      handler: listHandler,
      options: {
        requiredManagers: ['sessionManager'],
        description: 'List all sessions',
      },
    },
    {
      method: 'session.delete',
      handler: deleteHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['sessionManager'],
        description: 'Delete a session',
      },
    },
    {
      method: 'session.fork',
      handler: forkHandler,
      options: {
        requiredParams: ['sessionId'],
        requiredManagers: ['sessionManager'],
        description: 'Fork a session from a specific point',
      },
    },
  ];
}
