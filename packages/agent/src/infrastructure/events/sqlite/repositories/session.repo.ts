/**
 * @fileoverview Session Repository
 *
 * Handles session CRUD operations including counters, filtering, and message previews.
 */

import type { SQLQueryBindings } from 'bun:sqlite';
import { BaseRepository, rowUtils } from './base.js';
import {
  SessionId,
  EventId,
  WorkspaceId,
} from '../../types.js';
import type { SessionDbRow } from '../types.js';

/**
 * Session entity with computed fields
 */
/** Subagent spawn type */
export type SpawnType = 'subsession' | 'tmux' | 'fork';

export interface SessionRow {
  id: SessionId;
  workspaceId: WorkspaceId;
  headEventId: EventId | null;
  rootEventId: EventId | null;
  title: string | null;
  latestModel: string;
  workingDirectory: string;
  parentSessionId: SessionId | null;
  forkFromEventId: EventId | null;
  createdAt: string;
  lastActivityAt: string;
  archivedAt: string | null;
  eventCount: number;
  messageCount: number;
  turnCount: number;
  totalInputTokens: number;
  totalOutputTokens: number;
  lastTurnInputTokens: number;
  totalCost: number;
  totalCacheReadTokens: number;
  totalCacheCreationTokens: number;
  tags: string[];
  /** Backward compatible alias for latestModel */
  model: string;
  /** Computed: whether session is archived (archivedAt !== null) */
  isArchived: boolean;
  /** Session ID that spawned this session (for subagents) */
  spawningSessionId: SessionId | null;
  /** Type of spawn (for subagents) */
  spawnType: SpawnType | null;
  /** Task given to this subagent (for subagents) */
  spawnTask: string | null;
}

/**
 * Options for creating a session
 */
export interface CreateSessionOptions {
  workspaceId: WorkspaceId;
  model: string;
  workingDirectory: string;
  title?: string;
  tags?: string[];
  parentSessionId?: SessionId;
  forkFromEventId?: EventId;
  /** Session ID that spawned this session (for subagents) */
  spawningSessionId?: SessionId;
  /** Type of spawn (for subagents) */
  spawnType?: SpawnType;
  /** Task given to this subagent (for subagents) */
  spawnTask?: string;
}

/**
 * Options for listing sessions
 */
export interface ListSessionsOptions {
  workspaceId?: WorkspaceId;
  /** Filter by archived state (derived from archived_at) */
  archived?: boolean;
  /** Exclude subagent sessions (spawning_session_id IS NULL) */
  excludeSubagents?: boolean;
  limit?: number;
  offset?: number;
  orderBy?: 'createdAt' | 'lastActivityAt';
  order?: 'asc' | 'desc';
}

/**
 * Options for incrementing session counters
 * All values are increments except lastTurnInputTokens which is SET
 */
export interface IncrementCountersOptions {
  eventCount?: number;
  messageCount?: number;
  turnCount?: number;
  inputTokens?: number;
  outputTokens?: number;
  /** Current context size (SET, not incremented) */
  lastTurnInputTokens?: number;
  cost?: number;
  /** Tokens read from prompt cache (incremented) */
  cacheReadTokens?: number;
  /** Tokens written to prompt cache (incremented) */
  cacheCreationTokens?: number;
}

/**
 * Message preview for session list UI
 */
export interface MessagePreview {
  lastUserPrompt?: string;
  lastAssistantResponse?: string;
}

/**
 * Repository for session operations
 */
export class SessionRepository extends BaseRepository {
  /**
   * Create a new session
   */
  create(options: CreateSessionOptions): SessionRow {
    const id = SessionId(`sess_${this.generateId('').slice(1)}`);
    const now = this.now();

    this.run(
      `INSERT INTO sessions (
        id, workspace_id, title, latest_model, working_directory,
        parent_session_id, fork_from_event_id, created_at, last_activity_at, tags,
        spawning_session_id, spawn_type, spawn_task
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      id,
      options.workspaceId,
      options.title ?? null,
      options.model,
      options.workingDirectory,
      options.parentSessionId ?? null,
      options.forkFromEventId ?? null,
      now,
      now,
      JSON.stringify(options.tags ?? []),
      options.spawningSessionId ?? null,
      options.spawnType ?? null,
      options.spawnTask ?? null
    );

    return {
      id,
      workspaceId: options.workspaceId,
      headEventId: null,
      rootEventId: null,
      title: options.title ?? null,
      latestModel: options.model,
      workingDirectory: options.workingDirectory,
      parentSessionId: options.parentSessionId ?? null,
      forkFromEventId: options.forkFromEventId ?? null,
      createdAt: now,
      lastActivityAt: now,
      archivedAt: null,
      eventCount: 0,
      messageCount: 0,
      turnCount: 0,
      totalInputTokens: 0,
      totalOutputTokens: 0,
      lastTurnInputTokens: 0,
      totalCacheReadTokens: 0,
      totalCacheCreationTokens: 0,
      totalCost: 0,
      tags: options.tags ?? [],
      model: options.model,
      isArchived: false,
      spawningSessionId: options.spawningSessionId ?? null,
      spawnType: options.spawnType ?? null,
      spawnTask: options.spawnTask ?? null,
    };
  }

  /**
   * Get session by ID
   */
  getById(sessionId: SessionId): SessionRow | null {
    const row = this.get<SessionDbRow>(
      'SELECT * FROM sessions WHERE id = ?',
      sessionId
    );
    if (!row) return null;
    return this.rowToSession(row);
  }

  /**
   * Batch get sessions by IDs (prevents N+1 queries)
   */
  getByIds(sessionIds: SessionId[]): Map<SessionId, SessionRow> {
    const result = new Map<SessionId, SessionRow>();
    if (sessionIds.length === 0) return result;

    const placeholders = this.inPlaceholders(sessionIds);
    const rows = this.all<SessionDbRow>(
      `SELECT * FROM sessions WHERE id IN (${placeholders})`,
      ...sessionIds
    );

    for (const row of rows) {
      result.set(SessionId(row.id), this.rowToSession(row));
    }
    return result;
  }

  /**
   * List sessions with filtering and pagination
   */
  list(options: ListSessionsOptions = {}): SessionRow[] {
    let sql = 'SELECT * FROM sessions WHERE 1=1';
    const params: SQLQueryBindings[] = [];

    if (options.workspaceId) {
      sql += ' AND workspace_id = ?';
      params.push(options.workspaceId);
    }

    if (options.archived !== undefined) {
      if (options.archived) {
        sql += ' AND archived_at IS NOT NULL';
      } else {
        sql += ' AND archived_at IS NULL';
      }
    }

    if (options.excludeSubagents) {
      sql += ' AND spawning_session_id IS NULL';
    }

    const orderBy = options.orderBy === 'createdAt' ? 'created_at' : 'last_activity_at';
    const order = options.order === 'asc' ? 'ASC' : 'DESC';
    sql += ` ORDER BY ${orderBy} ${order}`;

    if (options.limit) {
      sql += ' LIMIT ?';
      params.push(options.limit);
    }

    if (options.offset) {
      sql += ' OFFSET ?';
      params.push(options.offset);
    }

    const rows = this.all<SessionDbRow>(sql, ...params);
    return rows.map(row => this.rowToSession(row));
  }

  /**
   * Get message previews for session list UI
   * Returns last user prompt and assistant response for each session
   */
  getMessagePreviews(sessionIds: SessionId[]): Map<SessionId, MessagePreview> {
    const result = new Map<SessionId, MessagePreview>();
    if (sessionIds.length === 0) return result;

    // Initialize all sessions with empty previews
    for (const sessionId of sessionIds) {
      result.set(sessionId, {});
    }

    // Use window function to get last message of each type per session
    const placeholders = this.inPlaceholders(sessionIds);
    const rows = this.all<{ session_id: string; type: string; payload: string }>(
      `WITH ranked AS (
        SELECT
          session_id,
          type,
          payload,
          ROW_NUMBER() OVER (PARTITION BY session_id, type ORDER BY sequence DESC) as rn
        FROM events
        WHERE session_id IN (${placeholders})
          AND type IN ('message.user', 'message.assistant')
      )
      SELECT session_id, type, payload
      FROM ranked
      WHERE rn = 1`,
      ...sessionIds
    );

    for (const row of rows) {
      const sessionId = SessionId(row.session_id);
      const entry = result.get(sessionId) || {};

      try {
        const payload = JSON.parse(row.payload);
        const text = this.extractTextFromContent(payload.content);

        if (row.type === 'message.user') {
          entry.lastUserPrompt = text;
        } else if (row.type === 'message.assistant') {
          entry.lastAssistantResponse = text;
        }

        result.set(sessionId, entry);
      } catch {
        // Skip malformed payloads
      }
    }

    return result;
  }

  /**
   * Update session head event
   */
  updateHead(sessionId: SessionId, headEventId: EventId): void {
    const now = this.now();
    this.run(
      'UPDATE sessions SET head_event_id = ?, last_activity_at = ? WHERE id = ?',
      headEventId,
      now,
      sessionId
    );
  }

  /**
   * Update session root event
   */
  updateRoot(sessionId: SessionId, rootEventId: EventId): void {
    this.run(
      'UPDATE sessions SET root_event_id = ? WHERE id = ?',
      rootEventId,
      sessionId
    );
  }

  /**
   * Archive a session (set archived_at timestamp)
   */
  archive(sessionId: SessionId): void {
    const now = this.now();
    this.run(
      'UPDATE sessions SET archived_at = ?, last_activity_at = ? WHERE id = ?',
      now,
      now,
      sessionId
    );
  }

  /**
   * Unarchive a session (clear archived_at)
   */
  unarchive(sessionId: SessionId): void {
    const now = this.now();
    this.run(
      'UPDATE sessions SET archived_at = NULL, last_activity_at = ? WHERE id = ?',
      now,
      sessionId
    );
  }

  /**
   * Update latest model used in session
   */
  updateLatestModel(sessionId: SessionId, model: string): void {
    const now = this.now();
    this.run(
      'UPDATE sessions SET latest_model = ?, last_activity_at = ? WHERE id = ?',
      model,
      now,
      sessionId
    );
  }

  /**
   * Update session title
   */
  updateTitle(sessionId: SessionId, title: string | null): void {
    this.run(
      'UPDATE sessions SET title = ? WHERE id = ?',
      title,
      sessionId
    );
  }

  /**
   * Update session tags
   */
  updateTags(sessionId: SessionId, tags: string[]): void {
    this.run(
      'UPDATE sessions SET tags = ? WHERE id = ?',
      JSON.stringify(tags),
      sessionId
    );
  }

  /**
   * Increment cached counters in session table
   *
   * DENORMALIZATION NOTE: These counters are a performance cache.
   * Source of truth for token usage is in message.assistant events.
   * Turn counts can be derived from counting message.assistant events.
   *
   * These cached values enable quick session list queries without event traversal.
   * During full session reconstruction (getStateAt/getStateAtHead), token totals
   * are computed from events, NOT from these cached values.
   */
  incrementCounters(sessionId: SessionId, counters: IncrementCountersOptions): void {
    const updates: string[] = [];
    const params: SQLQueryBindings[] = [];

    if (counters.eventCount) {
      updates.push('event_count = event_count + ?');
      params.push(counters.eventCount);
    }
    if (counters.messageCount) {
      updates.push('message_count = message_count + ?');
      params.push(counters.messageCount);
    }
    if (counters.turnCount) {
      updates.push('turn_count = turn_count + ?');
      params.push(counters.turnCount);
    }
    if (counters.inputTokens) {
      updates.push('total_input_tokens = total_input_tokens + ?');
      params.push(counters.inputTokens);
    }
    if (counters.outputTokens) {
      updates.push('total_output_tokens = total_output_tokens + ?');
      params.push(counters.outputTokens);
    }
    // SET (not increment) last_turn_input_tokens - this is current context size
    if (counters.lastTurnInputTokens !== undefined) {
      updates.push('last_turn_input_tokens = ?');
      params.push(counters.lastTurnInputTokens);
    }
    if (counters.cost) {
      updates.push('total_cost = total_cost + ?');
      params.push(counters.cost);
    }
    if (counters.cacheReadTokens) {
      updates.push('total_cache_read_tokens = total_cache_read_tokens + ?');
      params.push(counters.cacheReadTokens);
    }
    if (counters.cacheCreationTokens) {
      updates.push('total_cache_creation_tokens = total_cache_creation_tokens + ?');
      params.push(counters.cacheCreationTokens);
    }

    if (updates.length === 0) return;

    updates.push('last_activity_at = ?');
    params.push(this.now());
    params.push(sessionId);

    this.run(
      `UPDATE sessions SET ${updates.join(', ')} WHERE id = ?`,
      ...params
    );
  }

  /**
   * Count non-archived sessions by workspace
   */
  countByWorkspace(workspaceId: WorkspaceId): number {
    const row = this.get<{ count: number }>(
      'SELECT COUNT(*) as count FROM sessions WHERE workspace_id = ? AND archived_at IS NULL',
      workspaceId
    );
    return row?.count ?? 0;
  }

  /**
   * Check if session exists
   */
  exists(sessionId: SessionId): boolean {
    const row = this.get<{ id: string }>(
      'SELECT id FROM sessions WHERE id = ?',
      sessionId
    );
    return row !== undefined;
  }

  /**
   * Delete a session
   */
  delete(sessionId: SessionId): boolean {
    const result = this.run('DELETE FROM sessions WHERE id = ?', sessionId);
    return result.changes > 0;
  }

  /**
   * Delete all sessions for a workspace
   */
  deleteByWorkspace(workspaceId: WorkspaceId): number {
    const result = this.run('DELETE FROM sessions WHERE workspace_id = ?', workspaceId);
    return result.changes;
  }

  // ===========================================================================
  // Private Helpers
  // ===========================================================================

  /**
   * Extract plain text from message content (can be string or block array)
   */
  private extractTextFromContent(content: unknown): string {
    if (typeof content === 'string') {
      return content;
    }

    if (Array.isArray(content)) {
      const texts: string[] = [];
      for (const block of content) {
        if (typeof block === 'object' && block !== null) {
          const b = block as Record<string, unknown>;
          if (b.type === 'text' && typeof b.text === 'string') {
            texts.push(b.text);
          }
        }
      }
      return texts.join('');
    }

    return '';
  }

  /**
   * Convert database row to SessionRow entity
   */
  private rowToSession(row: SessionDbRow): SessionRow {
    const latestModel = row.latest_model;
    const archivedAt = row.archived_at;
    return {
      id: SessionId(row.id),
      workspaceId: WorkspaceId(row.workspace_id),
      headEventId: row.head_event_id ? EventId(row.head_event_id) : null,
      rootEventId: row.root_event_id ? EventId(row.root_event_id) : null,
      title: row.title,
      latestModel,
      workingDirectory: row.working_directory,
      parentSessionId: row.parent_session_id ? SessionId(row.parent_session_id) : null,
      forkFromEventId: row.fork_from_event_id ? EventId(row.fork_from_event_id) : null,
      createdAt: row.created_at,
      lastActivityAt: row.last_activity_at,
      archivedAt,
      eventCount: row.event_count,
      messageCount: row.message_count,
      turnCount: row.turn_count,
      totalInputTokens: row.total_input_tokens,
      totalOutputTokens: row.total_output_tokens,
      lastTurnInputTokens: row.last_turn_input_tokens ?? 0,
      totalCost: row.total_cost ?? 0,
      totalCacheReadTokens: row.total_cache_read_tokens ?? 0,
      totalCacheCreationTokens: row.total_cache_creation_tokens ?? 0,
      tags: rowUtils.parseJson(row.tags, []),
      // Backward compatibility aliases
      model: latestModel,
      isArchived: archivedAt !== null,
      // Subagent tracking
      spawningSessionId: row.spawning_session_id ? SessionId(row.spawning_session_id) : null,
      spawnType: row.spawn_type as SpawnType | null,
      spawnTask: row.spawn_task,
    };
  }

  /**
   * List subagent sessions spawned by a parent session
   */
  listSubagents(spawningSessionId: SessionId): SessionRow[] {
    const rows = this.all<SessionDbRow>(
      `SELECT * FROM sessions
       WHERE spawning_session_id = ?
       ORDER BY created_at DESC`,
      spawningSessionId
    );
    return rows.map(row => this.rowToSession(row));
  }

  /**
   * List active (non-ended) subagent sessions for a parent session
   */
  listActiveSubagents(spawningSessionId: SessionId): SessionRow[] {
    const rows = this.all<SessionDbRow>(
      `SELECT * FROM sessions
       WHERE spawning_session_id = ?
         AND archived_at IS NULL
       ORDER BY created_at DESC`,
      spawningSessionId
    );
    return rows.map(row => this.rowToSession(row));
  }
}
