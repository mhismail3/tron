/**
 * @fileoverview EventStore - High-level API for Event-Sourced Sessions
 *
 * Provides the main interface for creating sessions, appending events,
 * retrieving state, and performing tree operations (fork, rewind).
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
import { calculateCost } from '../providers/models.js';

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
  provider: string;
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
  provider?: string;
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
      provider: options.provider,
      title: options.title,
      tags: options.tags,
    });

    // Create root event
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
        provider: options.provider,
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

      const counters: { eventCount: number; messageCount?: number; inputTokens?: number; outputTokens?: number; cost?: number } = {
        eventCount: 1,
      };

      // Track message count for message events
      if (options.type === 'message.user' || options.type === 'message.assistant') {
        counters.messageCount = 1;
      }

      // Track token usage and calculate cost
      const payload = options.payload as { tokenUsage?: TokenUsage; model?: string };
      if (payload.tokenUsage) {
        counters.inputTokens = payload.tokenUsage.inputTokens;
        counters.outputTokens = payload.tokenUsage.outputTokens;
        // Calculate cost using the model from payload or session
        const modelId = payload.model ?? session.model;
        counters.cost = calculateCost(modelId, payload.tokenUsage.inputTokens, payload.tokenUsage.outputTokens);
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
    const messages: Message[] = [];

    for (const event of ancestors) {
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
    const messages: Message[] = [];
    let inputTokens = 0;
    let outputTokens = 0;
    let turnCount = 0;
    let currentTurn = 0;

    for (const evt of ancestors) {
      if (evt.type === 'message.user') {
        const payload = evt.payload as { content: Message['content']; tokenUsage?: TokenUsage };
        messages.push({
          role: 'user',
          content: payload.content,
        });
        // Token usage can be on user messages too
        if (payload.tokenUsage) {
          inputTokens += payload.tokenUsage.inputTokens;
          outputTokens += payload.tokenUsage.outputTokens;
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
        if (payload.tokenUsage) {
          inputTokens += payload.tokenUsage.inputTokens;
          outputTokens += payload.tokenUsage.outputTokens;
        }
        if (payload.turn && payload.turn > currentTurn) {
          currentTurn = payload.turn;
          turnCount = payload.turn;
        }
      }
    }

    // Get session for context
    const session = await this.backend.getSession(event.sessionId);

    return {
      sessionId: event.sessionId,
      workspaceId: event.workspaceId,
      headEventId: eventId,
      messages,
      tokenUsage: { inputTokens, outputTokens },
      turnCount,
      model: session?.model ?? 'unknown',
      workingDirectory: session?.workingDirectory ?? '',
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
        model: options?.model ?? sourceSession.model,
        provider: sourceSession.provider,
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
  // Rewind Operation
  // ===========================================================================

  async rewind(sessionId: SessionId, toEventId: EventId): Promise<void> {
    const event = await this.backend.getEvent(toEventId);
    if (!event) {
      throw new Error(`Event not found: ${toEventId}`);
    }

    if (event.sessionId !== sessionId) {
      throw new Error(`Event ${toEventId} does not belong to session ${sessionId}`);
    }

    await this.backend.updateSessionHead(sessionId, toEventId);
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

  async endSession(sessionId: SessionId): Promise<void> {
    await this.backend.updateSessionStatus(sessionId, 'ended');
  }

  async updateSessionModel(sessionId: SessionId, model: string): Promise<void> {
    await this.backend.updateSessionModel(sessionId, model);
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
