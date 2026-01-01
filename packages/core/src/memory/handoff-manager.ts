/**
 * @fileoverview Handoff Manager with FTS5 Search
 *
 * Manages session handoffs - structured summaries of completed sessions
 * that enable context retrieval across session boundaries.
 *
 * Uses SQLite with FTS5 for efficient full-text search across handoff content.
 *
 * @see Implementation Plan - Phase 2: Memory Layer
 */
import Database from 'better-sqlite3';
import { randomUUID } from 'crypto';
import { createLogger } from '../logging/logger.js';

const logger = createLogger('memory:handoff');

// =============================================================================
// Types
// =============================================================================

export interface CodeChange {
  file: string;
  description: string;
  lines?: {
    added: number;
    removed: number;
  };
  operation?: 'create' | 'modify' | 'delete';
}

export interface Handoff {
  id?: string;
  sessionId: string;
  timestamp: Date;
  summary: string;
  codeChanges: CodeChange[];
  currentState: string;
  blockers: string[];
  nextSteps: string[];
  patterns: string[];
  metadata?: Record<string, unknown>;
}

export interface HandoffSearchResult {
  id: string;
  sessionId: string;
  timestamp: Date;
  summary: string;
  currentState: string;
  rank?: number;
  snippet?: string;
}

export interface HandoffManagerConfig {
  dbPath: string;
  enableWAL?: boolean;
}

// =============================================================================
// Handoff Manager Class
// =============================================================================

export class HandoffManager {
  private db: Database.Database;
  private config: HandoffManagerConfig;
  private initialized: boolean = false;

  constructor(config: HandoffManagerConfig | string) {
    this.config = typeof config === 'string' ? { dbPath: config } : config;
    this.db = new Database(this.config.dbPath);

    // Enable WAL mode for better concurrency
    if (this.config.enableWAL !== false) {
      this.db.pragma('journal_mode = WAL');
    }
  }

  /**
   * Initialize database schema
   */
  async initialize(): Promise<void> {
    if (this.initialized) return;

    // Create main handoffs table
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS handoffs (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        summary TEXT NOT NULL,
        code_changes TEXT,
        current_state TEXT,
        blockers TEXT,
        next_steps TEXT,
        patterns TEXT,
        metadata TEXT,
        created_at INTEGER DEFAULT (strftime('%s', 'now'))
      );

      CREATE INDEX IF NOT EXISTS idx_handoffs_session ON handoffs(session_id);
      CREATE INDEX IF NOT EXISTS idx_handoffs_timestamp ON handoffs(timestamp DESC);
    `);

    // Create FTS5 virtual table for full-text search
    this.db.exec(`
      CREATE VIRTUAL TABLE IF NOT EXISTS handoffs_fts USING fts5(
        id UNINDEXED,
        session_id,
        summary,
        code_changes,
        current_state,
        patterns,
        content='handoffs',
        content_rowid='rowid',
        tokenize='porter unicode61'
      );

      -- Triggers to keep FTS in sync
      CREATE TRIGGER IF NOT EXISTS handoffs_ai AFTER INSERT ON handoffs BEGIN
        INSERT INTO handoffs_fts(rowid, id, session_id, summary, code_changes, current_state, patterns)
        VALUES (NEW.rowid, NEW.id, NEW.session_id, NEW.summary, NEW.code_changes, NEW.current_state, NEW.patterns);
      END;

      CREATE TRIGGER IF NOT EXISTS handoffs_ad AFTER DELETE ON handoffs BEGIN
        INSERT INTO handoffs_fts(handoffs_fts, rowid, id, session_id, summary, code_changes, current_state, patterns)
        VALUES ('delete', OLD.rowid, OLD.id, OLD.session_id, OLD.summary, OLD.code_changes, OLD.current_state, OLD.patterns);
      END;

      CREATE TRIGGER IF NOT EXISTS handoffs_au AFTER UPDATE ON handoffs BEGIN
        INSERT INTO handoffs_fts(handoffs_fts, rowid, id, session_id, summary, code_changes, current_state, patterns)
        VALUES ('delete', OLD.rowid, OLD.id, OLD.session_id, OLD.summary, OLD.code_changes, OLD.current_state, OLD.patterns);
        INSERT INTO handoffs_fts(rowid, id, session_id, summary, code_changes, current_state, patterns)
        VALUES (NEW.rowid, NEW.id, NEW.session_id, NEW.summary, NEW.code_changes, NEW.current_state, NEW.patterns);
      END;
    `);

    this.initialized = true;
    logger.info('Handoff manager initialized', { dbPath: this.config.dbPath });
  }

  /**
   * Create a new handoff record
   */
  async create(handoff: Omit<Handoff, 'id'>): Promise<string> {
    await this.initialize();

    const id = handoff.id ?? `handoff_${randomUUID().replace(/-/g, '').slice(0, 12)}`;

    const stmt = this.db.prepare(`
      INSERT INTO handoffs (id, session_id, timestamp, summary, code_changes, current_state, blockers, next_steps, patterns, metadata)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);

    stmt.run(
      id,
      handoff.sessionId,
      handoff.timestamp.getTime(),
      handoff.summary,
      this.serializeCodeChanges(handoff.codeChanges),
      handoff.currentState,
      JSON.stringify(handoff.blockers),
      JSON.stringify(handoff.nextSteps),
      JSON.stringify(handoff.patterns),
      handoff.metadata ? JSON.stringify(handoff.metadata) : null
    );

    logger.info('Handoff created', { id, sessionId: handoff.sessionId });
    return id;
  }

  /**
   * Get a handoff by ID
   */
  async get(id: string): Promise<Handoff | null> {
    await this.initialize();

    const stmt = this.db.prepare(`SELECT * FROM handoffs WHERE id = ?`);
    const row = stmt.get(id) as any;

    if (!row) return null;
    return this.deserialize(row);
  }

  /**
   * Search handoffs using FTS5
   */
  async search(query: string, limit: number = 10): Promise<HandoffSearchResult[]> {
    await this.initialize();

    // Escape special FTS5 characters and add prefix matching
    const sanitizedQuery = this.sanitizeFtsQuery(query);

    const stmt = this.db.prepare(`
      SELECT
        h.*,
        fts.rank
      FROM handoffs h
      INNER JOIN handoffs_fts fts ON h.id = fts.id
      WHERE handoffs_fts MATCH ?
      ORDER BY fts.rank
      LIMIT ?
    `);

    const rows = stmt.all(sanitizedQuery, limit) as any[];

    return rows.map(row => ({
      id: row.id,
      sessionId: row.session_id,
      timestamp: new Date(row.timestamp),
      summary: row.summary,
      currentState: row.current_state,
      rank: row.rank,
    }));
  }

  /**
   * Get recent handoffs
   */
  async getRecent(limit: number = 5): Promise<Handoff[]> {
    await this.initialize();

    const stmt = this.db.prepare(`
      SELECT * FROM handoffs
      ORDER BY timestamp DESC
      LIMIT ?
    `);

    const rows = stmt.all(limit) as any[];
    return rows.map(row => this.deserialize(row));
  }

  /**
   * Get handoffs for a specific session
   */
  async getBySession(sessionId: string): Promise<Handoff[]> {
    await this.initialize();

    const stmt = this.db.prepare(`
      SELECT * FROM handoffs
      WHERE session_id = ?
      ORDER BY timestamp DESC
    `);

    const rows = stmt.all(sessionId) as any[];
    return rows.map(row => this.deserialize(row));
  }

  /**
   * Delete a handoff
   */
  async delete(id: string): Promise<boolean> {
    await this.initialize();

    const stmt = this.db.prepare(`DELETE FROM handoffs WHERE id = ?`);
    const result = stmt.run(id);

    logger.debug('Handoff deleted', { id, deleted: result.changes > 0 });
    return result.changes > 0;
  }

  /**
   * Get handoff count
   */
  async count(): Promise<number> {
    await this.initialize();

    const stmt = this.db.prepare(`SELECT COUNT(*) as count FROM handoffs`);
    const row = stmt.get() as any;
    return row?.count ?? 0;
  }

  /**
   * Get handoffs containing specific patterns
   */
  async findByPattern(pattern: string, limit: number = 10): Promise<Handoff[]> {
    await this.initialize();

    const stmt = this.db.prepare(`
      SELECT * FROM handoffs
      WHERE patterns LIKE ?
      ORDER BY timestamp DESC
      LIMIT ?
    `);

    const rows = stmt.all(`%${pattern}%`, limit) as any[];
    return rows.map(row => this.deserialize(row));
  }

  /**
   * Get handoffs with blockers
   */
  async getWithBlockers(limit: number = 10): Promise<Handoff[]> {
    await this.initialize();

    const stmt = this.db.prepare(`
      SELECT * FROM handoffs
      WHERE blockers IS NOT NULL AND blockers != '[]'
      ORDER BY timestamp DESC
      LIMIT ?
    `);

    const rows = stmt.all(limit) as any[];
    return rows.map(row => this.deserialize(row));
  }

  /**
   * Generate a summary context from recent handoffs
   */
  async generateContext(limit: number = 3): Promise<string> {
    const recent = await this.getRecent(limit);

    if (recent.length === 0) {
      return '';
    }

    const lines: string[] = [];
    lines.push('## Previous Session Context');
    lines.push('');

    for (const handoff of recent) {
      lines.push(`### Session: ${handoff.sessionId}`);
      lines.push(`*${handoff.timestamp.toISOString()}*`);
      lines.push('');
      lines.push(handoff.summary);
      lines.push('');

      if (handoff.currentState) {
        lines.push(`**Current State**: ${handoff.currentState}`);
      }

      if (handoff.nextSteps.length > 0) {
        lines.push('**Next Steps**:');
        for (const step of handoff.nextSteps.slice(0, 3)) {
          lines.push(`- ${step}`);
        }
      }

      if (handoff.patterns.length > 0) {
        lines.push(`**Patterns**: ${handoff.patterns.join(', ')}`);
      }

      lines.push('');
      lines.push('---');
      lines.push('');
    }

    return lines.join('\n');
  }

  /**
   * Close the database connection
   */
  async close(): Promise<void> {
    this.db.close();
    logger.info('Handoff manager closed');
  }

  // ===========================================================================
  // Private Helpers
  // ===========================================================================

  private sanitizeFtsQuery(query: string): string {
    // Escape special characters for FTS5
    // Split into words and add prefix matching
    return query
      .replace(/['"]/g, '') // Remove quotes
      .split(/\s+/)
      .filter(word => word.length > 0)
      .map(word => `"${word}"*`) // Prefix matching
      .join(' OR ');
  }

  private serializeCodeChanges(changes: CodeChange[]): string {
    // Create a searchable string from code changes
    return changes
      .map(c => `${c.file}: ${c.description}`)
      .join('\n');
  }

  private deserialize(row: any): Handoff {
    return {
      id: row.id,
      sessionId: row.session_id,
      timestamp: new Date(row.timestamp),
      summary: row.summary,
      codeChanges: this.parseCodeChanges(row.code_changes),
      currentState: row.current_state ?? '',
      blockers: this.parseJsonArray(row.blockers),
      nextSteps: this.parseJsonArray(row.next_steps),
      patterns: this.parseJsonArray(row.patterns),
      metadata: row.metadata ? JSON.parse(row.metadata) : undefined,
    };
  }

  private parseCodeChanges(content: string | null): CodeChange[] {
    if (!content) return [];

    // Parse the searchable format back to structured data
    return content.split('\n').filter(Boolean).map(line => {
      const [file, ...descParts] = line.split(': ');
      return {
        file: file ?? '',
        description: descParts.join(': ') || '',
      };
    });
  }

  private parseJsonArray(value: string | null): string[] {
    if (!value) return [];
    try {
      return JSON.parse(value);
    } catch {
      return [];
    }
  }
}

// =============================================================================
// Factory Function
// =============================================================================

export function createHandoffManager(dbPath: string): HandoffManager {
  return new HandoffManager({ dbPath });
}
