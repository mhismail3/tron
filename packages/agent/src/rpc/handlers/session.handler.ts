/**
 * @fileoverview Session RPC Handlers
 *
 * Handlers for session.* RPC methods:
 * - session.create: Create a new session
 * - session.resume: Resume an existing session
 * - session.list: List all sessions
 * - session.delete: Delete a session
 * - session.fork: Fork a session from a specific point
 */

import { RpcHandlerError } from '../../utils/index.js';
import type {
  RpcRequest,
  RpcResponse,
  SessionCreateParams,
  SessionResumeParams,
  SessionResumeResult,
  SessionListParams,
  SessionListResult,
  SessionDeleteParams,
  SessionDeleteResult,
  SessionForkParams,
} from '../types.js';
import type { RpcContext } from '../context-types.js';
import { MethodRegistry, type MethodRegistration, type MethodHandler } from '../registry.js';

// =============================================================================
// Handler Implementations
// =============================================================================

/**
 * Handle session.create request
 *
 * Creates a new session with the specified working directory and options.
 */
export async function handleSessionCreate(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  const params = request.params as SessionCreateParams | undefined;

  if (!params?.workingDirectory) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'workingDirectory is required');
  }

  const result = await context.sessionManager.createSession(params);
  return MethodRegistry.successResponse(request.id, result);
}

/**
 * Handle session.resume request
 *
 * Resumes an existing session, activating it for agent operations.
 */
export async function handleSessionResume(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  const params = request.params as SessionResumeParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }

  try {
    const session = await context.sessionManager.resumeSession(params.sessionId);

    const result: SessionResumeResult = {
      sessionId: session.sessionId,
      model: session.model,
      messageCount: session.messages.length,
      lastActivity: session.lastActivity,
    };

    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    if (error instanceof Error && error.message.includes('not found')) {
      return MethodRegistry.errorResponse(request.id, 'SESSION_NOT_FOUND', 'Session does not exist');
    }
    throw error;
  }
}

/**
 * Handle session.list request
 *
 * Lists all sessions, optionally filtered by working directory or status.
 */
export async function handleSessionList(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  const params = (request.params || {}) as SessionListParams;
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

  return MethodRegistry.successResponse(request.id, result);
}

/**
 * Handle session.delete request
 *
 * Deletes a session by ID.
 */
export async function handleSessionDelete(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  const params = request.params as SessionDeleteParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }

  const deleted = await context.sessionManager.deleteSession(params.sessionId);

  const result: SessionDeleteResult = { deleted };
  return MethodRegistry.successResponse(request.id, result);
}

/**
 * Handle session.fork request
 *
 * Forks a session from a specific event ID, creating a new branch.
 */
export async function handleSessionFork(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  const params = request.params as SessionForkParams | undefined;

  if (!params?.sessionId) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'sessionId is required');
  }

  const result = await context.sessionManager.forkSession(
    params.sessionId,
    params.fromEventId
  );

  return MethodRegistry.successResponse(request.id, result);
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create session handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createSessionHandlers(): MethodRegistration[] {
  const createHandler: MethodHandler = async (request, context) => {
    const response = await handleSessionCreate(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    throw RpcHandlerError.fromResponse(response);
  };

  const resumeHandler: MethodHandler = async (request, context) => {
    const response = await handleSessionResume(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    throw RpcHandlerError.fromResponse(response);
  };

  const listHandler: MethodHandler = async (request, context) => {
    const response = await handleSessionList(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    throw RpcHandlerError.fromResponse(response);
  };

  const deleteHandler: MethodHandler = async (request, context) => {
    const response = await handleSessionDelete(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    throw RpcHandlerError.fromResponse(response);
  };

  const forkHandler: MethodHandler = async (request, context) => {
    const response = await handleSessionFork(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    throw RpcHandlerError.fromResponse(response);
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
