/**
 * @fileoverview Search Repository
 *
 * Handles FTS5 full-text search indexing and querying for events.
 */

import type { SQLQueryBindings } from 'bun:sqlite';
import { BaseRepository } from './base.js';
import {
  EventId,
  SessionId,
  WorkspaceId,
  type SessionEvent,
  type EventType,
  type SearchResult,
} from '../../types.js';

/**
 * Options for searching events
 */
export interface SearchOptions {
  workspaceId?: WorkspaceId;
  sessionId?: SessionId;
  types?: EventType[];
  limit?: number;
  offset?: number;
}

/**
 * Repository for FTS5 search operations
 */
export class SearchRepository extends BaseRepository {
  /**
   * Index an event for full-text search
   */
  index(event: SessionEvent): void {
    const content = this.extractSearchableContent(event);
    const toolName = this.extractToolName(event);

    this.run(
      `INSERT INTO events_fts (id, session_id, type, content, tool_name)
       VALUES (?, ?, ?, ?, ?)`,
      event.id,
      event.sessionId,
      event.type,
      content,
      toolName
    );
  }

  /**
   * Index multiple events in a batch
   */
  indexBatch(events: SessionEvent[]): void {
    if (events.length === 0) return;

    this.transaction(() => {
      for (const event of events) {
        this.index(event);
      }
    });
  }

  /**
   * Search events using FTS5 query
   * Uses BM25 scoring for relevance ranking
   */
  search(query: string, options: SearchOptions = {}): SearchResult[] {
    let sql = `
      SELECT
        events_fts.id,
        events_fts.session_id,
        events_fts.type,
        snippet(events_fts, 3, '<mark>', '</mark>', '...', 64) as snippet,
        bm25(events_fts) as score,
        e.timestamp
      FROM events_fts
      JOIN events e ON events_fts.id = e.id
      WHERE events_fts MATCH ?
    `;

    const params: SQLQueryBindings[] = [query];

    if (options.workspaceId) {
      sql += ' AND e.workspace_id = ?';
      params.push(options.workspaceId);
    }

    if (options.sessionId) {
      sql += ' AND events_fts.session_id = ?';
      params.push(options.sessionId);
    }

    if (options.types && options.types.length > 0) {
      const placeholders = this.inPlaceholders(options.types);
      sql += ` AND events_fts.type IN (${placeholders})`;
      params.push(...options.types);
    }

    sql += ' ORDER BY score';

    if (options.limit) {
      sql += ' LIMIT ?';
      params.push(options.limit);
    }

    if (options.offset) {
      sql += ' OFFSET ?';
      params.push(options.offset);
    }

    const rows = this.all<{
      id: string;
      session_id: string;
      type: string;
      snippet: string | null;
      score: number;
      timestamp: string;
    }>(sql, ...params);

    return rows.map(row => ({
      eventId: EventId(row.id),
      sessionId: SessionId(row.session_id),
      type: row.type as EventType,
      timestamp: row.timestamp,
      snippet: row.snippet || '',
      score: Math.abs(row.score),
    }));
  }

  /**
   * Search within a specific session
   */
  searchInSession(sessionId: SessionId, query: string, limit?: number): SearchResult[] {
    return this.search(query, { sessionId, limit });
  }

  /**
   * Search within a specific workspace
   */
  searchInWorkspace(workspaceId: WorkspaceId, query: string, limit?: number): SearchResult[] {
    return this.search(query, { workspaceId, limit });
  }

  /**
   * Search for events by tool name
   */
  searchByToolName(toolName: string, options: SearchOptions = {}): SearchResult[] {
    let sql = `
      SELECT
        events_fts.id,
        events_fts.session_id,
        events_fts.type,
        snippet(events_fts, 4, '<mark>', '</mark>', '...', 64) as snippet,
        bm25(events_fts) as score,
        e.timestamp
      FROM events_fts
      JOIN events e ON events_fts.id = e.id
      WHERE events_fts.tool_name MATCH ?
    `;

    const params: SQLQueryBindings[] = [toolName];

    if (options.workspaceId) {
      sql += ' AND e.workspace_id = ?';
      params.push(options.workspaceId);
    }

    if (options.sessionId) {
      sql += ' AND events_fts.session_id = ?';
      params.push(options.sessionId);
    }

    sql += ' ORDER BY score';

    if (options.limit) {
      sql += ' LIMIT ?';
      params.push(options.limit);
    }

    const rows = this.all<{
      id: string;
      session_id: string;
      type: string;
      snippet: string | null;
      score: number;
      timestamp: string;
    }>(sql, ...params);

    return rows.map(row => ({
      eventId: EventId(row.id),
      sessionId: SessionId(row.session_id),
      type: row.type as EventType,
      timestamp: row.timestamp,
      snippet: row.snippet || '',
      score: Math.abs(row.score),
    }));
  }

  /**
   * Remove event from search index
   */
  remove(eventId: EventId): boolean {
    const result = this.run('DELETE FROM events_fts WHERE id = ?', eventId);
    return result.changes > 0;
  }

  /**
   * Remove all events for a session from search index
   */
  removeBySession(sessionId: SessionId): number {
    const result = this.run('DELETE FROM events_fts WHERE session_id = ?', sessionId);
    return result.changes;
  }

  /**
   * Check if event is indexed
   */
  isIndexed(eventId: EventId): boolean {
    const row = this.get<{ id: string }>('SELECT id FROM events_fts WHERE id = ?', eventId);
    return row !== undefined;
  }

  /**
   * Count indexed events for a session
   */
  countBySession(sessionId: SessionId): number {
    const row = this.get<{ count: number }>(
      'SELECT COUNT(*) as count FROM events_fts WHERE session_id = ?',
      sessionId
    );
    return row?.count ?? 0;
  }

  /**
   * Rebuild the search index for a session from events table
   * Useful for recovery or re-indexing after schema changes
   */
  rebuildSessionIndex(sessionId: SessionId): number {
    // First remove existing index entries
    this.removeBySession(sessionId);

    // Get all events for the session
    const events = this.all<{
      id: string;
      session_id: string;
      type: string;
      payload: string;
    }>(
      `SELECT id, session_id, type, payload
       FROM events
       WHERE session_id = ?
       ORDER BY sequence ASC`,
      sessionId
    );

    // Index each event
    let indexed = 0;
    for (const row of events) {
      const content = this.extractContentFromPayload(row.payload);
      const toolName = this.extractToolNameFromPayload(row.payload);

      this.run(
        `INSERT INTO events_fts (id, session_id, type, content, tool_name)
         VALUES (?, ?, ?, ?, ?)`,
        row.id,
        row.session_id,
        row.type,
        content,
        toolName
      );
      indexed++;
    }

    return indexed;
  }

  // ===========================================================================
  // Private Helpers
  // ===========================================================================

  /**
   * Extract searchable content from event payload
   */
  private extractSearchableContent(event: SessionEvent): string {
    if (!('payload' in event)) return '';

    const payload = event.payload as Record<string, unknown>;
    return this.extractContentFromValue(payload.content);
  }

  /**
   * Extract content from a value (string or block array)
   */
  private extractContentFromValue(content: unknown): string {
    if (typeof content === 'string') {
      return content;
    }

    if (Array.isArray(content)) {
      return content
        .filter((block): block is { type: string; text: string } =>
          typeof block === 'object' &&
          block !== null &&
          (block as Record<string, unknown>).type === 'text'
        )
        .map(block => block.text)
        .join(' ');
    }

    return '';
  }

  /**
   * Extract tool name from event payload
   */
  private extractToolName(event: SessionEvent): string {
    if (!('payload' in event)) return '';

    const payload = event.payload as Record<string, unknown>;
    return (payload.toolName ?? payload.name ?? '') as string;
  }

  /**
   * Extract content from stored JSON payload string
   */
  private extractContentFromPayload(payloadStr: string): string {
    try {
      const payload = JSON.parse(payloadStr);
      return this.extractContentFromValue(payload.content);
    } catch {
      return '';
    }
  }

  /**
   * Extract tool name from stored JSON payload string
   */
  private extractToolNameFromPayload(payloadStr: string): string {
    try {
      const payload = JSON.parse(payloadStr);
      return (payload.toolName ?? payload.name ?? '') as string;
    } catch {
      return '';
    }
  }
}
