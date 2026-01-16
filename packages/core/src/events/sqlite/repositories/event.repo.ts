/**
 * @fileoverview Event Repository
 *
 * Handles event storage and retrieval for the event-sourced session tree.
 * Events are immutable and form a tree structure via parentId chains.
 */

import { BaseRepository, rowUtils } from './base.js';
import {
  EventId,
  SessionId,
  WorkspaceId,
  type SessionEvent,
  type EventType,
  type TokenUsage,
} from '../../types.js';
import type { EventDbRow } from '../types.js';

/**
 * Extended event with computed depth field
 */
export type EventWithDepth = SessionEvent & {
  depth: number;
};

/**
 * Options for listing events
 */
export interface ListEventsOptions {
  limit?: number;
  offset?: number;
}

/**
 * Repository for event operations
 */
export class EventRepository extends BaseRepository {
  /**
   * Insert a new event
   * Events are immutable - this should only be called once per event ID
   */
  async insert(event: SessionEvent): Promise<void> {
    // Extract role from event type
    const role = this.extractRole(event.type);

    // Extract tool info from payload
    const { toolName, toolCallId, turn } = this.extractToolInfo(event);

    // Calculate depth from parent
    const depth = await this.calculateDepth(event.parentId);

    // Extract token usage
    const tokenUsage = this.extractTokenUsage(event);

    this.run(
      `INSERT INTO events (
        id, session_id, parent_id, sequence, depth, type, timestamp, payload,
        content_blob_id, workspace_id, role, tool_name, tool_call_id, turn,
        input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, checksum
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      event.id,
      event.sessionId,
      event.parentId,
      event.sequence,
      depth,
      event.type,
      event.timestamp,
      JSON.stringify(event.payload),
      (event as any).contentBlobId ?? null,
      event.workspaceId,
      role,
      toolName,
      toolCallId,
      turn,
      tokenUsage?.inputTokens ?? null,
      tokenUsage?.outputTokens ?? null,
      tokenUsage?.cacheReadTokens ?? null,
      tokenUsage?.cacheCreationTokens ?? null,
      event.checksum ?? null
    );
  }

  /**
   * Insert multiple events in a transaction
   */
  async insertBatch(events: SessionEvent[]): Promise<void> {
    if (events.length === 0) return;

    await this.transactionAsync(async () => {
      for (const event of events) {
        await this.insert(event);
      }
    });
  }

  /**
   * Get single event by ID
   */
  getById(eventId: EventId): EventWithDepth | null {
    const row = this.get<EventDbRow>('SELECT * FROM events WHERE id = ?', eventId);
    if (!row) return null;
    return this.rowToEvent(row);
  }

  /**
   * Batch get events by IDs
   * Returns a Map for efficient lookup
   */
  getByIds(eventIds: EventId[]): Map<EventId, EventWithDepth> {
    const result = new Map<EventId, EventWithDepth>();
    if (eventIds.length === 0) return result;

    const placeholders = this.inPlaceholders(eventIds);
    const rows = this.all<EventDbRow>(
      `SELECT * FROM events WHERE id IN (${placeholders})`,
      ...eventIds
    );

    for (const row of rows) {
      result.set(EventId(row.id), this.rowToEvent(row));
    }

    return result;
  }

  /**
   * Get all events for a session, ordered by sequence
   */
  getBySession(sessionId: SessionId, options?: ListEventsOptions): EventWithDepth[] {
    let sql = 'SELECT * FROM events WHERE session_id = ? ORDER BY sequence ASC';
    const params: unknown[] = [sessionId];

    if (options?.limit) {
      sql += ' LIMIT ?';
      params.push(options.limit);
    }

    if (options?.offset) {
      sql += ' OFFSET ?';
      params.push(options.offset);
    }

    const rows = this.all<EventDbRow>(sql, ...params);
    return rows.map(row => this.rowToEvent(row));
  }

  /**
   * Get events of specific types for a session
   */
  getByTypes(
    sessionId: SessionId,
    types: EventType[],
    options?: { limit?: number }
  ): EventWithDepth[] {
    if (types.length === 0) return [];

    const placeholders = this.inPlaceholders(types);
    let sql = `SELECT * FROM events WHERE session_id = ? AND type IN (${placeholders}) ORDER BY sequence ASC`;
    const params: unknown[] = [sessionId, ...types];

    if (options?.limit) {
      sql += ' LIMIT ?';
      params.push(options.limit);
    }

    const rows = this.all<EventDbRow>(sql, ...params);
    return rows.map(row => this.rowToEvent(row));
  }

  /**
   * Get the next sequence number for a session
   */
  getNextSequence(sessionId: SessionId): number {
    const row = this.get<{ max_seq: number | null }>(
      'SELECT MAX(sequence) as max_seq FROM events WHERE session_id = ?',
      sessionId
    );
    return (row?.max_seq ?? -1) + 1;
  }

  /**
   * Get ancestor chain from root to the specified event (inclusive)
   * Uses recursive CTE for efficient tree traversal
   * Returns events in chronological order (root first)
   */
  getAncestors(eventId: EventId): EventWithDepth[] {
    // Recursive CTE walks from target to root via parent_id
    // Depth limit (10000) prevents infinite loops from data corruption
    const rows = this.all<EventDbRow & { cte_depth: number }>(
      `WITH RECURSIVE ancestors(
        id, parent_id, session_id, workspace_id, type, timestamp, sequence,
        payload, content_blob_id, depth, role, tool_name, tool_call_id, turn,
        input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens,
        checksum, cte_depth
      ) AS (
        SELECT id, parent_id, session_id, workspace_id, type, timestamp, sequence,
               payload, content_blob_id, depth, role, tool_name, tool_call_id, turn,
               input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens,
               checksum, 0
        FROM events WHERE id = ?
        UNION ALL
        SELECT e.id, e.parent_id, e.session_id, e.workspace_id, e.type, e.timestamp,
               e.sequence, e.payload, e.content_blob_id, e.depth, e.role, e.tool_name,
               e.tool_call_id, e.turn, e.input_tokens, e.output_tokens,
               e.cache_read_tokens, e.cache_creation_tokens, e.checksum, a.cte_depth + 1
        FROM events e
        INNER JOIN ancestors a ON e.id = a.parent_id
        WHERE a.cte_depth < 10000
      )
      SELECT * FROM ancestors ORDER BY cte_depth DESC`,
      eventId
    );

    return rows.map(row => this.rowToEvent(row));
  }

  /**
   * Get direct children of an event
   */
  getChildren(eventId: EventId): EventWithDepth[] {
    const rows = this.all<EventDbRow>(
      'SELECT * FROM events WHERE parent_id = ? ORDER BY sequence ASC',
      eventId
    );
    return rows.map(row => this.rowToEvent(row));
  }

  /**
   * Get all descendants of an event (children, grandchildren, etc.)
   * Uses recursive CTE for efficient tree traversal
   */
  getDescendants(eventId: EventId): EventWithDepth[] {
    const rows = this.all<EventDbRow>(
      `WITH RECURSIVE descendants(
        id, parent_id, session_id, workspace_id, type, timestamp, sequence,
        payload, content_blob_id, depth, role, tool_name, tool_call_id, turn,
        input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens,
        checksum, cte_depth
      ) AS (
        SELECT id, parent_id, session_id, workspace_id, type, timestamp, sequence,
               payload, content_blob_id, depth, role, tool_name, tool_call_id, turn,
               input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens,
               checksum, 0
        FROM events WHERE parent_id = ?
        UNION ALL
        SELECT e.id, e.parent_id, e.session_id, e.workspace_id, e.type, e.timestamp,
               e.sequence, e.payload, e.content_blob_id, e.depth, e.role, e.tool_name,
               e.tool_call_id, e.turn, e.input_tokens, e.output_tokens,
               e.cache_read_tokens, e.cache_creation_tokens, e.checksum, d.cte_depth + 1
        FROM events e
        INNER JOIN descendants d ON e.parent_id = d.id
        WHERE d.cte_depth < 10000
      )
      SELECT * FROM descendants ORDER BY sequence ASC`,
      eventId
    );

    return rows.map(row => this.rowToEvent(row));
  }

  /**
   * Count events in a session
   */
  countBySession(sessionId: SessionId): number {
    const row = this.get<{ count: number }>(
      'SELECT COUNT(*) as count FROM events WHERE session_id = ?',
      sessionId
    );
    return row?.count ?? 0;
  }

  /**
   * Count events by type in a session
   */
  countByType(sessionId: SessionId, type: EventType): number {
    const row = this.get<{ count: number }>(
      'SELECT COUNT(*) as count FROM events WHERE session_id = ? AND type = ?',
      sessionId,
      type
    );
    return row?.count ?? 0;
  }

  /**
   * Get the latest event for a session
   */
  getLatest(sessionId: SessionId): EventWithDepth | null {
    const row = this.get<EventDbRow>(
      'SELECT * FROM events WHERE session_id = ? ORDER BY sequence DESC LIMIT 1',
      sessionId
    );
    if (!row) return null;
    return this.rowToEvent(row);
  }

  /**
   * Get events since a specific sequence number
   */
  getSince(sessionId: SessionId, afterSequence: number): EventWithDepth[] {
    const rows = this.all<EventDbRow>(
      'SELECT * FROM events WHERE session_id = ? AND sequence > ? ORDER BY sequence ASC',
      sessionId,
      afterSequence
    );
    return rows.map(row => this.rowToEvent(row));
  }

  /**
   * Get events within a sequence range
   */
  getRange(
    sessionId: SessionId,
    fromSequence: number,
    toSequence: number
  ): EventWithDepth[] {
    const rows = this.all<EventDbRow>(
      'SELECT * FROM events WHERE session_id = ? AND sequence >= ? AND sequence <= ? ORDER BY sequence ASC',
      sessionId,
      fromSequence,
      toSequence
    );
    return rows.map(row => this.rowToEvent(row));
  }

  /**
   * Get events by workspace
   */
  getByWorkspace(
    workspaceId: WorkspaceId,
    options?: { limit?: number; offset?: number }
  ): EventWithDepth[] {
    let sql = 'SELECT * FROM events WHERE workspace_id = ? ORDER BY timestamp DESC';
    const params: unknown[] = [workspaceId];

    if (options?.limit) {
      sql += ' LIMIT ?';
      params.push(options.limit);
    }

    if (options?.offset) {
      sql += ' OFFSET ?';
      params.push(options.offset);
    }

    const rows = this.all<EventDbRow>(sql, ...params);
    return rows.map(row => this.rowToEvent(row));
  }

  /**
   * Check if an event exists
   */
  exists(eventId: EventId): boolean {
    const row = this.get<{ id: string }>('SELECT id FROM events WHERE id = ?', eventId);
    return row !== undefined;
  }

  /**
   * Delete an event (use with caution - events should normally be immutable)
   */
  delete(eventId: EventId): boolean {
    const result = this.run('DELETE FROM events WHERE id = ?', eventId);
    return result.changes > 0;
  }

  /**
   * Delete all events for a session
   */
  deleteBySession(sessionId: SessionId): number {
    const result = this.run('DELETE FROM events WHERE session_id = ?', sessionId);
    return result.changes;
  }

  /**
   * Get total event count
   */
  count(): number {
    const row = this.get<{ count: number }>('SELECT COUNT(*) as count FROM events');
    return row?.count ?? 0;
  }

  /**
   * Get token usage summary for a session
   */
  getTokenUsageSummary(sessionId: SessionId): TokenUsage {
    const row = this.get<{
      input_tokens: number;
      output_tokens: number;
      cache_read_tokens: number;
      cache_creation_tokens: number;
    }>(
      `SELECT
        COALESCE(SUM(input_tokens), 0) as input_tokens,
        COALESCE(SUM(output_tokens), 0) as output_tokens,
        COALESCE(SUM(cache_read_tokens), 0) as cache_read_tokens,
        COALESCE(SUM(cache_creation_tokens), 0) as cache_creation_tokens
      FROM events
      WHERE session_id = ?`,
      sessionId
    );

    return {
      inputTokens: row?.input_tokens ?? 0,
      outputTokens: row?.output_tokens ?? 0,
      cacheReadTokens: row?.cache_read_tokens ?? 0,
      cacheCreationTokens: row?.cache_creation_tokens ?? 0,
    };
  }

  // ===========================================================================
  // Private Helpers
  // ===========================================================================

  /**
   * Extract role from event type
   */
  private extractRole(type: EventType): string | null {
    if (type === 'message.user') return 'user';
    if (type === 'message.assistant') return 'assistant';
    if (type === 'message.system') return 'system';
    if (type === 'tool.call' || type === 'tool.result') return 'tool';
    return null;
  }

  /**
   * Extract tool info from event payload
   */
  private extractToolInfo(event: SessionEvent): {
    toolName: string | null;
    toolCallId: string | null;
    turn: number | null;
  } {
    if (!('payload' in event)) {
      return { toolName: null, toolCallId: null, turn: null };
    }

    const payload = event.payload as Record<string, unknown>;
    return {
      toolName: (payload.toolName ?? payload.name ?? null) as string | null,
      toolCallId: (payload.toolCallId ?? null) as string | null,
      turn: (payload.turn ?? null) as number | null,
    };
  }

  /**
   * Calculate depth from parent event
   */
  private async calculateDepth(parentId: EventId | null): Promise<number> {
    if (!parentId) return 0;

    const parent = this.getById(parentId);
    return parent ? parent.depth + 1 : 0;
  }

  /**
   * Extract token usage from event payload
   */
  private extractTokenUsage(event: SessionEvent): TokenUsage | null {
    if (!('payload' in event)) return null;

    const payload = event.payload as Record<string, unknown>;
    const usage = payload.tokenUsage as TokenUsage | undefined;

    return usage ?? null;
  }

  /**
   * Convert database row to EventWithDepth
   */
  private rowToEvent(row: EventDbRow): EventWithDepth {
    return {
      id: EventId(row.id),
      parentId: row.parent_id ? EventId(row.parent_id) : null,
      sessionId: SessionId(row.session_id),
      workspaceId: WorkspaceId(row.workspace_id),
      timestamp: row.timestamp,
      type: row.type as EventType,
      sequence: row.sequence,
      payload: rowUtils.parseJson(row.payload, {}),
      checksum: row.checksum ?? undefined,
      depth: row.depth ?? 0,
    } as EventWithDepth;
  }
}
