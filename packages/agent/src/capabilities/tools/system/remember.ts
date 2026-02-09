/**
 * @fileoverview Remember Tool
 *
 * The agent's memory recall and self-analysis tool. Queries the internal
 * event database to remember past work, retrieve stored content, and
 * debug session behavior.
 *
 * Actions:
 * - recall: Semantic memory search (default, uses vector embeddings)
 * - search: Keyword search via FTS5 (fallback for exact terms)
 * - schema: List tables and columns
 * - sessions: List recent sessions
 * - session: Get session details
 * - events: Get events (filter by session, type, turn)
 * - messages: Get conversation messages
 * - tools: Get tool executions
 * - logs: Get application logs
 * - stats: Database statistics
 * - read_blob: Read stored blob content
 */

import { Database, type SQLQueryBindings } from 'bun:sqlite';
import type { TronTool, TronToolResult, ToolExecutionOptions } from '@core/types/index.js';
import { createLogger } from '@infrastructure/logging/index.js';
import type { EmbeddingService } from '@infrastructure/embeddings/index.js';
import type { VectorRepository } from '@infrastructure/events/sqlite/repositories/vector.repo.js';

const logger = createLogger('tool:remember');

const REMEMBER_MAX_LIMIT = 500;

// =============================================================================
// Types
// =============================================================================

export interface RememberToolConfig {
  /** Path to the SQLite database */
  dbPath: string;
  /** Optional embedding service for semantic recall */
  embeddingService?: EmbeddingService;
  /** Optional vector repository for semantic recall */
  vectorRepo?: VectorRepository;
}

export interface RememberParams {
  action: string;
  session_id?: string;
  blob_id?: string;
  query?: string;
  type?: string;
  turn?: number;
  level?: string;
  limit?: number;
  offset?: number;
}

// =============================================================================
// Implementation
// =============================================================================

export class RememberTool implements TronTool<RememberParams> {
  readonly name = 'Remember';

  readonly description = `Your memory and self-analysis tool. Query your internal database to recall past work, review session history, and retrieve stored content.

Available actions:
- recall (default): Semantic memory search — "find memories about X". Uses vector similarity to find the most relevant past work even when exact keywords don't match. ALWAYS provide a query describing what you want to remember.
- search: Keyword search via exact term matching in memory ledger entries. Use when you know the exact term to search for.
- sessions: List recent sessions (title, tokens, cost)
- session: Get details for a specific session
- events: Get raw events (filter by session_id, type, turn)
- messages: Get conversation messages for a session
- tools: Get tool calls and results for a session
- logs: Get application logs
- stats: Get database statistics
- schema: List database tables and columns
- read_blob: Read stored content from blob storage

Search strategy: Use "recall" for finding relevant past work (semantic). Use "search" for exact keyword matching. Start narrow (query + small limit), then broaden if needed.
Use read_blob to retrieve full content when tool results reference a blob_id.`;

  readonly parameters = {
    type: 'object' as const,
    properties: {
      action: {
        type: 'string' as const,
        enum: ['recall', 'search', 'memory', 'sessions', 'session', 'events', 'messages', 'tools', 'logs', 'stats', 'schema', 'read_blob'],
        description: 'The action to perform. Use "recall" for semantic search (recommended), "search" for keyword matching.',
      },
      session_id: {
        type: 'string' as const,
        description: 'Session ID for session-scoped queries (can be prefix)',
      },
      blob_id: {
        type: 'string' as const,
        description: 'Blob ID to read (for read_blob action)',
      },
      query: {
        type: 'string' as const,
        description: 'Search query — for recall: describe what you want to remember; for search: exact keyword to match.',
      },
      type: {
        type: 'string' as const,
        description: 'Filter events by type (e.g., "message.user", "memory.ledger")',
      },
      turn: {
        type: 'number' as const,
        description: 'Filter events by turn number',
      },
      level: {
        type: 'string' as const,
        enum: ['trace', 'debug', 'info', 'warn', 'error', 'fatal'],
        description: 'Minimum log level',
      },
      limit: {
        type: 'number' as const,
        description: 'Maximum results to return (default: 20, max: 500)',
      },
      offset: {
        type: 'number' as const,
        description: 'Number of results to skip',
      },
    },
    required: ['action'] as string[],
  };

  readonly label = 'Remember';
  readonly category = 'custom' as const;
  readonly executionContract = 'options' as const;

  private dbPath: string;
  private _db: Database | null = null;
  private embeddingService?: EmbeddingService;
  private vectorRepo?: VectorRepository;

  constructor(config: RememberToolConfig) {
    this.dbPath = config.dbPath;
    this.embeddingService = config.embeddingService;
    this.vectorRepo = config.vectorRepo;
  }

  private get db(): Database {
    if (!this._db) {
      this._db = new Database(this.dbPath, { readonly: true });
    }
    return this._db!;
  }

  close(): void {
    if (this._db) {
      this._db.close();
      this._db = null;
    }
  }

  async execute(params: RememberParams, _options?: ToolExecutionOptions): Promise<TronToolResult> {
    const limit = Math.max(1, Math.min(params.limit ?? 20, REMEMBER_MAX_LIMIT));
    const offset = Math.max(0, params.offset ?? 0);

    try {
      switch (params.action) {
        case 'recall':
          return this.recallMemory(params.query, limit);

        // 'memory' is kept as an alias for backward compatibility
        case 'memory':
        case 'search':
          return this.searchMemory(params.session_id, params.query, limit, offset);

        case 'schema':
          return this.getSchema();

        case 'sessions':
          return this.listSessions(limit, offset);

        case 'session':
          if (!params.session_id) {
            return { content: 'session_id is required for session action', isError: true };
          }
          return this.getSession(params.session_id);

        case 'events':
          return this.getEvents(params.session_id, params.type, params.turn, limit, offset);

        case 'messages':
          if (!params.session_id) {
            return { content: 'session_id is required for messages action', isError: true };
          }
          return this.getMessages(params.session_id, limit);

        case 'tools':
          if (!params.session_id) {
            return { content: 'session_id is required for tools action', isError: true };
          }
          return this.getToolCalls(params.session_id, limit);

        case 'logs':
          return this.getLogs(params.session_id, params.level, limit, offset);

        case 'stats':
          return this.getStats();

        case 'read_blob':
          if (!params.blob_id) {
            return { content: 'blob_id is required for read_blob action', isError: true };
          }
          return this.readBlob(params.blob_id);

        default:
          return { content: `Unknown action: ${params.action}`, isError: true };
      }
    } catch (error) {
      logger.error('Remember tool error', { action: params.action, error });
      return {
        content: `Error: ${error instanceof Error ? error.message : String(error)}`,
        isError: true,
      };
    }
  }

  // ===========================================================================
  // Recall — semantic memory search (primary)
  // ===========================================================================

  private async recallMemory(query: string | undefined, limit: number): Promise<TronToolResult> {
    if (!query) {
      return { content: 'query is required for recall action — describe what you want to remember', isError: true };
    }

    // If embedding service and vector repo are available, use semantic search
    if (this.embeddingService?.isReady() && this.vectorRepo) {
      try {
        const queryEmbedding = await this.embeddingService.embedSingle(query);
        const results = this.vectorRepo.search(queryEmbedding, { limit });

        if (results.length === 0) {
          // Fall back to FTS5 search if no vector results
          return this.searchMemory(undefined, query, limit, 0);
        }

        // Look up event payloads for the results
        const eventIds = results.map(r => r.eventId);
        const placeholders = eventIds.map(() => '?').join(',');
        const rows = this.db.prepare(`
          SELECT id, session_id, timestamp, payload
          FROM events
          WHERE id IN (${placeholders})
        `).all(...eventIds) as Array<{
          id: string;
          session_id: string;
          timestamp: string;
          payload: string;
        }>;

        // Order by vector search ranking
        const rowMap = new Map(rows.map(r => [r.id, r]));
        const orderedRows = results
          .map(r => {
            const row = rowMap.get(r.eventId);
            return row ? { ...row, distance: r.distance } : null;
          })
          .filter((r): r is NonNullable<typeof r> => r !== null);

        return this.formatRecallRows(orderedRows, query);
      } catch (error) {
        logger.warn('Semantic recall failed, falling back to FTS5', { error: (error as Error).message });
        // Fall back to FTS5 keyword search
        return this.searchMemory(undefined, query, limit, 0);
      }
    }

    // No embedding service — fall back to FTS5 search
    return this.searchMemory(undefined, query, limit, 0);
  }

  /**
   * Format semantic recall results with relevance scores
   */
  private formatRecallRows(
    rows: Array<{ id: string; session_id: string; timestamp: string; payload: string; distance: number }>,
    query: string
  ): TronToolResult {
    if (rows.length === 0) {
      return { content: `No memories found matching "${query}"`, isError: false };
    }

    const lines = [`Memory Recall (query: "${query}", ${rows.length} results):`, ''];

    for (const row of rows) {
      try {
        const payload = JSON.parse(row.payload);
        const relevance = Math.round((1 - row.distance) * 100);
        lines.push(`[${row.timestamp}] ${payload.title ?? 'Untitled'} (${relevance}% relevant)`);
        lines.push(`  Session: ${row.session_id}`);
        lines.push(`  Type: ${payload.entryType ?? '?'} | Status: ${payload.status ?? '?'}`);
        if (payload.input) lines.push(`  Request: ${payload.input}`);
        if (Array.isArray(payload.actions) && payload.actions.length > 0) {
          lines.push(`  Actions: ${payload.actions.join('; ')}`);
        }
        if (Array.isArray(payload.files) && payload.files.length > 0) {
          const fileStrs = payload.files.map((f: Record<string, unknown>) =>
            `${f.op ?? '?'}:${f.path ?? '?'}`
          );
          lines.push(`  Files: ${fileStrs.join(', ')}`);
        }
        if (Array.isArray(payload.decisions) && payload.decisions.length > 0) {
          for (const d of payload.decisions) {
            if (d && typeof d === 'object') {
              lines.push(`  Decision: ${(d as Record<string, unknown>).choice ?? '?'} — ${(d as Record<string, unknown>).reason ?? ''}`);
            }
          }
        }
        if (Array.isArray(payload.lessons) && payload.lessons.length > 0) {
          lines.push(`  Lessons: ${payload.lessons.join('; ')}`);
        }
      } catch {
        lines.push(`[${row.timestamp}] (could not parse payload)`);
      }
      lines.push('');
    }

    return { content: lines.join('\n'), isError: false };
  }

  // ===========================================================================
  // Search — keyword-based memory search (FTS5)
  // ===========================================================================

  private searchMemory(
    sessionId: string | undefined,
    searchQuery: string | undefined,
    limit: number,
    offset: number
  ): TronToolResult {
    // When a search query is provided and events_fts exists, use FTS5 for ranked results
    if (searchQuery && this.hasFtsTable()) {
      return this.searchMemoryFts(sessionId, searchQuery, limit, offset);
    }

    // Fallback: direct table scan (no query or no FTS table)
    let query = `
      SELECT id, session_id, timestamp, payload
      FROM events
      WHERE type = 'memory.ledger'
    `;
    const params: SQLQueryBindings[] = [];

    if (sessionId) {
      query += ` AND (session_id = ? OR session_id LIKE ?)`;
      params.push(sessionId, `${sessionId}%`);
    }

    query += ` ORDER BY timestamp DESC LIMIT ? OFFSET ?`;
    params.push(limit, offset);

    const rows = this.db.prepare(query).all(...params) as Array<{
      id: string;
      session_id: string;
      timestamp: string;
      payload: string;
    }>;

    return this.formatMemoryRows(rows);
  }

  /**
   * Search memory ledger entries using FTS5 full-text search with BM25 ranking
   */
  private searchMemoryFts(
    sessionId: string | undefined,
    searchQuery: string,
    limit: number,
    offset: number
  ): TronToolResult {
    // Build FTS5 query — split into individual terms joined by OR for broad matching.
    // Each term is quoted to handle special characters (hyphens, dots, etc.).
    // BM25 ranks results with more matching terms higher.
    const terms = searchQuery.split(/\s+/).filter(t => t.length > 0);
    const ftsQuery = terms.length === 1
      ? `content:"${terms[0]!.replace(/"/g, '""')}"`
      : `content:(${terms.map(t => `"${t.replace(/"/g, '""')}"`).join(' OR ')})`;

    let sql = `
      SELECT
        e.id, e.session_id, e.timestamp, e.payload,
        bm25(events_fts) as score
      FROM events_fts
      JOIN events e ON events_fts.id = e.id
      WHERE events_fts MATCH ?
        AND events_fts.type = 'memory.ledger'
    `;
    const params: SQLQueryBindings[] = [ftsQuery];

    if (sessionId) {
      sql += ` AND (events_fts.session_id = ? OR events_fts.session_id LIKE ?)`;
      params.push(sessionId, `${sessionId}%`);
    }

    sql += ` ORDER BY score LIMIT ? OFFSET ?`;
    params.push(limit, offset);

    const rows = this.db.prepare(sql).all(...params) as Array<{
      id: string;
      session_id: string;
      timestamp: string;
      payload: string;
      score: number;
    }>;

    return this.formatMemoryRows(rows, searchQuery);
  }

  /**
   * Check if events_fts table exists (may not in test databases)
   */
  private hasFtsTable(): boolean {
    try {
      const row = this.db.prepare(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='events_fts'"
      ).get() as { name: string } | undefined;
      return !!row;
    } catch {
      return false;
    }
  }

  /**
   * Format memory ledger rows into readable output
   */
  private formatMemoryRows(
    rows: Array<{ id: string; session_id: string; timestamp: string; payload: string; score?: number }>,
    searchQuery?: string
  ): TronToolResult {
    if (rows.length === 0) {
      const msg = searchQuery
        ? `No memory ledger entries found matching "${searchQuery}"`
        : 'No memory ledger entries found';
      return { content: msg, isError: false };
    }

    const lines = searchQuery
      ? [`Memory Search (keyword: "${searchQuery}", ${rows.length} results):`, '']
      : ['Memory Ledger:', ''];

    for (const row of rows) {
      try {
        const payload = JSON.parse(row.payload);
        lines.push(`[${row.timestamp}] ${payload.title ?? 'Untitled'}`);
        lines.push(`  Session: ${row.session_id}`);
        lines.push(`  Type: ${payload.entryType ?? '?'} | Status: ${payload.status ?? '?'}`);
        if (payload.input) lines.push(`  Request: ${payload.input}`);
        if (Array.isArray(payload.actions) && payload.actions.length > 0) {
          lines.push(`  Actions: ${payload.actions.join('; ')}`);
        }
        if (Array.isArray(payload.files) && payload.files.length > 0) {
          const fileStrs = payload.files.map((f: Record<string, unknown>) =>
            `${f.op ?? '?'}:${f.path ?? '?'}`
          );
          lines.push(`  Files: ${fileStrs.join(', ')}`);
        }
        if (Array.isArray(payload.decisions) && payload.decisions.length > 0) {
          for (const d of payload.decisions) {
            if (d && typeof d === 'object') {
              lines.push(`  Decision: ${(d as Record<string, unknown>).choice ?? '?'} — ${(d as Record<string, unknown>).reason ?? ''}`);
            }
          }
        }
        if (Array.isArray(payload.lessons) && payload.lessons.length > 0) {
          lines.push(`  Lessons: ${payload.lessons.join('; ')}`);
        }
      } catch {
        lines.push(`[${row.timestamp}] (could not parse payload)`);
      }
      lines.push('');
    }

    return { content: lines.join('\n'), isError: false };
  }

  // ===========================================================================
  // Schema
  // ===========================================================================

  private getSchema(): TronToolResult {
    const tables = this.db
      .prepare(`SELECT name FROM sqlite_master WHERE type='table' ORDER BY name`)
      .all() as Array<{ name: string }>;

    const schema: Record<string, string[]> = {};

    for (const { name } of tables) {
      if (name.startsWith('sqlite_') || name.endsWith('_fts')) continue;

      const columns = this.db.prepare(`PRAGMA table_info("${name.replace(/"/g, '""')}")`).all() as Array<{
        name: string;
        type: string;
      }>;

      schema[name] = columns.map((c) => `${c.name} (${c.type})`);
    }

    const lines = ['Database Schema:', ''];
    for (const [table, columns] of Object.entries(schema)) {
      lines.push(`${table}:`);
      columns.forEach((col) => lines.push(`  - ${col}`));
      lines.push('');
    }

    lines.push('Tips:');
    lines.push('- Use session_id prefix matching: "sess_abc" matches "sess_abc123..."');
    lines.push('- Use read_blob to retrieve full content from offloaded tool results');

    return { content: lines.join('\n'), isError: false };
  }

  // ===========================================================================
  // Sessions
  // ===========================================================================

  private listSessions(limit: number, offset: number): TronToolResult {
    const rows = this.db
      .prepare(
        `SELECT id, title, created_at, last_activity_at, event_count, turn_count,
                total_input_tokens + total_output_tokens as total_tokens, total_cost
         FROM sessions
         ORDER BY last_activity_at DESC
         LIMIT ? OFFSET ?`
      )
      .all(limit, offset) as Array<{
      id: string;
      title: string | null;
      created_at: string;
      last_activity_at: string;
      event_count: number;
      turn_count: number;
      total_tokens: number;
      total_cost: number;
    }>;

    if (rows.length === 0) {
      return { content: 'No sessions found', isError: false };
    }

    const lines = ['Recent Sessions:', ''];
    for (const row of rows) {
      lines.push(`${row.id}`);
      lines.push(`  Title: ${row.title || '(untitled)'}`);
      lines.push(`  Last activity: ${row.last_activity_at}`);
      lines.push(`  Events: ${row.event_count}, Turns: ${row.turn_count}`);
      lines.push(`  Tokens: ${row.total_tokens}, Cost: $${row.total_cost.toFixed(4)}`);
      lines.push('');
    }

    return { content: lines.join('\n'), isError: false };
  }

  // ===========================================================================
  // Session detail
  // ===========================================================================

  private getSession(sessionId: string): TronToolResult {
    const row = this.db
      .prepare(
        `SELECT s.*, w.path as workspace_path
         FROM sessions s
         LEFT JOIN workspaces w ON s.workspace_id = w.id
         WHERE s.id = ? OR s.id LIKE ?
         LIMIT 1`
      )
      .get(sessionId, `${sessionId}%`) as Record<string, unknown> | undefined;

    if (!row) {
      return { content: `Session not found: ${sessionId}`, isError: true };
    }

    const lines = ['Session Details:', ''];
    for (const [key, value] of Object.entries(row)) {
      if (value !== null) {
        lines.push(`${key}: ${value}`);
      }
    }

    return { content: lines.join('\n'), isError: false };
  }

  // ===========================================================================
  // Events
  // ===========================================================================

  private getEvents(
    sessionId: string | undefined,
    type: string | undefined,
    turn: number | undefined,
    limit: number,
    offset: number
  ): TronToolResult {
    let query = `
      SELECT id, sequence, type, timestamp, turn, tool_name,
             input_tokens, output_tokens, substr(payload, 1, 500) as payload_preview
      FROM events
      WHERE 1=1
    `;
    const params: SQLQueryBindings[] = [];

    if (sessionId) {
      query += ` AND (session_id = ? OR session_id LIKE ?)`;
      params.push(sessionId, `${sessionId}%`);
    }

    if (type) {
      query += ` AND type LIKE ?`;
      params.push(`%${type}%`);
    }

    if (turn !== undefined) {
      query += ` AND turn = ?`;
      params.push(turn);
    }

    query += ` ORDER BY sequence DESC LIMIT ? OFFSET ?`;
    params.push(limit, offset);

    const rows = this.db.prepare(query).all(...params) as Array<{
      id: string;
      sequence: number;
      type: string;
      timestamp: string;
      turn: number | null;
      tool_name: string | null;
      input_tokens: number | null;
      output_tokens: number | null;
      payload_preview: string;
    }>;

    if (rows.length === 0) {
      return { content: 'No events found', isError: false };
    }

    const lines = ['Events:', ''];
    for (const row of rows) {
      lines.push(`[${row.sequence}] ${row.type} @ ${row.timestamp}`);
      if (row.turn !== null) lines.push(`  Turn: ${row.turn}`);
      if (row.tool_name) lines.push(`  Tool: ${row.tool_name}`);
      if (row.input_tokens || row.output_tokens) {
        lines.push(`  Tokens: in=${row.input_tokens || 0}, out=${row.output_tokens || 0}`);
      }
      if (row.payload_preview) {
        const preview = row.payload_preview.length >= 500
          ? row.payload_preview + '...'
          : row.payload_preview;
        lines.push(`  Payload: ${preview}`);
      }
      lines.push('');
    }

    return { content: lines.join('\n'), isError: false };
  }

  // ===========================================================================
  // Messages
  // ===========================================================================

  private getMessages(sessionId: string, limit: number): TronToolResult {
    const rows = this.db
      .prepare(
        `SELECT sequence, type, timestamp, turn, payload
         FROM events
         WHERE (session_id = ? OR session_id LIKE ?)
           AND type IN ('message.user', 'message.assistant')
         ORDER BY sequence
         LIMIT ?`
      )
      .all(sessionId, `${sessionId}%`, limit) as Array<{
      sequence: number;
      type: string;
      timestamp: string;
      turn: number | null;
      payload: string;
    }>;

    if (rows.length === 0) {
      return { content: 'No messages found', isError: false };
    }

    const lines = ['Messages:', ''];
    for (const row of rows) {
      const role = row.type === 'message.user' ? 'USER' : 'ASSISTANT';
      lines.push(`[${row.sequence}] ${role} (turn ${row.turn ?? '?'})`);

      try {
        const payload = JSON.parse(row.payload);
        const content = payload.content;
        if (typeof content === 'string') {
          lines.push(`  ${content.slice(0, 200)}${content.length > 200 ? '...' : ''}`);
        } else if (Array.isArray(content)) {
          const textBlocks = content.filter((b: Record<string, unknown>) => b?.type === 'text');
          const text = textBlocks.map((b: Record<string, unknown>) => String(b?.text ?? '')).join(' ');
          lines.push(`  ${text.slice(0, 200)}${text.length > 200 ? '...' : ''}`);
        }
      } catch {
        lines.push(`  (could not parse payload)`);
      }
      lines.push('');
    }

    return { content: lines.join('\n'), isError: false };
  }

  // ===========================================================================
  // Tool calls
  // ===========================================================================

  private getToolCalls(sessionId: string, limit: number): TronToolResult {
    const rows = this.db
      .prepare(
        `SELECT sequence, type, timestamp, turn, tool_name, tool_call_id, payload
         FROM events
         WHERE (session_id = ? OR session_id LIKE ?)
           AND (type = 'tool.call' OR type = 'tool.result')
         ORDER BY sequence
         LIMIT ?`
      )
      .all(sessionId, `${sessionId}%`, limit) as Array<{
      sequence: number;
      type: string;
      timestamp: string;
      turn: number | null;
      tool_name: string | null;
      tool_call_id: string | null;
      payload: string;
    }>;

    if (rows.length === 0) {
      return { content: 'No tool calls found', isError: false };
    }

    const lines = ['Tool Calls:', ''];
    for (const row of rows) {
      const isCall = row.type === 'tool.call';
      lines.push(`[${row.sequence}] ${isCall ? 'CALL' : 'RESULT'}: ${row.tool_name || '?'}`);

      try {
        const payload = JSON.parse(row.payload);
        if (isCall && payload.arguments) {
          const argsStr = JSON.stringify(payload.arguments);
          lines.push(`  Args: ${argsStr.slice(0, 150)}${argsStr.length > 150 ? '...' : ''}`);
        } else if (!isCall) {
          if (payload.blobId) {
            lines.push(`  [Stored in blob: ${payload.blobId}]`);
          }
          const content = payload.content || '';
          lines.push(`  Result: ${content.slice(0, 150)}${content.length > 150 ? '...' : ''}`);
          if (payload.isError) lines.push(`  ERROR`);
        }
      } catch {
        lines.push(`  (could not parse payload)`);
      }
      lines.push('');
    }

    return { content: lines.join('\n'), isError: false };
  }

  // ===========================================================================
  // Logs
  // ===========================================================================

  private getLogs(
    sessionId: string | undefined,
    level: string | undefined,
    limit: number,
    offset: number
  ): TronToolResult {
    const levelMap: Record<string, number> = {
      trace: 10,
      debug: 20,
      info: 30,
      warn: 40,
      error: 50,
      fatal: 60,
    };

    let query = `
      SELECT timestamp, level, component, message, error_message
      FROM logs
      WHERE 1=1
    `;
    const params: SQLQueryBindings[] = [];

    if (sessionId) {
      query += ` AND (session_id = ? OR session_id LIKE ?)`;
      params.push(sessionId, `${sessionId}%`);
    }

    if (level && levelMap[level]) {
      query += ` AND level_num >= ?`;
      params.push(levelMap[level]);
    }

    query += ` ORDER BY timestamp DESC LIMIT ? OFFSET ?`;
    params.push(limit, offset);

    const rows = this.db.prepare(query).all(...params) as Array<{
      timestamp: string;
      level: string;
      component: string;
      message: string;
      error_message: string | null;
    }>;

    if (rows.length === 0) {
      return { content: 'No logs found', isError: false };
    }

    const lines = ['Logs:', ''];
    for (const row of rows) {
      lines.push(`[${row.timestamp}] ${row.level.toUpperCase()} ${row.component}`);
      lines.push(`  ${row.message}`);
      if (row.error_message) {
        lines.push(`  Error: ${row.error_message}`);
      }
      lines.push('');
    }

    return { content: lines.join('\n'), isError: false };
  }

  // ===========================================================================
  // Stats
  // ===========================================================================

  private getStats(): TronToolResult {
    const count = (table: string): number => {
      try {
        return (this.db.prepare(`SELECT COUNT(*) as count FROM "${table.replace(/"/g, '""')}"`).get() as { count: number }).count;
      } catch {
        return 0;
      }
    };

    const sessions = count('sessions');
    const events = count('events');
    const blobs = count('blobs');
    const logCount = count('logs');

    let blobSize = 0;
    let totalCost = 0;
    try {
      blobSize = (this.db.prepare('SELECT COALESCE(SUM(size_original), 0) as size FROM blobs').get() as { size: number }).size;
    } catch { /* table may not exist */ }
    try {
      totalCost = (this.db.prepare('SELECT COALESCE(SUM(total_cost), 0) as cost FROM sessions').get() as { cost: number }).cost;
    } catch { /* table may not exist */ }

    const lines = [
      'Database Statistics:',
      '',
      `Sessions: ${sessions.toLocaleString()}`,
      `Events: ${events.toLocaleString()}`,
      `Logs: ${logCount.toLocaleString()}`,
      `Blobs: ${blobs.toLocaleString()}`,
      `Blob storage: ${(blobSize / 1024).toFixed(1)} KB`,
      `Total cost: $${totalCost.toFixed(4)}`,
    ];

    return { content: lines.join('\n'), isError: false };
  }

  // ===========================================================================
  // Blob reader
  // ===========================================================================

  private readBlob(blobId: string): TronToolResult {
    const row = this.db
      .prepare('SELECT id, hash, content, mime_type, size_original, created_at FROM blobs WHERE id = ?')
      .get(blobId) as {
      id: string;
      hash: string;
      content: Buffer;
      mime_type: string;
      size_original: number;
      created_at: string;
    } | undefined;

    if (!row) {
      return { content: `Blob not found: ${blobId}`, isError: true };
    }

    const content = row.content.toString('utf-8');

    const lines = [
      `Blob: ${row.id}`,
      `Size: ${row.size_original.toLocaleString()} bytes`,
      `Type: ${row.mime_type}`,
      `Created: ${row.created_at}`,
      '',
      '--- Content ---',
      content,
    ];

    return {
      content: lines.join('\n'),
      isError: false,
      details: {
        blobId: row.id,
        hash: row.hash,
        sizeOriginal: row.size_original,
        mimeType: row.mime_type,
        createdAt: row.created_at,
      },
    };
  }
}
