/**
 * @fileoverview SQLite memory store implementation
 *
 * Uses better-sqlite3 with FTS5 for full-text search.
 */

import Database from 'better-sqlite3';
import { randomUUID } from 'crypto';
import type {
  MemoryStore,
  MemoryEntry,
  MemoryQuery,
  MemorySearchResult,
  SessionMemory,
  ProjectMemory,
  GlobalMemory,
  HandoffRecord,
  LedgerEntry,
} from './types.js';
import { createLogger } from '../logging/logger.js';

const logger = createLogger('memory:sqlite');

export interface SQLiteStoreConfig {
  dbPath: string;
  enableFTS?: boolean;
  enableWAL?: boolean;
}

export class SQLiteMemoryStore implements MemoryStore {
  private db: Database.Database;
  private config: SQLiteStoreConfig;

  constructor(config: SQLiteStoreConfig) {
    this.config = config;
    this.db = new Database(config.dbPath);

    // Enable WAL mode for better concurrency
    if (config.enableWAL !== false) {
      this.db.pragma('journal_mode = WAL');
    }

    this.initSchema();
    logger.info('SQLite memory store initialized', { dbPath: config.dbPath });
  }

  private initSchema(): void {
    this.db.exec(`
      -- Sessions table
      CREATE TABLE IF NOT EXISTS sessions (
        session_id TEXT PRIMARY KEY,
        started_at TEXT NOT NULL,
        ended_at TEXT,
        working_directory TEXT NOT NULL,
        active_files TEXT,  -- JSON array
        context TEXT,       -- JSON object
        parent_handoff_id TEXT,
        token_input INTEGER DEFAULT 0,
        token_output INTEGER DEFAULT 0
      );

      -- Messages table
      CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        FOREIGN KEY (session_id) REFERENCES sessions(session_id)
      );

      -- Tool calls table
      CREATE TABLE IF NOT EXISTS tool_calls (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        name TEXT NOT NULL,
        arguments TEXT,  -- JSON
        result TEXT,
        is_error INTEGER DEFAULT 0,
        timestamp TEXT NOT NULL,
        FOREIGN KEY (session_id) REFERENCES sessions(session_id)
      );

      -- Memory entries table
      CREATE TABLE IF NOT EXISTS memory_entries (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        content TEXT NOT NULL,
        source TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        metadata TEXT,  -- JSON
        category TEXT,
        tags TEXT,      -- JSON array
        project_path TEXT
      );

      -- Handoffs table
      CREATE TABLE IF NOT EXISTS handoffs (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        created_at TEXT NOT NULL,
        summary TEXT NOT NULL,
        pending_tasks TEXT,  -- JSON array
        context TEXT,        -- JSON object
        message_count INTEGER DEFAULT 0,
        tool_call_count INTEGER DEFAULT 0,
        parent_handoff_id TEXT,
        compressed_messages TEXT,
        key_insights TEXT,   -- JSON array
        project_path TEXT,
        FOREIGN KEY (session_id) REFERENCES sessions(session_id)
      );

      -- Ledger entries table
      CREATE TABLE IF NOT EXISTS ledger (
        id TEXT PRIMARY KEY,
        timestamp TEXT NOT NULL,
        session_id TEXT NOT NULL,
        action TEXT NOT NULL,
        description TEXT NOT NULL,
        files_modified TEXT,  -- JSON array
        success INTEGER NOT NULL,
        error TEXT,
        duration INTEGER,
        metadata TEXT  -- JSON
      );

      -- Project memory table
      CREATE TABLE IF NOT EXISTS project_memory (
        project_path TEXT PRIMARY KEY,
        project_name TEXT,
        claude_md_path TEXT,
        patterns TEXT,     -- JSON array
        decisions TEXT,    -- JSON array
        preferences TEXT,  -- JSON object
        statistics TEXT,   -- JSON object
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );

      -- Global memory table (single row)
      CREATE TABLE IF NOT EXISTS global_memory (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        lessons TEXT,      -- JSON array
        preferences TEXT,  -- JSON object
        statistics TEXT,   -- JSON object
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );

      -- Initialize global memory if not exists
      INSERT OR IGNORE INTO global_memory (id, lessons, preferences, statistics, created_at, updated_at)
      VALUES (1, '[]', '{}', '{"totalSessions":0,"totalToolCalls":0}', datetime('now'), datetime('now'));

      -- Create indexes
      CREATE INDEX IF NOT EXISTS idx_sessions_ended ON sessions(ended_at);
      CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id);
      CREATE INDEX IF NOT EXISTS idx_tool_calls_session ON tool_calls(session_id);
      CREATE INDEX IF NOT EXISTS idx_memory_type ON memory_entries(type);
      CREATE INDEX IF NOT EXISTS idx_memory_source ON memory_entries(source);
      CREATE INDEX IF NOT EXISTS idx_memory_project ON memory_entries(project_path);
      CREATE INDEX IF NOT EXISTS idx_handoffs_project ON handoffs(project_path);
      CREATE INDEX IF NOT EXISTS idx_ledger_session ON ledger(session_id);
    `);

    // Create FTS5 virtual table for full-text search
    if (this.config.enableFTS !== false) {
      this.db.exec(`
        CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
          id,
          content,
          content=memory_entries,
          content_rowid=rowid
        );

        -- Triggers to keep FTS in sync
        CREATE TRIGGER IF NOT EXISTS memory_ai AFTER INSERT ON memory_entries BEGIN
          INSERT INTO memory_fts(rowid, id, content) VALUES (NEW.rowid, NEW.id, NEW.content);
        END;

        CREATE TRIGGER IF NOT EXISTS memory_ad AFTER DELETE ON memory_entries BEGIN
          INSERT INTO memory_fts(memory_fts, rowid, id, content) VALUES('delete', OLD.rowid, OLD.id, OLD.content);
        END;

        CREATE TRIGGER IF NOT EXISTS memory_au AFTER UPDATE ON memory_entries BEGIN
          INSERT INTO memory_fts(memory_fts, rowid, id, content) VALUES('delete', OLD.rowid, OLD.id, OLD.content);
          INSERT INTO memory_fts(rowid, id, content) VALUES (NEW.rowid, NEW.id, NEW.content);
        END;
      `);
    }

    logger.debug('Schema initialized');
  }

  // ==========================================================================
  // Session Operations
  // ==========================================================================

  async createSession(session: Omit<SessionMemory, 'sessionId'>): Promise<SessionMemory> {
    const sessionId = `sess_${randomUUID().replace(/-/g, '').slice(0, 12)}`;

    const stmt = this.db.prepare(`
      INSERT INTO sessions (session_id, started_at, working_directory, active_files, context, parent_handoff_id)
      VALUES (?, ?, ?, ?, ?, ?)
    `);

    stmt.run(
      sessionId,
      session.startedAt,
      session.workingDirectory,
      JSON.stringify(session.activeFiles),
      JSON.stringify(session.context),
      session.parentHandoffId ?? null
    );

    logger.info('Session created', { sessionId });

    return {
      sessionId,
      ...session,
    };
  }

  async getSession(sessionId: string): Promise<SessionMemory | null> {
    const stmt = this.db.prepare(`
      SELECT * FROM sessions WHERE session_id = ?
    `);

    const row = stmt.get(sessionId) as any;
    if (!row) return null;

    // Get messages
    const messagesStmt = this.db.prepare(`
      SELECT * FROM messages WHERE session_id = ? ORDER BY timestamp
    `);
    const messageRows = messagesStmt.all(sessionId) as any[];

    // Get tool calls
    const toolCallsStmt = this.db.prepare(`
      SELECT * FROM tool_calls WHERE session_id = ? ORDER BY timestamp
    `);
    const toolCallRows = toolCallsStmt.all(sessionId) as any[];

    return {
      sessionId: row.session_id,
      startedAt: row.started_at,
      endedAt: row.ended_at,
      workingDirectory: row.working_directory,
      activeFiles: JSON.parse(row.active_files || '[]'),
      context: JSON.parse(row.context || '{}'),
      parentHandoffId: row.parent_handoff_id,
      messages: messageRows.map(m => ({
        role: m.role,
        content: m.content,
        timestamp: m.timestamp,
      })) as any[],
      toolCalls: toolCallRows.map(t => ({
        id: t.id,
        name: t.name,
        arguments: JSON.parse(t.arguments || '{}'),
        type: 'tool_use' as const,
      })),
      tokenUsage: row.token_input || row.token_output ? {
        input: row.token_input,
        output: row.token_output,
      } : undefined,
    };
  }

  async updateSession(sessionId: string, updates: Partial<SessionMemory>): Promise<void> {
    const sets: string[] = [];
    const values: any[] = [];

    if (updates.activeFiles !== undefined) {
      sets.push('active_files = ?');
      values.push(JSON.stringify(updates.activeFiles));
    }
    if (updates.context !== undefined) {
      sets.push('context = ?');
      values.push(JSON.stringify(updates.context));
    }
    if (updates.endedAt !== undefined) {
      sets.push('ended_at = ?');
      values.push(updates.endedAt);
    }
    if (updates.tokenUsage !== undefined) {
      sets.push('token_input = ?, token_output = ?');
      values.push(updates.tokenUsage.input, updates.tokenUsage.output);
    }

    if (sets.length === 0) return;

    values.push(sessionId);
    const stmt = this.db.prepare(`
      UPDATE sessions SET ${sets.join(', ')} WHERE session_id = ?
    `);
    stmt.run(...values);

    logger.debug('Session updated', { sessionId });
  }

  async endSession(sessionId: string): Promise<HandoffRecord> {
    const session = await this.getSession(sessionId);
    if (!session) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    // Update ended_at
    await this.updateSession(sessionId, { endedAt: new Date().toISOString() });

    // Create handoff
    return this.createHandoff(sessionId, 'Session ended');
  }

  // ==========================================================================
  // Memory Entry Operations
  // ==========================================================================

  async addEntry(entry: Omit<MemoryEntry, 'id' | 'timestamp'>): Promise<MemoryEntry> {
    const id = `mem_${randomUUID().replace(/-/g, '').slice(0, 12)}`;
    const timestamp = new Date().toISOString();

    const stmt = this.db.prepare(`
      INSERT INTO memory_entries (id, type, content, source, timestamp, metadata, category, tags, project_path)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);

    stmt.run(
      id,
      entry.type,
      entry.content,
      entry.source,
      timestamp,
      entry.metadata ? JSON.stringify(entry.metadata) : null,
      entry.category ?? null,
      entry.tags ? JSON.stringify(entry.tags) : null,
      (entry as any).projectPath ?? null
    );

    logger.debug('Memory entry added', { id, type: entry.type });

    return {
      id,
      timestamp,
      ...entry,
    };
  }

  async getEntry(id: string): Promise<MemoryEntry | null> {
    const stmt = this.db.prepare(`
      SELECT * FROM memory_entries WHERE id = ?
    `);

    const row = stmt.get(id) as any;
    if (!row) return null;

    return this.rowToEntry(row);
  }

  async searchEntries(query: MemoryQuery): Promise<MemorySearchResult> {
    const conditions: string[] = ['1=1'];
    const values: any[] = [];

    if (query.source) {
      conditions.push('source = ?');
      values.push(query.source);
    }
    if (query.type) {
      conditions.push('type = ?');
      values.push(query.type);
    }
    if (query.projectPath) {
      conditions.push('project_path = ?');
      values.push(query.projectPath);
    }
    if (query.after) {
      conditions.push('timestamp > ?');
      values.push(query.after);
    }
    if (query.before) {
      conditions.push('timestamp < ?');
      values.push(query.before);
    }

    // For text search, use FTS if available
    let sql: string;
    let countSql: string;
    let countValues: any[];

    if (query.searchText && this.config.enableFTS !== false) {
      sql = `
        SELECT e.* FROM memory_entries e
        INNER JOIN memory_fts fts ON e.id = fts.id
        WHERE fts.content MATCH ? AND ${conditions.join(' AND ')}
        ORDER BY e.timestamp DESC
        LIMIT ? OFFSET ?
      `;
      countSql = `
        SELECT COUNT(*) as count FROM memory_entries e
        INNER JOIN memory_fts fts ON e.id = fts.id
        WHERE fts.content MATCH ? AND ${conditions.join(' AND ')}
      `;
      values.unshift(query.searchText);
      countValues = [...values]; // Copy before adding limit/offset
    } else {
      if (query.searchText) {
        conditions.push('content LIKE ?');
        values.push(`%${query.searchText}%`);
      }
      sql = `
        SELECT * FROM memory_entries
        WHERE ${conditions.join(' AND ')}
        ORDER BY timestamp DESC
        LIMIT ? OFFSET ?
      `;
      countSql = `
        SELECT COUNT(*) as count FROM memory_entries
        WHERE ${conditions.join(' AND ')}
      `;
      countValues = [...values]; // Copy before adding limit/offset
    }

    const limit = query.limit ?? 50;
    const offset = query.offset ?? 0;
    values.push(limit + 1, offset); // +1 to check hasMore

    const stmt = this.db.prepare(sql);
    const rows = stmt.all(...values) as any[];

    const hasMore = rows.length > limit;
    const entries = rows.slice(0, limit).map(row => this.rowToEntry(row));

    // Get total count
    const countStmt = this.db.prepare(countSql);
    const countRow = countStmt.get(...countValues) as any;

    return {
      entries,
      totalCount: countRow?.count ?? 0,
      hasMore,
    };
  }

  async deleteEntry(id: string): Promise<void> {
    const stmt = this.db.prepare(`DELETE FROM memory_entries WHERE id = ?`);
    stmt.run(id);
    logger.debug('Memory entry deleted', { id });
  }

  private rowToEntry(row: any): MemoryEntry {
    return {
      id: row.id,
      type: row.type,
      content: row.content,
      source: row.source,
      timestamp: row.timestamp,
      metadata: row.metadata ? JSON.parse(row.metadata) : undefined,
      category: row.category,
      tags: row.tags ? JSON.parse(row.tags) : undefined,
    };
  }

  // ==========================================================================
  // Handoff Operations
  // ==========================================================================

  async createHandoff(sessionId: string, summary: string): Promise<HandoffRecord> {
    const id = `handoff_${randomUUID().replace(/-/g, '').slice(0, 12)}`;
    const createdAt = new Date().toISOString();

    const session = await this.getSession(sessionId);
    const messageCount = session?.messages.length ?? 0;
    const toolCallCount = session?.toolCalls.length ?? 0;

    const stmt = this.db.prepare(`
      INSERT INTO handoffs (id, session_id, created_at, summary, context, message_count, tool_call_count, project_path)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `);

    stmt.run(
      id,
      sessionId,
      createdAt,
      summary,
      JSON.stringify(session?.context ?? {}),
      messageCount,
      toolCallCount,
      session?.workingDirectory ?? null
    );

    logger.info('Handoff created', { id, sessionId });

    return {
      id,
      sessionId,
      createdAt,
      summary,
      context: session?.context ?? {},
      messageCount,
      toolCallCount,
    };
  }

  async getHandoff(handoffId: string): Promise<HandoffRecord | null> {
    const stmt = this.db.prepare(`SELECT * FROM handoffs WHERE id = ?`);
    const row = stmt.get(handoffId) as any;
    if (!row) return null;

    return this.rowToHandoff(row);
  }

  async listHandoffs(projectPath?: string): Promise<HandoffRecord[]> {
    let sql = `SELECT * FROM handoffs`;
    const values: any[] = [];

    if (projectPath) {
      sql += ` WHERE project_path = ?`;
      values.push(projectPath);
    }

    sql += ` ORDER BY created_at DESC LIMIT 100`;

    const stmt = this.db.prepare(sql);
    const rows = stmt.all(...values) as any[];

    return rows.map(row => this.rowToHandoff(row));
  }

  private rowToHandoff(row: any): HandoffRecord {
    return {
      id: row.id,
      sessionId: row.session_id,
      createdAt: row.created_at,
      summary: row.summary,
      pendingTasks: row.pending_tasks ? JSON.parse(row.pending_tasks) : undefined,
      context: JSON.parse(row.context || '{}'),
      messageCount: row.message_count,
      toolCallCount: row.tool_call_count,
      parentHandoffId: row.parent_handoff_id,
      compressedMessages: row.compressed_messages,
      keyInsights: row.key_insights ? JSON.parse(row.key_insights) : undefined,
    };
  }

  // ==========================================================================
  // Ledger Operations
  // ==========================================================================

  async addLedgerEntry(entry: Omit<LedgerEntry, 'id' | 'timestamp'>): Promise<LedgerEntry> {
    const id = `ledger_${randomUUID().replace(/-/g, '').slice(0, 12)}`;
    const timestamp = new Date().toISOString();

    const stmt = this.db.prepare(`
      INSERT INTO ledger (id, timestamp, session_id, action, description, files_modified, success, error, duration, metadata)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);

    stmt.run(
      id,
      timestamp,
      entry.sessionId,
      entry.action,
      entry.description,
      entry.filesModified ? JSON.stringify(entry.filesModified) : null,
      entry.success ? 1 : 0,
      entry.error ?? null,
      entry.duration ?? null,
      entry.metadata ? JSON.stringify(entry.metadata) : null
    );

    logger.debug('Ledger entry added', { id, action: entry.action });

    return {
      id,
      timestamp,
      ...entry,
    };
  }

  async getLedgerEntries(sessionId?: string): Promise<LedgerEntry[]> {
    let sql = `SELECT * FROM ledger`;
    const values: any[] = [];

    if (sessionId) {
      sql += ` WHERE session_id = ?`;
      values.push(sessionId);
    }

    sql += ` ORDER BY timestamp DESC LIMIT 1000`;

    const stmt = this.db.prepare(sql);
    const rows = stmt.all(...values) as any[];

    return rows.map(row => ({
      id: row.id,
      timestamp: row.timestamp,
      sessionId: row.session_id,
      action: row.action,
      description: row.description,
      filesModified: row.files_modified ? JSON.parse(row.files_modified) : undefined,
      success: row.success === 1,
      error: row.error,
      duration: row.duration,
      metadata: row.metadata ? JSON.parse(row.metadata) : undefined,
    }));
  }

  // ==========================================================================
  // Project Memory
  // ==========================================================================

  async getProjectMemory(projectPath: string): Promise<ProjectMemory | null> {
    const stmt = this.db.prepare(`SELECT * FROM project_memory WHERE project_path = ?`);
    const row = stmt.get(projectPath) as any;
    if (!row) return null;

    return {
      projectPath: row.project_path,
      projectName: row.project_name,
      claudeMdPath: row.claude_md_path,
      patterns: JSON.parse(row.patterns || '[]'),
      decisions: JSON.parse(row.decisions || '[]'),
      preferences: JSON.parse(row.preferences || '{}'),
      statistics: row.statistics ? JSON.parse(row.statistics) : undefined,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    };
  }

  async updateProjectMemory(projectPath: string, updates: Partial<ProjectMemory>): Promise<void> {
    const existing = await this.getProjectMemory(projectPath);
    const now = new Date().toISOString();

    if (existing) {
      const merged = { ...existing, ...updates, updatedAt: now };
      const stmt = this.db.prepare(`
        UPDATE project_memory SET
          project_name = ?,
          claude_md_path = ?,
          patterns = ?,
          decisions = ?,
          preferences = ?,
          statistics = ?,
          updated_at = ?
        WHERE project_path = ?
      `);
      stmt.run(
        merged.projectName,
        merged.claudeMdPath ?? null,
        JSON.stringify(merged.patterns),
        JSON.stringify(merged.decisions),
        JSON.stringify(merged.preferences),
        merged.statistics ? JSON.stringify(merged.statistics) : null,
        now,
        projectPath
      );
    } else {
      const stmt = this.db.prepare(`
        INSERT INTO project_memory (project_path, project_name, claude_md_path, patterns, decisions, preferences, statistics, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      `);
      stmt.run(
        projectPath,
        updates.projectName ?? '',
        updates.claudeMdPath ?? null,
        JSON.stringify(updates.patterns ?? []),
        JSON.stringify(updates.decisions ?? []),
        JSON.stringify(updates.preferences ?? {}),
        updates.statistics ? JSON.stringify(updates.statistics) : null,
        now,
        now
      );
    }

    logger.debug('Project memory updated', { projectPath });
  }

  // ==========================================================================
  // Global Memory
  // ==========================================================================

  async getGlobalMemory(): Promise<GlobalMemory> {
    const stmt = this.db.prepare(`SELECT * FROM global_memory WHERE id = 1`);
    const row = stmt.get() as any;

    return {
      lessons: JSON.parse(row.lessons || '[]'),
      preferences: JSON.parse(row.preferences || '{}'),
      statistics: JSON.parse(row.statistics || '{"totalSessions":0,"totalToolCalls":0}'),
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    };
  }

  async updateGlobalMemory(updates: Partial<GlobalMemory>): Promise<void> {
    const existing = await this.getGlobalMemory();
    const now = new Date().toISOString();

    const merged = {
      lessons: updates.lessons ?? existing.lessons,
      preferences: { ...existing.preferences, ...updates.preferences },
      statistics: { ...existing.statistics, ...updates.statistics },
    };

    const stmt = this.db.prepare(`
      UPDATE global_memory SET
        lessons = ?,
        preferences = ?,
        statistics = ?,
        updated_at = ?
      WHERE id = 1
    `);

    stmt.run(
      JSON.stringify(merged.lessons),
      JSON.stringify(merged.preferences),
      JSON.stringify(merged.statistics),
      now
    );

    logger.debug('Global memory updated');
  }

  // ==========================================================================
  // Maintenance
  // ==========================================================================

  async compact(): Promise<void> {
    // Delete old sessions (older than 30 days)
    const cutoff = new Date();
    cutoff.setDate(cutoff.getDate() - 30);

    const stmt = this.db.prepare(`
      DELETE FROM sessions WHERE ended_at < ? AND ended_at IS NOT NULL
    `);
    const result = stmt.run(cutoff.toISOString());

    logger.info('Database compacted', { deletedSessions: result.changes });
  }

  async vacuum(): Promise<void> {
    this.db.exec('VACUUM');
    logger.info('Database vacuumed');
  }

  async close(): Promise<void> {
    this.db.close();
    logger.info('Database connection closed');
  }
}
