/**
 * @fileoverview EventStore - High-level API for Event-Sourced Sessions
 *
 * Provides the main interface for creating sessions, appending events,
 * retrieving state, and performing tree operations (fork).
 */

import * as crypto from 'crypto';
import { SQLiteBackend, type SessionRow, type ListSessionsOptions } from './sqlite-backend.js';
import {
  EventId,
  SessionId,
  WorkspaceId,
  type SessionEvent,
  type SessionStartEvent,
  type SessionForkEvent,
  type EventType,
  type Workspace,
  type SessionState,
  type Message,
  type SearchResult,
  type TokenUsage,
} from './types.js';
import { calculateCost } from '../usage/index.js';
import { createLogger } from '../logging/logger.js';

const logger = createLogger('event-store');

// =============================================================================
// Types
// =============================================================================

export interface EventStoreConfig {
  dbPath: string;
}

export interface CreateSessionOptions {
  workspacePath: string;
  workingDirectory: string;
  model: string;
  /** Provider type (for session.start event payload) */
  provider?: string;
  title?: string;
  tags?: string[];
  /** Additional metadata to include in session.start event payload */
  metadata?: Record<string, unknown>;
}

export interface CreateSessionResult {
  session: SessionRow;
  rootEvent: SessionEvent;
}

export interface AppendEventOptions {
  sessionId: SessionId;
  type: EventType;
  payload: Record<string, unknown>;
  parentId?: EventId; // If not provided, uses session head
}

export interface ForkOptions {
  name?: string;
  model?: string;
}

export interface ForkResult {
  session: SessionRow;
  rootEvent: SessionEvent;
}

export interface SearchOptions {
  workspaceId?: WorkspaceId;
  sessionId?: SessionId;
  types?: EventType[];
  limit?: number;
}

// =============================================================================
// EventStore Implementation
// =============================================================================

export class EventStore {
  private backend: SQLiteBackend;
  private initialized = false;

  constructor(dbPath: string) {
    this.backend = new SQLiteBackend(dbPath);
  }

  // ===========================================================================
  // Lifecycle
  // ===========================================================================

  async initialize(): Promise<void> {
    if (this.initialized) return;
    await this.backend.initialize();
    this.initialized = true;
  }

  async close(): Promise<void> {
    await this.backend.close();
    this.initialized = false;
  }

  isInitialized(): boolean {
    return this.initialized;
  }

  /**
   * Get the underlying database instance.
   * Used for initializing shared resources like the log transport.
   */
  getDatabase(): import('better-sqlite3').Database {
    return this.backend.getDatabase();
  }

  // ===========================================================================
  // Session Creation
  // ===========================================================================

  async createSession(options: CreateSessionOptions): Promise<CreateSessionResult> {
    // Get or create workspace
    const workspace = await this.backend.getOrCreateWorkspace(
      options.workspacePath,
      options.workspacePath.split('/').pop() // Use last segment as name
    );

    // Create session
    const session = await this.backend.createSession({
      workspaceId: workspace.id,
      workingDirectory: options.workingDirectory,
      model: options.model,
      title: options.title,
      tags: options.tags,
    });

    // Create root event (provider stored in event payload for historical record)
    const rootEvent: SessionStartEvent = {
      id: EventId(`evt_${this.generateId()}`),
      parentId: null,
      sessionId: session.id,
      workspaceId: workspace.id,
      timestamp: new Date().toISOString(),
      type: 'session.start',
      sequence: 0,
      payload: {
        workingDirectory: options.workingDirectory,
        model: options.model,
        ...(options.provider && { provider: options.provider }),
        title: options.title,
        // Include any additional metadata in the payload
        ...options.metadata,
      },
    };

    await this.backend.insertEvent(rootEvent);
    await this.backend.updateSessionRoot(session.id, rootEvent.id);
    await this.backend.updateSessionHead(session.id, rootEvent.id);
    await this.backend.incrementSessionCounters(session.id, { eventCount: 1 });

    return {
      session: { ...session, rootEventId: rootEvent.id, headEventId: rootEvent.id },
      rootEvent,
    };
  }

  // ===========================================================================
  // Event Appending
  // ===========================================================================

  async append(options: AppendEventOptions): Promise<SessionEvent> {
    const session = await this.backend.getSession(options.sessionId);
    if (!session) {
      throw new Error(`Session not found: ${options.sessionId}`);
    }

    // Determine parent - use provided or session head
    const parentId = options.parentId ?? session.headEventId;
    if (!parentId) {
      throw new Error('No parent ID available');
    }

    // P1 FIX: Wrap sequence generation + insert in transaction to prevent race conditions
    // Without this, concurrent appends could get duplicate sequence numbers
    return this.backend.transactionAsync(async () => {
      // Get next sequence number (atomic within transaction)
      const sequence = await this.backend.getNextSequence(options.sessionId);

      // Create event
      const event: SessionEvent = {
        id: EventId(`evt_${this.generateId()}`),
        parentId,
        sessionId: options.sessionId,
        workspaceId: session.workspaceId,
        timestamp: new Date().toISOString(),
        type: options.type,
        sequence,
        payload: options.payload,
      } as SessionEvent;

      await this.backend.insertEvent(event);

      // Update session head and counters
      await this.backend.updateSessionHead(options.sessionId, event.id);

      const counters: {
        eventCount: number;
        messageCount?: number;
        inputTokens?: number;
        outputTokens?: number;
        lastTurnInputTokens?: number;
        cost?: number;
        cacheReadTokens?: number;
        cacheCreationTokens?: number;
      } = {
        eventCount: 1,
      };

      // Track message count for message events
      if (options.type === 'message.user' || options.type === 'message.assistant') {
        counters.messageCount = 1;
      }

      // Track token usage and cost
      const payload = options.payload as { tokenUsage?: TokenUsage; model?: string; cost?: number };
      if (payload.tokenUsage) {
        counters.inputTokens = payload.tokenUsage.inputTokens;
        counters.outputTokens = payload.tokenUsage.outputTokens;
        // Set current context size (not accumulated - represents context window utilization)
        counters.lastTurnInputTokens = payload.tokenUsage.inputTokens;
        // Track cache tokens for prompt caching efficiency
        if (payload.tokenUsage.cacheReadTokens) {
          counters.cacheReadTokens = payload.tokenUsage.cacheReadTokens;
          logger.debug(`[CACHE] Storing cacheReadTokens: ${payload.tokenUsage.cacheReadTokens}`);
        }
        if (payload.tokenUsage.cacheCreationTokens) {
          counters.cacheCreationTokens = payload.tokenUsage.cacheCreationTokens;
          logger.debug(`[CACHE] Storing cacheCreationTokens: ${payload.tokenUsage.cacheCreationTokens}`);
        }
        // Use pre-calculated cost if provided (from agent with full cache token pricing),
        // otherwise calculate from tokenUsage
        if (payload.cost !== undefined) {
          counters.cost = payload.cost;
        } else {
          const modelId = payload.model ?? session.latestModel;
          counters.cost = calculateCost(modelId, payload.tokenUsage).total;
        }
      }

      await this.backend.incrementSessionCounters(options.sessionId, counters);

      // Index for search
      await this.backend.indexEventForSearch(event);

      return event;
    });
  }

  // ===========================================================================
  // Event Retrieval
  // ===========================================================================

  async getEvent(eventId: EventId): Promise<SessionEvent | null> {
    return this.backend.getEvent(eventId);
  }

  async getEventsBySession(sessionId: SessionId): Promise<SessionEvent[]> {
    return this.backend.getEventsBySession(sessionId);
  }

  async getAncestors(eventId: EventId): Promise<SessionEvent[]> {
    return this.backend.getAncestors(eventId);
  }

  async getChildren(eventId: EventId): Promise<SessionEvent[]> {
    return this.backend.getChildren(eventId);
  }

  // ===========================================================================
  // State Projection
  // ===========================================================================

  async getMessagesAtHead(sessionId: SessionId): Promise<Message[]> {
    const session = await this.backend.getSession(sessionId);
    if (!session?.headEventId) return [];
    return this.getMessagesAt(session.headEventId);
  }

  async getMessagesAt(eventId: EventId): Promise<Message[]> {
    const ancestors = await this.backend.getAncestors(eventId);

    // Two-pass reconstruction: First collect deleted event IDs, then build messages
    // This ensures deletions that occur later in the chain are properly filtered
    const deletedEventIds = new Set<EventId>();
    for (const event of ancestors) {
      if (event.type === 'message.deleted') {
        const payload = event.payload as { targetEventId: EventId };
        deletedEventIds.add(payload.targetEventId);
      }
    }

    const messages: Message[] = [];

    for (const event of ancestors) {
      // Skip deleted messages
      if (deletedEventIds.has(event.id)) {
        continue;
      }

      // Handle compaction boundary - clear pre-compaction messages and inject summary
      // Compaction events come in order: [old messages] -> compact.boundary -> compact.summary -> [new messages]
      // When we see compact.summary, we discard messages before it and inject the summary as context
      if (event.type === 'compact.summary') {
        const payload = event.payload as { summary: string };
        // Clear any messages we've collected (they were summarized)
        messages.length = 0;
        // Inject the compaction summary as a context message pair
        // This mirrors how ContextManager.executeCompaction() formats the summary
        messages.push({
          role: 'user',
          content: `[Context from earlier in this conversation]\n\n${payload.summary}`,
        });
        messages.push({
          role: 'assistant',
          content: [
            {
              type: 'text',
              text: 'I understand the previous context. Let me continue helping you.',
            },
          ],
        });
        continue;
      }

      // Handle context cleared - discard all messages before this point
      // Unlike compaction, no summary is preserved - messages just get cleared
      if (event.type === 'context.cleared') {
        messages.length = 0;
        continue;
      }

      if (event.type === 'message.user') {
        const payload = event.payload as { content: Message['content'] };
        messages.push({
          role: 'user',
          content: payload.content,
        });
      } else if (event.type === 'message.assistant') {
        const payload = event.payload as { content: Message['content'] };
        messages.push({
          role: 'assistant',
          content: payload.content,
        });
      }
      // NOTE: tool.result events are NOT reconstructed here as separate messages.
      // Tool results are stored in two places:
      // 1. tool.result events (for real-time streaming/display)
      // 2. message.user events with tool_result content (for proper sequencing)
      // The message.user approach (stored at turn end, AFTER message.assistant) ensures
      // correct ordering: assistant(tool_use) -> user(tool_result)
      // Reconstructing tool.result events would create duplicate/misordered messages.
    }

    return messages;
  }

  async getStateAtHead(sessionId: SessionId): Promise<SessionState> {
    const session = await this.backend.getSession(sessionId);
    if (!session?.headEventId) {
      throw new Error(`Session has no head event: ${sessionId}`);
    }
    return this.getStateAt(session.headEventId);
  }

  async getStateAt(eventId: EventId): Promise<SessionState> {
    const event = await this.backend.getEvent(eventId);
    if (!event) {
      throw new Error(`Event not found: ${eventId}`);
    }

    const ancestors = await this.backend.getAncestors(eventId);

    // Two-pass reconstruction: First collect deleted event IDs and config state
    const deletedEventIds = new Set<EventId>();
    let reasoningLevel: 'low' | 'medium' | 'high' | 'xhigh' | undefined;
    let systemPrompt: string | undefined;

    for (const evt of ancestors) {
      if (evt.type === 'message.deleted') {
        const payload = evt.payload as { targetEventId: EventId };
        deletedEventIds.add(payload.targetEventId);
      } else if (evt.type === 'config.reasoning_level') {
        const payload = evt.payload as { newLevel?: 'low' | 'medium' | 'high' | 'xhigh' };
        reasoningLevel = payload.newLevel;
      } else if (evt.type === 'session.start') {
        // Extract initial system prompt from session.start
        const payload = evt.payload as { systemPrompt?: string };
        if (payload.systemPrompt) {
          systemPrompt = payload.systemPrompt;
        }
      } else if (evt.type === 'config.prompt_update') {
        // Track mid-session system prompt updates (using hash-based content blob)
        // Note: actual content retrieval from blob would need additional implementation
        // For now, we track that an update happened
        const payload = evt.payload as { newHash: string; contentBlobId?: string };
        // If contentBlobId is present, we'd fetch from blob storage
        // For now, mark that systemPrompt was updated (actual content TBD)
        if (payload.contentBlobId) {
          // TODO: Implement blob content retrieval for full prompt restoration
          systemPrompt = `[Updated prompt - hash: ${payload.newHash}]`;
        }
      }
    }

    const messages: Message[] = [];
    const messageEventIds: (string | undefined)[] = [];
    let inputTokens = 0;
    let outputTokens = 0;
    let cacheReadTokens = 0;
    let cacheCreationTokens = 0;
    let turnCount = 0;
    let currentTurn = 0;

    for (const evt of ancestors) {
      // Skip deleted messages
      if (deletedEventIds.has(evt.id)) {
        continue;
      }

      // Handle compaction boundary - clear pre-compaction messages and inject summary
      // This mirrors getMessagesAt behavior for consistency
      if (evt.type === 'compact.summary') {
        const payload = evt.payload as { summary: string };
        // Clear messages before compaction (but preserve token accounting for session totals)
        messages.length = 0;
        messageEventIds.length = 0;
        // Inject the compaction summary as a context message pair
        // These synthetic messages don't have eventIds (undefined)
        messages.push({
          role: 'user',
          content: `[Context from earlier in this conversation]\n\n${payload.summary}`,
        });
        messageEventIds.push(undefined); // Synthetic message, no eventId
        messages.push({
          role: 'assistant',
          content: [
            {
              type: 'text',
              text: 'I understand the previous context. Let me continue helping you.',
            },
          ],
        });
        messageEventIds.push(undefined); // Synthetic message, no eventId
        continue;
      }

      // Handle context cleared - discard all messages before this point
      // Unlike compaction, no summary is preserved - messages just get cleared
      // Token accounting is preserved for session totals
      if (evt.type === 'context.cleared') {
        messages.length = 0;
        messageEventIds.length = 0;
        continue;
      }

      if (evt.type === 'message.user') {
        const payload = evt.payload as { content: Message['content']; tokenUsage?: TokenUsage };
        messages.push({
          role: 'user',
          content: payload.content,
        });
        messageEventIds.push(evt.id); // Track eventId for deletion
        // Token usage can be on user messages too
        if (payload.tokenUsage) {
          inputTokens += payload.tokenUsage.inputTokens;
          outputTokens += payload.tokenUsage.outputTokens;
          cacheReadTokens += payload.tokenUsage.cacheReadTokens ?? 0;
          cacheCreationTokens += payload.tokenUsage.cacheCreationTokens ?? 0;
        }
      } else if (evt.type === 'message.assistant') {
        const payload = evt.payload as {
          content: Message['content'];
          turn?: number;
          tokenUsage?: TokenUsage;
        };
        messages.push({
          role: 'assistant',
          content: payload.content,
        });
        messageEventIds.push(evt.id); // Track eventId for deletion
        if (payload.tokenUsage) {
          inputTokens += payload.tokenUsage.inputTokens;
          outputTokens += payload.tokenUsage.outputTokens;
          cacheReadTokens += payload.tokenUsage.cacheReadTokens ?? 0;
          cacheCreationTokens += payload.tokenUsage.cacheCreationTokens ?? 0;
        }
        if (payload.turn && payload.turn > currentTurn) {
          currentTurn = payload.turn;
          turnCount = payload.turn;
        }
      }
      // NOTE: tool.result events are NOT reconstructed here.
      // Tool results are stored in message.user events (at turn end) for proper sequencing.
      // See comment in getMessagesAt() for details.
    }

    // Get session for context
    const session = await this.backend.getSession(event.sessionId);

    return {
      sessionId: event.sessionId,
      workspaceId: event.workspaceId,
      headEventId: eventId,
      messages,
      messageEventIds,
      tokenUsage: { inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens },
      turnCount,
      model: session?.latestModel ?? 'unknown',
      workingDirectory: session?.workingDirectory ?? '',
      reasoningLevel,
      systemPrompt,
    };
  }

  // ===========================================================================
  // Fork Operation
  // ===========================================================================

  async fork(fromEventId: EventId, options?: ForkOptions): Promise<ForkResult> {
    const sourceEvent = await this.backend.getEvent(fromEventId);
    if (!sourceEvent) {
      throw new Error(`Event not found: ${fromEventId}`);
    }

    const sourceSession = await this.backend.getSession(sourceEvent.sessionId);
    if (!sourceSession) {
      throw new Error(`Source session not found: ${sourceEvent.sessionId}`);
    }

    // P1 FIX: Wrap entire fork operation in transaction to prevent orphaned sessions
    // If crash occurs between createSession and insertEvent, we'd have an inconsistent state
    return this.backend.transactionAsync(async () => {
      // Create new forked session
      const forkedSession = await this.backend.createSession({
        workspaceId: sourceSession.workspaceId,
        workingDirectory: sourceSession.workingDirectory,
        model: options?.model ?? sourceSession.latestModel,
        title: options?.name,
        parentSessionId: sourceSession.id,
        forkFromEventId: fromEventId,
      });

      // Create fork event
      const forkEvent: SessionForkEvent = {
        id: EventId(`evt_${this.generateId()}`),
        parentId: fromEventId, // Points to the event we forked from
        sessionId: forkedSession.id,
        workspaceId: sourceSession.workspaceId,
        timestamp: new Date().toISOString(),
        type: 'session.fork',
        sequence: 0,
        payload: {
          sourceSessionId: sourceSession.id,
          sourceEventId: fromEventId,
          name: options?.name,
        },
      };

      await this.backend.insertEvent(forkEvent);
      await this.backend.updateSessionRoot(forkedSession.id, forkEvent.id);
      await this.backend.updateSessionHead(forkedSession.id, forkEvent.id);
      await this.backend.incrementSessionCounters(forkedSession.id, { eventCount: 1 });

      return {
        session: { ...forkedSession, rootEventId: forkEvent.id, headEventId: forkEvent.id },
        rootEvent: forkEvent,
      };
    });
  }

  // ===========================================================================
  // Search
  // ===========================================================================

  async search(query: string, options?: SearchOptions): Promise<SearchResult[]> {
    return this.backend.searchEvents(query, {
      workspaceId: options?.workspaceId,
      sessionId: options?.sessionId,
      types: options?.types,
      limit: options?.limit,
    });
  }

  // ===========================================================================
  // Session Management
  // ===========================================================================

  async getSession(sessionId: SessionId): Promise<SessionRow | null> {
    return this.backend.getSession(sessionId);
  }

  /**
   * P2 FIX: Batch fetch sessions by IDs to prevent N+1 queries
   */
  async getSessionsByIds(sessionIds: SessionId[]): Promise<Map<SessionId, SessionRow>> {
    return this.backend.getSessionsByIds(sessionIds);
  }

  async listSessions(options?: ListSessionsOptions): Promise<SessionRow[]> {
    return this.backend.listSessions(options ?? {});
  }

  /**
   * Get message previews (last user prompt and assistant response) for a list of sessions.
   */
  async getSessionMessagePreviews(sessionIds: SessionId[]): Promise<Map<SessionId, { lastUserPrompt?: string; lastAssistantResponse?: string }>> {
    return this.backend.getSessionMessagePreviews(sessionIds);
  }

  async endSession(sessionId: SessionId): Promise<void> {
    await this.backend.markSessionEnded(sessionId);
  }

  async clearSessionEnded(sessionId: SessionId): Promise<void> {
    await this.backend.clearSessionEnded(sessionId);
  }

  /**
   * Update the cached latest model in the session table.
   *
   * DENORMALIZATION NOTE: This is a performance cache. The source of truth for
   * model changes is the `config.model_switch` event. This cached value is used
   * for quick session lookups without traversing the event tree. During session
   * reconstruction (getStateAt/getStateAtHead), the model is determined from
   * events, NOT from this cached value.
   *
   * If the cache becomes stale, it can be recomputed by scanning events for the
   * latest config.model_switch event or the session.start event.
   */
  async updateLatestModel(sessionId: SessionId, model: string): Promise<void> {
    await this.backend.updateLatestModel(sessionId, model);
  }

  // ===========================================================================
  // Message Deletion
  // ===========================================================================

  /**
   * Delete a message from the session context.
   * This appends a message.deleted event; the original message is preserved in the event log.
   * Two-pass reconstruction will filter out deleted messages.
   *
   * @param sessionId - Session containing the message
   * @param targetEventId - Event ID of the message to delete
   * @param reason - Reason for deletion (defaults to 'user_request')
   */
  async deleteMessage(
    sessionId: SessionId,
    targetEventId: EventId,
    reason: 'user_request' | 'content_policy' | 'context_management' = 'user_request'
  ): Promise<SessionEvent> {
    // Validate target exists and is a message
    const targetEvent = await this.backend.getEvent(targetEventId);
    if (!targetEvent) {
      throw new Error(`Event not found: ${targetEventId}`);
    }

    // Only allow deleting message and tool result events
    const deletableTypes = ['message.user', 'message.assistant', 'tool.result'];
    if (!deletableTypes.includes(targetEvent.type)) {
      throw new Error(`Cannot delete event of type: ${targetEvent.type}`);
    }

    // Validate target belongs to the session (or is in its ancestry for forks)
    const session = await this.backend.getSession(sessionId);
    if (!session) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    // Get turn number from the target message if available
    const targetPayload = targetEvent.payload as { turn?: number };

    // Append the deletion event
    return this.append({
      sessionId,
      type: 'message.deleted',
      payload: {
        targetEventId,
        targetType: targetEvent.type as 'message.user' | 'message.assistant',
        targetTurn: targetPayload.turn,
        reason,
      },
    });
  }

  // ===========================================================================
  // Workspace
  // ===========================================================================

  async getWorkspaceByPath(path: string): Promise<Workspace | null> {
    return this.backend.getWorkspaceByPath(path);
  }

  // ===========================================================================
  // Utilities
  // ===========================================================================

  private generateId(length = 12): string {
    return crypto.randomUUID().replace(/-/g, '').slice(0, length);
  }
}
