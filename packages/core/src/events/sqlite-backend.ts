/**
 * @fileoverview SQLite Backend for Event Store
 *
 * Provides the persistence layer for the event-sourced session tree.
 * Uses better-sqlite3 for synchronous, fast SQLite operations.
 */

import Database from 'better-sqlite3';
import * as crypto from 'crypto';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';
import {
  EventId,
  SessionId,
  WorkspaceId,
  BranchId,
  type SessionEvent,
  type EventType,
  type Workspace,
  type SearchResult,
  type TokenUsage,
} from './types.js';

// =============================================================================
// Types
// =============================================================================

export interface SQLiteBackendConfig {
  /** Path to SQLite database file, or ':memory:' for in-memory */
  dbPath: string;
  /** Enable WAL mode (default: true) */
  enableWAL?: boolean;
  /** Busy timeout in milliseconds (default: 5000) */
  busyTimeout?: number;
}

export interface CreateWorkspaceOptions {
  path: string;
  name?: string;
}

export interface CreateSessionOptions {
  workspaceId: WorkspaceId;
  workingDirectory: string;
  model: string;
  provider: string;
  title?: string;
  tags?: string[];
  parentSessionId?: SessionId;
  forkFromEventId?: EventId;
}

export interface SessionRow {
  id: SessionId;
  workspaceId: WorkspaceId;
  headEventId: EventId | null;
  rootEventId: EventId | null;
  title: string | null;
  status: 'active' | 'ended' | 'archived';
  model: string;
  provider: string;
  workingDirectory: string;
  parentSessionId: SessionId | null;
  forkFromEventId: EventId | null;
  createdAt: string;
  lastActivityAt: string;
  endedAt: string | null;
  eventCount: number;
  messageCount: number;
  turnCount: number;
  totalInputTokens: number;
  totalOutputTokens: number;
  tags: string[];
}

export interface CreateBranchOptions {
  sessionId: SessionId;
  name: string;
  description?: string;
  rootEventId: EventId;
  headEventId: EventId;
  isDefault?: boolean;
}

export interface BranchRow {
  id: BranchId;
  sessionId: SessionId;
  name: string;
  description: string | null;
  rootEventId: EventId;
  headEventId: EventId;
  isDefault: boolean;
  createdAt: string;
  lastActivityAt: string;
}

export interface ListSessionsOptions {
  workspaceId?: WorkspaceId;
  status?: 'active' | 'ended' | 'archived';
  limit?: number;
  offset?: number;
  orderBy?: 'createdAt' | 'lastActivityAt';
  order?: 'asc' | 'desc';
}

export interface SearchOptions {
  workspaceId?: WorkspaceId;
  sessionId?: SessionId;
  types?: EventType[];
  limit?: number;
  offset?: number;
}

export interface IncrementCountersOptions {
  eventCount?: number;
  messageCount?: number;
  turnCount?: number;
  inputTokens?: number;
  outputTokens?: number;
}

// =============================================================================
// SQLite Backend Implementation
// =============================================================================

export class SQLiteBackend {
  private db: Database.Database | null = null;
  private dbPath: string;
  private config: SQLiteBackendConfig;
  private initialized = false;

  constructor(dbPath: string, config?: Partial<SQLiteBackendConfig>) {
    this.dbPath = dbPath;
    this.config = {
      dbPath,
      enableWAL: config?.enableWAL ?? true,
      busyTimeout: config?.busyTimeout ?? 5000,
    };
  }

  // ===========================================================================
  // Lifecycle
  // ===========================================================================

  async initialize(): Promise<void> {
    if (this.initialized) return;

    this.db = new Database(this.dbPath);

    // Configure database
    this.db.pragma('journal_mode = WAL');
    this.db.pragma(`busy_timeout = ${this.config.busyTimeout}`);
    this.db.pragma('foreign_keys = ON');
    this.db.pragma('synchronous = NORMAL');
    this.db.pragma('cache_size = -64000'); // 64MB cache

    // Run migrations
    await this.runMigrations();

    this.initialized = true;
  }

  async close(): Promise<void> {
    if (this.db) {
      this.db.close();
      this.db = null;
      this.initialized = false;
    }
  }

  isInitialized(): boolean {
    return this.initialized;
  }

  private getDb(): Database.Database {
    if (!this.db) {
      throw new Error('Database not initialized. Call initialize() first.');
    }
    return this.db;
  }

  // ===========================================================================
  // Migrations
  // ===========================================================================

  private async runMigrations(): Promise<void> {
    const db = this.getDb();

    // Read and execute the initial migration
    const __dirname = path.dirname(fileURLToPath(import.meta.url));
    const migrationPath = path.join(__dirname, 'migrations', '001_initial.sql');

    let migrationSQL: string;
    try {
      migrationSQL = fs.readFileSync(migrationPath, 'utf-8');
    } catch {
      // Fallback: inline migration for testing
      migrationSQL = this.getInlineMigration();
    }

    db.exec(migrationSQL);
  }

  private getInlineMigration(): string {
    return `
      -- Workspaces
      CREATE TABLE IF NOT EXISTS workspaces (
        id TEXT PRIMARY KEY,
        path TEXT NOT NULL UNIQUE,
        name TEXT,
        created_at TEXT NOT NULL,
        last_activity_at TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_workspaces_path ON workspaces(path);

      -- Sessions
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL REFERENCES workspaces(id),
        head_event_id TEXT,
        root_event_id TEXT,
        title TEXT,
        status TEXT NOT NULL DEFAULT 'active',
        model TEXT NOT NULL,
        provider TEXT NOT NULL,
        working_directory TEXT NOT NULL,
        parent_session_id TEXT REFERENCES sessions(id),
        fork_from_event_id TEXT,
        created_at TEXT NOT NULL,
        last_activity_at TEXT NOT NULL,
        ended_at TEXT,
        event_count INTEGER DEFAULT 0,
        message_count INTEGER DEFAULT 0,
        turn_count INTEGER DEFAULT 0,
        total_input_tokens INTEGER DEFAULT 0,
        total_output_tokens INTEGER DEFAULT 0,
        tags TEXT DEFAULT '[]'
      );
      CREATE INDEX IF NOT EXISTS idx_sessions_workspace ON sessions(workspace_id);
      CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(status);

      -- Events
      CREATE TABLE IF NOT EXISTS events (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL REFERENCES sessions(id),
        parent_id TEXT REFERENCES events(id),
        sequence INTEGER NOT NULL,
        depth INTEGER NOT NULL DEFAULT 0,
        type TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        payload TEXT NOT NULL,
        content_blob_id TEXT REFERENCES blobs(id),
        workspace_id TEXT NOT NULL,
        role TEXT,
        tool_name TEXT,
        tool_call_id TEXT,
        turn INTEGER,
        input_tokens INTEGER,
        output_tokens INTEGER,
        cache_read_tokens INTEGER,
        cache_creation_tokens INTEGER,
        checksum TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_events_session_seq ON events(session_id, sequence);
      CREATE INDEX IF NOT EXISTS idx_events_parent ON events(parent_id);
      CREATE INDEX IF NOT EXISTS idx_events_type ON events(type);
      CREATE INDEX IF NOT EXISTS idx_events_workspace ON events(workspace_id, timestamp DESC);

      -- Blobs
      CREATE TABLE IF NOT EXISTS blobs (
        id TEXT PRIMARY KEY,
        hash TEXT NOT NULL UNIQUE,
        content BLOB NOT NULL,
        mime_type TEXT DEFAULT 'text/plain',
        size_original INTEGER NOT NULL,
        size_compressed INTEGER NOT NULL,
        compression TEXT DEFAULT 'none',
        created_at TEXT NOT NULL,
        ref_count INTEGER DEFAULT 1
      );
      CREATE INDEX IF NOT EXISTS idx_blobs_hash ON blobs(hash);

      -- Branches
      CREATE TABLE IF NOT EXISTS branches (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL REFERENCES sessions(id),
        name TEXT NOT NULL,
        description TEXT,
        root_event_id TEXT NOT NULL REFERENCES events(id),
        head_event_id TEXT NOT NULL REFERENCES events(id),
        is_default INTEGER DEFAULT 0,
        created_at TEXT NOT NULL,
        last_activity_at TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_branches_session ON branches(session_id);

      -- FTS5 (standalone table with manual inserts)
      CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
        id UNINDEXED,
        session_id UNINDEXED,
        type,
        content,
        tool_name,
        tokenize='porter unicode61'
      );

      -- Schema version
      CREATE TABLE IF NOT EXISTS schema_version (
        version INTEGER PRIMARY KEY,
        applied_at TEXT NOT NULL,
        description TEXT
      );
      INSERT OR IGNORE INTO schema_version (version, applied_at, description)
      VALUES (1, datetime('now'), 'Initial schema');
    `;
  }

  getSchemaVersion(): number {
    const db = this.getDb();
    const row = db.prepare('SELECT MAX(version) as version FROM schema_version').get() as { version: number } | undefined;
    return row?.version ?? 0;
  }

  listTables(): string[] {
    const db = this.getDb();
    const rows = db.prepare(`
      SELECT name FROM sqlite_master
      WHERE type='table' OR type='virtual table'
      ORDER BY name
    `).all() as { name: string }[];
    return rows.map(r => r.name);
  }

  // ===========================================================================
  // Workspace Operations
  // ===========================================================================

  async createWorkspace(options: CreateWorkspaceOptions): Promise<Workspace> {
    const db = this.getDb();
    const id = WorkspaceId(`ws_${this.generateId()}`);
    const now = new Date().toISOString();

    db.prepare(`
      INSERT INTO workspaces (id, path, name, created_at, last_activity_at)
      VALUES (?, ?, ?, ?, ?)
    `).run(id, options.path, options.name ?? null, now, now);

    return {
      id,
      path: options.path,
      name: options.name,
      created: now,
      lastActivity: now,
      sessionCount: 0,
    };
  }

  async getWorkspaceByPath(path: string): Promise<Workspace | null> {
    const db = this.getDb();
    const row = db.prepare(`
      SELECT w.*, (SELECT COUNT(*) FROM sessions WHERE workspace_id = w.id) as session_count
      FROM workspaces w
      WHERE path = ?
    `).get(path) as any;

    if (!row) return null;

    return {
      id: WorkspaceId(row.id),
      path: row.path,
      name: row.name,
      created: row.created_at,
      lastActivity: row.last_activity_at,
      sessionCount: row.session_count,
    };
  }

  async getOrCreateWorkspace(path: string, name?: string): Promise<Workspace> {
    const existing = await this.getWorkspaceByPath(path);
    if (existing) return existing;
    return this.createWorkspace({ path, name });
  }

  async listWorkspaces(): Promise<Workspace[]> {
    const db = this.getDb();
    const rows = db.prepare(`
      SELECT w.*, (SELECT COUNT(*) FROM sessions WHERE workspace_id = w.id) as session_count
      FROM workspaces w
      ORDER BY last_activity_at DESC
    `).all() as any[];

    return rows.map(row => ({
      id: WorkspaceId(row.id),
      path: row.path,
      name: row.name,
      created: row.created_at,
      lastActivity: row.last_activity_at,
      sessionCount: row.session_count,
    }));
  }

  // ===========================================================================
  // Session Operations
  // ===========================================================================

  async createSession(options: CreateSessionOptions): Promise<SessionRow> {
    const db = this.getDb();
    const id = SessionId(`sess_${this.generateId(12)}`);
    const now = new Date().toISOString();

    db.prepare(`
      INSERT INTO sessions (
        id, workspace_id, title, status, model, provider, working_directory,
        parent_session_id, fork_from_event_id, created_at, last_activity_at, tags
      )
      VALUES (?, ?, ?, 'active', ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      id,
      options.workspaceId,
      options.title ?? null,
      options.model,
      options.provider,
      options.workingDirectory,
      options.parentSessionId ?? null,
      options.forkFromEventId ?? null,
      now,
      now,
      JSON.stringify(options.tags ?? []),
    );

    return {
      id,
      workspaceId: options.workspaceId,
      headEventId: null,
      rootEventId: null,
      title: options.title ?? null,
      status: 'active',
      model: options.model,
      provider: options.provider,
      workingDirectory: options.workingDirectory,
      parentSessionId: options.parentSessionId ?? null,
      forkFromEventId: options.forkFromEventId ?? null,
      createdAt: now,
      lastActivityAt: now,
      endedAt: null,
      eventCount: 0,
      messageCount: 0,
      turnCount: 0,
      totalInputTokens: 0,
      totalOutputTokens: 0,
      tags: options.tags ?? [],
    };
  }

  async getSession(sessionId: SessionId): Promise<SessionRow | null> {
    const db = this.getDb();
    const row = db.prepare('SELECT * FROM sessions WHERE id = ?').get(sessionId) as any;

    if (!row) return null;

    return this.rowToSession(row);
  }

  async listSessions(options: ListSessionsOptions): Promise<SessionRow[]> {
    const db = this.getDb();
    let sql = 'SELECT * FROM sessions WHERE 1=1';
    const params: any[] = [];

    if (options.workspaceId) {
      sql += ' AND workspace_id = ?';
      params.push(options.workspaceId);
    }

    if (options.status) {
      sql += ' AND status = ?';
      params.push(options.status);
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

    const rows = db.prepare(sql).all(...params) as any[];
    return rows.map(row => this.rowToSession(row));
  }

  async updateSessionHead(sessionId: SessionId, headEventId: EventId): Promise<void> {
    const db = this.getDb();
    db.prepare(`
      UPDATE sessions
      SET head_event_id = ?, last_activity_at = ?
      WHERE id = ?
    `).run(headEventId, new Date().toISOString(), sessionId);
  }

  async updateSessionRoot(sessionId: SessionId, rootEventId: EventId): Promise<void> {
    const db = this.getDb();
    db.prepare(`
      UPDATE sessions
      SET root_event_id = ?
      WHERE id = ?
    `).run(rootEventId, sessionId);
  }

  async updateSessionStatus(sessionId: SessionId, status: 'active' | 'ended' | 'archived'): Promise<void> {
    const db = this.getDb();
    const now = new Date().toISOString();
    db.prepare(`
      UPDATE sessions
      SET status = ?, ended_at = ?, last_activity_at = ?
      WHERE id = ?
    `).run(status, status === 'ended' ? now : null, now, sessionId);
  }

  async incrementSessionCounters(sessionId: SessionId, counters: IncrementCountersOptions): Promise<void> {
    const db = this.getDb();
    const updates: string[] = [];
    const params: any[] = [];

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

    if (updates.length === 0) return;

    updates.push('last_activity_at = ?');
    params.push(new Date().toISOString());
    params.push(sessionId);

    db.prepare(`
      UPDATE sessions SET ${updates.join(', ')}
      WHERE id = ?
    `).run(...params);
  }

  private rowToSession(row: any): SessionRow {
    return {
      id: SessionId(row.id),
      workspaceId: WorkspaceId(row.workspace_id),
      headEventId: row.head_event_id ? EventId(row.head_event_id) : null,
      rootEventId: row.root_event_id ? EventId(row.root_event_id) : null,
      title: row.title,
      status: row.status,
      model: row.model,
      provider: row.provider,
      workingDirectory: row.working_directory,
      parentSessionId: row.parent_session_id ? SessionId(row.parent_session_id) : null,
      forkFromEventId: row.fork_from_event_id ? EventId(row.fork_from_event_id) : null,
      createdAt: row.created_at,
      lastActivityAt: row.last_activity_at,
      endedAt: row.ended_at,
      eventCount: row.event_count,
      messageCount: row.message_count,
      turnCount: row.turn_count,
      totalInputTokens: row.total_input_tokens,
      totalOutputTokens: row.total_output_tokens,
      tags: JSON.parse(row.tags || '[]'),
    };
  }

  // ===========================================================================
  // Event Operations
  // ===========================================================================

  async insertEvent(event: SessionEvent): Promise<void> {
    const db = this.getDb();

    // Extract role from event type
    let role: string | null = null;
    if (event.type === 'message.user') role = 'user';
    else if (event.type === 'message.assistant') role = 'assistant';
    else if (event.type === 'message.system') role = 'system';
    else if (event.type === 'tool.call' || event.type === 'tool.result') role = 'tool';

    // Extract tool info
    let toolName: string | null = null;
    let toolCallId: string | null = null;
    let turn: number | null = null;

    if ('payload' in event) {
      const payload = event.payload as any;
      toolName = payload.toolName ?? payload.name ?? null;
      toolCallId = payload.toolCallId ?? null;
      turn = payload.turn ?? null;
    }

    // Calculate depth
    let depth = 0;
    if (event.parentId) {
      const parent = await this.getEvent(event.parentId);
      if (parent) {
        depth = (parent as any).depth + 1;
      }
    }

    // Extract token usage
    let inputTokens: number | null = null;
    let outputTokens: number | null = null;
    if ('payload' in event && (event.payload as any).tokenUsage) {
      const usage = (event.payload as any).tokenUsage as TokenUsage;
      inputTokens = usage.inputTokens;
      outputTokens = usage.outputTokens;
    }

    db.prepare(`
      INSERT INTO events (
        id, session_id, parent_id, sequence, depth, type, timestamp, payload,
        content_blob_id, workspace_id, role, tool_name, tool_call_id, turn,
        input_tokens, output_tokens, checksum
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
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
      inputTokens,
      outputTokens,
      event.checksum ?? null,
    );
  }

  async getEvent(eventId: EventId): Promise<SessionEvent | null> {
    const db = this.getDb();
    const row = db.prepare('SELECT * FROM events WHERE id = ?').get(eventId) as any;

    if (!row) return null;

    return this.rowToEvent(row);
  }

  async getEvents(eventIds: EventId[]): Promise<Map<EventId, SessionEvent>> {
    const db = this.getDb();
    const result = new Map<EventId, SessionEvent>();

    if (eventIds.length === 0) return result;

    const placeholders = eventIds.map(() => '?').join(',');
    const rows = db.prepare(`SELECT * FROM events WHERE id IN (${placeholders})`).all(...eventIds) as any[];

    for (const row of rows) {
      result.set(EventId(row.id), this.rowToEvent(row));
    }

    return result;
  }

  async getEventsBySession(sessionId: SessionId, options?: { limit?: number; offset?: number }): Promise<SessionEvent[]> {
    const db = this.getDb();
    let sql = 'SELECT * FROM events WHERE session_id = ? ORDER BY sequence ASC';
    const params: any[] = [sessionId];

    if (options?.limit) {
      sql += ' LIMIT ?';
      params.push(options.limit);
    }

    if (options?.offset) {
      sql += ' OFFSET ?';
      params.push(options.offset);
    }

    const rows = db.prepare(sql).all(...params) as any[];
    return rows.map(row => this.rowToEvent(row));
  }

  async getEventsByType(sessionId: SessionId, types: EventType[], options?: { limit?: number }): Promise<SessionEvent[]> {
    const db = this.getDb();
    const placeholders = types.map(() => '?').join(',');
    let sql = `SELECT * FROM events WHERE session_id = ? AND type IN (${placeholders}) ORDER BY sequence ASC`;
    const params: any[] = [sessionId, ...types];

    if (options?.limit) {
      sql += ' LIMIT ?';
      params.push(options.limit);
    }

    const rows = db.prepare(sql).all(...params) as any[];
    return rows.map(row => this.rowToEvent(row));
  }

  async getNextSequence(sessionId: SessionId): Promise<number> {
    const db = this.getDb();
    const row = db.prepare('SELECT MAX(sequence) as max_seq FROM events WHERE session_id = ?').get(sessionId) as { max_seq: number | null };
    return (row.max_seq ?? -1) + 1;
  }

  async getAncestors(eventId: EventId): Promise<SessionEvent[]> {
    const db = this.getDb();

    // Use recursive CTE to get all ancestors
    // The CTE walks from target to root via parent_id, so we track depth
    // and order by depth DESC to get chronological order (root first)
    const rows = db.prepare(`
      WITH RECURSIVE ancestors(id, parent_id, session_id, workspace_id, type, timestamp, sequence, payload, content_blob_id, input_tokens, output_tokens, checksum, depth) AS (
        SELECT id, parent_id, session_id, workspace_id, type, timestamp, sequence, payload, content_blob_id, input_tokens, output_tokens, checksum, 0
        FROM events WHERE id = ?
        UNION ALL
        SELECT e.id, e.parent_id, e.session_id, e.workspace_id, e.type, e.timestamp, e.sequence, e.payload, e.content_blob_id, e.input_tokens, e.output_tokens, e.checksum, a.depth + 1
        FROM events e
        INNER JOIN ancestors a ON e.id = a.parent_id
      )
      SELECT * FROM ancestors ORDER BY depth DESC
    `).all(eventId) as any[];

    return rows.map(row => this.rowToEvent(row));
  }

  async getChildren(eventId: EventId): Promise<SessionEvent[]> {
    const db = this.getDb();
    const rows = db.prepare('SELECT * FROM events WHERE parent_id = ? ORDER BY sequence ASC').all(eventId) as any[];
    return rows.map(row => this.rowToEvent(row));
  }

  async countEvents(sessionId: SessionId): Promise<number> {
    const db = this.getDb();
    const row = db.prepare('SELECT COUNT(*) as count FROM events WHERE session_id = ?').get(sessionId) as { count: number };
    return row.count;
  }

  private rowToEvent(row: any): SessionEvent & { depth: number } {
    return {
      id: EventId(row.id),
      parentId: row.parent_id ? EventId(row.parent_id) : null,
      sessionId: SessionId(row.session_id),
      workspaceId: WorkspaceId(row.workspace_id),
      timestamp: row.timestamp,
      type: row.type as EventType,
      sequence: row.sequence,
      payload: JSON.parse(row.payload),
      checksum: row.checksum,
      depth: row.depth ?? 0,
    } as SessionEvent & { depth: number };
  }

  // ===========================================================================
  // Blob Operations
  // ===========================================================================

  async storeBlob(content: string | Buffer, mimeType = 'text/plain'): Promise<string> {
    const db = this.getDb();
    const buffer = typeof content === 'string' ? Buffer.from(content, 'utf-8') : content;
    const hash = crypto.createHash('sha256').update(buffer).digest('hex');

    // Check for existing blob
    const existing = db.prepare('SELECT id FROM blobs WHERE hash = ?').get(hash) as { id: string } | undefined;

    if (existing) {
      // Increment ref count
      db.prepare('UPDATE blobs SET ref_count = ref_count + 1 WHERE id = ?').run(existing.id);
      return existing.id;
    }

    // Create new blob
    const id = `blob_${this.generateId()}`;
    const now = new Date().toISOString();

    db.prepare(`
      INSERT INTO blobs (id, hash, content, mime_type, size_original, size_compressed, compression, created_at)
      VALUES (?, ?, ?, ?, ?, ?, 'none', ?)
    `).run(id, hash, buffer, mimeType, buffer.length, buffer.length, now);

    return id;
  }

  async getBlob(blobId: string): Promise<string | null> {
    const db = this.getDb();
    const row = db.prepare('SELECT content FROM blobs WHERE id = ?').get(blobId) as { content: Buffer } | undefined;

    if (!row) return null;

    return row.content.toString('utf-8');
  }

  async getBlobRefCount(blobId: string): Promise<number> {
    const db = this.getDb();
    const row = db.prepare('SELECT ref_count FROM blobs WHERE id = ?').get(blobId) as { ref_count: number } | undefined;
    return row?.ref_count ?? 0;
  }

  // ===========================================================================
  // FTS5 Search
  // ===========================================================================

  async indexEventForSearch(event: SessionEvent): Promise<void> {
    const db = this.getDb();

    // Extract searchable content from payload
    let content = '';
    if ('payload' in event) {
      const payload = event.payload as any;
      if (typeof payload.content === 'string') {
        content = payload.content;
      } else if (Array.isArray(payload.content)) {
        content = payload.content
          .filter((block: any) => block.type === 'text')
          .map((block: any) => block.text)
          .join(' ');
      }
    }

    // Get tool name
    let toolName = '';
    if ('payload' in event) {
      const payload = event.payload as any;
      toolName = payload.toolName ?? payload.name ?? '';
    }

    db.prepare(`
      INSERT INTO events_fts (id, session_id, type, content, tool_name)
      VALUES (?, ?, ?, ?, ?)
    `).run(event.id, event.sessionId, event.type, content, toolName);
  }

  async searchEvents(query: string, options?: SearchOptions): Promise<SearchResult[]> {
    const db = this.getDb();

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

    const params: any[] = [query];

    if (options?.workspaceId) {
      sql += ' AND e.workspace_id = ?';
      params.push(options.workspaceId);
    }

    if (options?.sessionId) {
      sql += ' AND events_fts.session_id = ?';
      params.push(options.sessionId);
    }

    if (options?.types && options.types.length > 0) {
      const placeholders = options.types.map(() => '?').join(',');
      sql += ` AND events_fts.type IN (${placeholders})`;
      params.push(...options.types);
    }

    sql += ' ORDER BY score';

    if (options?.limit) {
      sql += ' LIMIT ?';
      params.push(options.limit);
    }

    if (options?.offset) {
      sql += ' OFFSET ?';
      params.push(options.offset);
    }

    const rows = db.prepare(sql).all(...params) as any[];

    return rows.map(row => ({
      eventId: EventId(row.id),
      sessionId: SessionId(row.session_id),
      type: row.type as EventType,
      timestamp: row.timestamp,
      snippet: row.snippet || '',
      score: Math.abs(row.score),
    }));
  }

  // ===========================================================================
  // Branch Operations
  // ===========================================================================

  async createBranch(options: CreateBranchOptions): Promise<BranchRow> {
    const db = this.getDb();
    const id = BranchId(`br_${this.generateId()}`);
    const now = new Date().toISOString();

    db.prepare(`
      INSERT INTO branches (id, session_id, name, description, root_event_id, head_event_id, is_default, created_at, last_activity_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      id,
      options.sessionId,
      options.name,
      options.description ?? null,
      options.rootEventId,
      options.headEventId,
      options.isDefault ? 1 : 0,
      now,
      now,
    );

    return {
      id,
      sessionId: options.sessionId,
      name: options.name,
      description: options.description ?? null,
      rootEventId: options.rootEventId,
      headEventId: options.headEventId,
      isDefault: options.isDefault ?? false,
      createdAt: now,
      lastActivityAt: now,
    };
  }

  async getBranch(branchId: BranchId): Promise<BranchRow | null> {
    const db = this.getDb();
    const row = db.prepare('SELECT * FROM branches WHERE id = ?').get(branchId) as any;

    if (!row) return null;

    return this.rowToBranch(row);
  }

  async getBranchesBySession(sessionId: SessionId): Promise<BranchRow[]> {
    const db = this.getDb();
    const rows = db.prepare('SELECT * FROM branches WHERE session_id = ? ORDER BY created_at ASC').all(sessionId) as any[];
    return rows.map(row => this.rowToBranch(row));
  }

  async updateBranchHead(branchId: BranchId, headEventId: EventId): Promise<void> {
    const db = this.getDb();
    db.prepare(`
      UPDATE branches SET head_event_id = ?, last_activity_at = ?
      WHERE id = ?
    `).run(headEventId, new Date().toISOString(), branchId);
  }

  private rowToBranch(row: any): BranchRow {
    return {
      id: BranchId(row.id),
      sessionId: SessionId(row.session_id),
      name: row.name,
      description: row.description,
      rootEventId: EventId(row.root_event_id),
      headEventId: EventId(row.head_event_id),
      isDefault: row.is_default === 1,
      createdAt: row.created_at,
      lastActivityAt: row.last_activity_at,
    };
  }

  // ===========================================================================
  // Transaction Support
  // ===========================================================================

  /**
   * Execute a function within a synchronous SQLite transaction.
   * Note: better-sqlite3 transactions are synchronous - async functions are NOT supported.
   * All operations inside the function must be synchronous.
   */
  transaction<T>(fn: () => T): T {
    const db = this.getDb();
    return db.transaction(fn)();
  }

  /**
   * Execute an async function with manual transaction control.
   * Uses BEGIN/COMMIT/ROLLBACK for async operations.
   */
  async transactionAsync<T>(fn: () => Promise<T>): Promise<T> {
    const db = this.getDb();
    db.exec('BEGIN IMMEDIATE');
    try {
      const result = await fn();
      db.exec('COMMIT');
      return result;
    } catch (error) {
      db.exec('ROLLBACK');
      throw error;
    }
  }

  // ===========================================================================
  // Statistics
  // ===========================================================================

  async getStats(): Promise<{
    totalEvents: number;
    totalSessions: number;
    totalWorkspaces: number;
    totalBlobs: number;
  }> {
    const db = this.getDb();

    const events = db.prepare('SELECT COUNT(*) as count FROM events').get() as { count: number };
    const sessions = db.prepare('SELECT COUNT(*) as count FROM sessions').get() as { count: number };
    const workspaces = db.prepare('SELECT COUNT(*) as count FROM workspaces').get() as { count: number };
    const blobs = db.prepare('SELECT COUNT(*) as count FROM blobs').get() as { count: number };

    return {
      totalEvents: events.count,
      totalSessions: sessions.count,
      totalWorkspaces: workspaces.count,
      totalBlobs: blobs.count,
    };
  }

  // ===========================================================================
  // Utilities
  // ===========================================================================

  private generateId(length = 12): string {
    return crypto.randomUUID().replace(/-/g, '').slice(0, length);
  }
}
