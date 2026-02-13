/**
 * @fileoverview Session Adapter
 *
 * Adapts EventStoreOrchestrator session methods to the SessionManager
 * interface expected by RpcContext. Handles session lifecycle including
 * creation, retrieval, resumption, listing, deletion, forking, and model switching.
 */

import type { AdapterDependencies, SessionManagerAdapter, OrchestratorMessage } from '../types.js';

// =============================================================================
// Helper Functions
// =============================================================================

/**
 * Transform session data to the expected SessionInfo format
 */
function toSessionInfo(
  session: {
    sessionId: string;
    workingDirectory: string;
    model: string;
    messageCount: number;
    inputTokens: number;
    outputTokens: number;
    lastTurnInputTokens: number;
    cacheReadTokens: number;
    cacheCreationTokens: number;
    cost: number;
    createdAt: string;
    lastActivity: string;
    isActive: boolean;
    isArchived: boolean;
    lastUserPrompt?: string;
    lastAssistantResponse?: string;
  },
  messages: OrchestratorMessage[] = [],
) {
  return {
    sessionId: session.sessionId,
    workingDirectory: session.workingDirectory,
    model: session.model,
    messageCount: session.messageCount,
    inputTokens: session.inputTokens,
    outputTokens: session.outputTokens,
    lastTurnInputTokens: session.lastTurnInputTokens,
    cacheReadTokens: session.cacheReadTokens,
    cacheCreationTokens: session.cacheCreationTokens,
    cost: session.cost,
    createdAt: session.createdAt,
    lastActivity: session.lastActivity,
    isActive: session.isActive,
    isArchived: session.isArchived,
    messages: messages.map(m => ({
      role: m.role,
      content: m.content,
    })),
    lastUserPrompt: session.lastUserPrompt,
    lastAssistantResponse: session.lastAssistantResponse,
  };
}

// =============================================================================
// Session Adapter Factory
// =============================================================================

/**
 * Creates a session manager adapter that delegates to the orchestrator
 *
 * @param deps - Adapter dependencies including the orchestrator
 * @returns SessionManagerAdapter implementation
 */
export function createSessionAdapter(deps: AdapterDependencies): SessionManagerAdapter {
  const { orchestrator } = deps;

  return {
    /**
     * Create a new session
     */
    async createSession(params) {
      const session = await orchestrator.sessions.createSession({
        workingDirectory: params.workingDirectory,
        model: params.model,
      });
      return {
        sessionId: session.sessionId,
        model: session.model,
        createdAt: session.createdAt,
      };
    },

    /**
     * Get session info by ID
     */
    async getSession(sessionId) {
      const session = await orchestrator.sessions.getSession(sessionId);
      if (!session) return null;

      // Get messages from event store
      const messages = await orchestrator.events.getMessages(sessionId);

      return toSessionInfo(session, messages);
    },

    /**
     * Resume an existing session (activates it in the orchestrator)
     */
    async resumeSession(sessionId) {
      const session = await orchestrator.sessions.resumeSession(sessionId);

      // Get messages from event store
      const messages = await orchestrator.events.getMessages(sessionId);

      return toSessionInfo(session, messages);
    },

    /**
     * List sessions, optionally filtered by working directory
     */
    async listSessions(params) {
      const sessions = await orchestrator.sessions.listSessions({
        workingDirectory: params.workingDirectory,
        limit: params.limit,
        offset: params.offset,
        includeArchived: params.includeArchived,
      });

      // For list, we don't include full messages (empty array)
      return sessions.map((s: typeof sessions[number]) => toSessionInfo(s, []));
    },

    /**
     * Delete (archive) a session
     */
    async deleteSession(sessionId) {
      await orchestrator.sessions.archiveSession(sessionId);
      return true;
    },

    /**
     * Archive a session (hide from default list)
     */
    async archiveSession(sessionId) {
      await orchestrator.sessions.archiveSession(sessionId);
      return true;
    },

    /**
     * Unarchive a session (restore to list)
     */
    async unarchiveSession(sessionId) {
      await orchestrator.sessions.unarchiveSession(sessionId);
      return true;
    },

    /**
     * Fork a session from a specific event
     */
    async forkSession(sessionId, fromEventId) {
      const result = await orchestrator.sessions.forkSession(sessionId, fromEventId);
      return {
        newSessionId: result.newSessionId,
        rootEventId: result.rootEventId,
        forkedFromEventId: result.forkedFromEventId,
        forkedFromSessionId: result.forkedFromSessionId,
        worktree: result.worktree,
      };
    },

    /**
     * Switch the model for a session
     */
    async switchModel(sessionId, model) {
      return orchestrator.models.switchModel(sessionId, model);
    },
  };
}
