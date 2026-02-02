/**
 * @fileoverview Database Maintenance Service
 *
 * Provides maintenance operations for SQLite database health:
 * - Log pruning based on retention period
 * - Unreferenced blob cleanup
 * - WAL checkpointing
 * - Statistics gathering
 */

import type Database from 'better-sqlite3';

/**
 * Result of a maintenance run
 */
export interface MaintenanceResult {
  logsPruned: number;
  blobsCleaned: number;
}

/**
 * Database statistics
 */
export interface DatabaseStats {
  logCount: number;
  blobCount: number;
  unreferencedBlobCount: number;
}

/**
 * Database maintenance service for periodic cleanup operations
 */
export class DatabaseMaintenance {
  constructor(private db: Database.Database) {}

  /**
   * Run all maintenance operations
   *
   * @param logRetentionDays - Number of days to retain logs (default: 30)
   * @returns Results of maintenance operations
   */
  runMaintenance(logRetentionDays = 30): MaintenanceResult {
    const cutoff = new Date();
    cutoff.setDate(cutoff.getDate() - logRetentionDays);
    const cutoffStr = cutoff.toISOString();

    // 1. Prune old logs (FTS entries will be auto-deleted via trigger)
    const logsPruned = this.db
      .prepare('DELETE FROM logs WHERE timestamp < ?')
      .run(cutoffStr).changes;

    // 2. Clean unreferenced blobs
    const blobsCleaned = this.db.prepare('DELETE FROM blobs WHERE ref_count <= 0').run().changes;

    // 3. Run ANALYZE to update query planner statistics
    this.db.exec('ANALYZE');

    return { logsPruned, blobsCleaned };
  }

  /**
   * Run a passive WAL checkpoint
   *
   * This checkpoints as many WAL frames as possible without
   * blocking writers. Use this for background maintenance.
   */
  checkpoint(): void {
    try {
      this.db.pragma('wal_checkpoint(PASSIVE)');
    } catch {
      // Checkpoint may fail if not in WAL mode (e.g., in-memory database)
      // This is safe to ignore
    }
  }

  /**
   * Get database statistics for monitoring
   */
  getStats(): DatabaseStats {
    const logCount = (this.db.prepare('SELECT COUNT(*) as c FROM logs').get() as { c: number }).c;

    const blobCount = (this.db.prepare('SELECT COUNT(*) as c FROM blobs').get() as { c: number }).c;

    const unreferencedBlobCount = (
      this.db.prepare('SELECT COUNT(*) as c FROM blobs WHERE ref_count <= 0').get() as { c: number }
    ).c;

    return {
      logCount,
      blobCount,
      unreferencedBlobCount,
    };
  }
}
