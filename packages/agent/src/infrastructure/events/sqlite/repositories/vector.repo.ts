/**
 * @fileoverview Vector Repository
 *
 * sqlite-vec backed vector storage for semantic memory search.
 * Stores embeddings alongside event IDs for KNN retrieval.
 *
 * The virtual table uses vec0 format with Float32 vectors at 512 dimensions.
 * KNN search uses cosine distance via the MATCH operator.
 */

import type { DatabaseConnection } from '../database.js';

// =============================================================================
// Types
// =============================================================================

export interface VectorSearchResult {
  eventId: string;
  workspaceId: string;
  distance: number;
}

export interface VectorSearchOptions {
  limit?: number;
  workspaceId?: string;
  excludeWorkspaceId?: string;
}

// =============================================================================
// VectorRepository
// =============================================================================

export class VectorRepository {
  private connection: DatabaseConnection;
  private readonly dimensions: number;

  constructor(connection: DatabaseConnection, dimensions = 512) {
    this.connection = connection;
    this.dimensions = dimensions;
  }

  private get db() {
    return this.connection.getDatabase();
  }

  /**
   * Create the memory_vectors virtual table if it doesn't exist.
   * Must be called after sqlite-vec extension is loaded.
   */
  ensureTable(): void {
    this.db.exec(`
      CREATE VIRTUAL TABLE IF NOT EXISTS memory_vectors USING vec0(
        event_id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL,
        embedding float[${this.dimensions}]
      )
    `);
  }

  store(eventId: string, workspaceId: string, embedding: Float32Array): void {
    // sqlite-vec virtual tables don't support INSERT OR REPLACE,
    // so delete first then insert.
    this.delete(eventId);
    const buffer = Buffer.from(embedding.buffer, embedding.byteOffset, embedding.byteLength);
    this.db.prepare(
      'INSERT INTO memory_vectors (event_id, workspace_id, embedding) VALUES (?, ?, ?)'
    ).run(eventId, workspaceId, buffer);
  }

  search(query: Float32Array, options: VectorSearchOptions = {}): VectorSearchResult[] {
    const limit = options.limit ?? 10;
    const queryBuffer = Buffer.from(query.buffer, query.byteOffset, query.byteLength);

    // sqlite-vec KNN query via MATCH + k parameter
    // Then filter by workspace in the outer query
    let sql: string;
    const params: (string | number | Buffer)[] = [];

    if (options.workspaceId) {
      sql = `
        SELECT event_id, workspace_id, distance
        FROM memory_vectors
        WHERE embedding MATCH ? AND k = ?
          AND workspace_id = ?
        ORDER BY distance
      `;
      params.push(queryBuffer, limit, options.workspaceId);
    } else if (options.excludeWorkspaceId) {
      // Fetch more than needed since we filter post-KNN
      sql = `
        SELECT event_id, workspace_id, distance
        FROM memory_vectors
        WHERE embedding MATCH ? AND k = ?
          AND workspace_id != ?
        ORDER BY distance
      `;
      params.push(queryBuffer, limit * 2, options.excludeWorkspaceId);
    } else {
      sql = `
        SELECT event_id, workspace_id, distance
        FROM memory_vectors
        WHERE embedding MATCH ? AND k = ?
        ORDER BY distance
      `;
      params.push(queryBuffer, limit);
    }

    const rows = this.db.prepare(sql).all(...params) as Array<{
      event_id: string;
      workspace_id: string;
      distance: number;
    }>;

    return rows.slice(0, limit).map(row => ({
      eventId: row.event_id,
      workspaceId: row.workspace_id,
      distance: row.distance,
    }));
  }

  delete(eventId: string): void {
    this.db.prepare('DELETE FROM memory_vectors WHERE event_id = ?').run(eventId);
  }

  hasTable(): boolean {
    try {
      const row = this.db.prepare(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='memory_vectors'"
      ).get() as { name: string } | null;
      return !!row;
    } catch {
      return false;
    }
  }

  count(): number {
    try {
      const row = this.db.prepare('SELECT COUNT(*) as count FROM memory_vectors').get() as { count: number } | null;
      return row?.count ?? 0;
    } catch {
      return 0;
    }
  }
}
