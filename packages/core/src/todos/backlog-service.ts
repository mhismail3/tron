/**
 * @fileoverview Backlog Service
 *
 * Manages persistent storage of backlogged tasks.
 * Tasks are moved to the backlog when context is cleared or sessions end.
 */

import type Database from 'better-sqlite3';
import type { TodoItem, BackloggedTask, BacklogReason } from './types.js';
import { createLogger } from '../logging/logger.js';

const logger = createLogger('backlog-service');

// =============================================================================
// Types
// =============================================================================

/**
 * Database row for task_backlog table
 */
interface BacklogRow {
  id: string;
  workspace_id: string;
  source_session_id: string;
  content: string;
  active_form: string;
  status: string;
  source: string;
  created_at: string;
  completed_at: string | null;
  backlogged_at: string;
  backlog_reason: string;
  metadata: string | null;
  restored_to_session_id: string | null;
  restored_at: string | null;
}

/**
 * Options for querying backlog
 */
export interface BacklogQueryOptions {
  /** Include already-restored tasks */
  includeRestored?: boolean;
  /** Limit number of results */
  limit?: number;
  /** Filter by status */
  status?: 'pending' | 'in_progress';
}

// =============================================================================
// BacklogService
// =============================================================================

/**
 * BacklogService manages persistent storage of backlogged tasks.
 *
 * Key responsibilities:
 * - Move incomplete tasks to backlog on context clear
 * - Query backlogged tasks by workspace
 * - Restore tasks from backlog to new sessions
 */
export class BacklogService {
  private db: Database.Database;

  constructor(db: Database.Database) {
    this.db = db;
  }

  // ===========================================================================
  // Backlog Operations
  // ===========================================================================

  /**
   * Move incomplete tasks to the backlog.
   * Called when context is cleared or session ends.
   */
  backlogTasks(
    tasks: TodoItem[],
    sessionId: string,
    workspaceId: string,
    reason: BacklogReason
  ): void {
    if (tasks.length === 0) return;

    const now = new Date().toISOString();
    const stmt = this.db.prepare(`
      INSERT INTO task_backlog
      (id, workspace_id, source_session_id, content, active_form, status, source,
       created_at, completed_at, backlogged_at, backlog_reason, metadata)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);

    const insertMany = this.db.transaction(() => {
      for (const task of tasks) {
        stmt.run(
          task.id,
          workspaceId,
          sessionId,
          task.content,
          task.activeForm,
          task.status,
          task.source,
          task.createdAt,
          task.completedAt ?? null,
          now,
          reason,
          task.metadata ? JSON.stringify(task.metadata) : null
        );
      }
    });

    insertMany();

    logger.info('Tasks backlogged', {
      sessionId,
      workspaceId,
      taskCount: tasks.length,
      reason,
    });
  }

  /**
   * Get backlogged tasks for a workspace.
   */
  getBacklog(workspaceId: string, options?: BacklogQueryOptions): BackloggedTask[] {
    const includeRestored = options?.includeRestored ?? false;
    const limit = options?.limit ?? 100;
    const status = options?.status;

    let sql = `
      SELECT * FROM task_backlog
      WHERE workspace_id = ?
    `;
    const params: unknown[] = [workspaceId];

    if (!includeRestored) {
      sql += ' AND restored_to_session_id IS NULL';
    }

    if (status) {
      sql += ' AND status = ?';
      params.push(status);
    }

    sql += ' ORDER BY backlogged_at DESC';

    if (limit > 0) {
      sql += ' LIMIT ?';
      params.push(limit);
    }

    const rows = this.db.prepare(sql).all(...params) as BacklogRow[];
    return rows.map(this.rowToTask);
  }

  /**
   * Get a single backlogged task by ID.
   */
  getBackloggedTask(taskId: string): BackloggedTask | undefined {
    const row = this.db.prepare(`
      SELECT * FROM task_backlog WHERE id = ?
    `).get(taskId) as BacklogRow | undefined;

    if (!row) return undefined;
    return this.rowToTask(row);
  }

  /**
   * Restore tasks from backlog to a new session.
   * Marks original backlog entries as restored and returns new TodoItems.
   *
   * @param taskIds - IDs of tasks to restore
   * @param targetSessionId - Session to restore tasks to
   * @param generateId - Function to generate new task IDs
   * @returns Array of new TodoItems with fresh IDs
   */
  restoreTasks(
    taskIds: string[],
    targetSessionId: string,
    generateId: () => string
  ): TodoItem[] {
    if (taskIds.length === 0) return [];

    const now = new Date().toISOString();
    const restoredTasks: TodoItem[] = [];

    const markRestoredStmt = this.db.prepare(`
      UPDATE task_backlog
      SET restored_to_session_id = ?, restored_at = ?
      WHERE id = ?
    `);

    const getTaskStmt = this.db.prepare(`
      SELECT * FROM task_backlog WHERE id = ?
    `);

    const restoreMany = this.db.transaction(() => {
      for (const taskId of taskIds) {
        const row = getTaskStmt.get(taskId) as BacklogRow | undefined;
        if (!row) continue;

        // Skip already restored tasks
        if (row.restored_to_session_id) {
          logger.debug('Task already restored, skipping', { taskId });
          continue;
        }

        // Mark as restored in backlog
        markRestoredStmt.run(targetSessionId, now, taskId);

        // Create new TodoItem with fresh ID
        const newTodo: TodoItem = {
          id: generateId(),
          content: row.content,
          activeForm: row.active_form,
          status: 'pending', // Reset status on restore
          source: row.source as TodoItem['source'],
          createdAt: now,
          metadata: {
            ...this.parseMetadata(row.metadata),
            restoredFrom: taskId,
            originalCreatedAt: row.created_at,
          },
        };

        restoredTasks.push(newTodo);
      }
    });

    restoreMany();

    logger.info('Tasks restored from backlog', {
      targetSessionId,
      requestedCount: taskIds.length,
      restoredCount: restoredTasks.length,
    });

    return restoredTasks;
  }

  /**
   * Delete backlogged tasks (e.g., user dismisses them).
   */
  deleteBackloggedTasks(taskIds: string[]): number {
    if (taskIds.length === 0) return 0;

    const placeholders = taskIds.map(() => '?').join(',');
    const result = this.db.prepare(`
      DELETE FROM task_backlog WHERE id IN (${placeholders})
    `).run(...taskIds);

    logger.info('Backlogged tasks deleted', {
      requestedCount: taskIds.length,
      deletedCount: result.changes,
    });

    return result.changes;
  }

  /**
   * Get count of unrestored tasks for a workspace.
   */
  getUnrestoredCount(workspaceId: string): number {
    const row = this.db.prepare(`
      SELECT COUNT(*) as count FROM task_backlog
      WHERE workspace_id = ? AND restored_to_session_id IS NULL
    `).get(workspaceId) as { count: number };

    return row.count;
  }

  // ===========================================================================
  // Private Helpers
  // ===========================================================================

  /**
   * Convert database row to BackloggedTask
   */
  private rowToTask(row: BacklogRow): BackloggedTask {
    return {
      id: row.id,
      content: row.content,
      activeForm: row.active_form,
      status: row.status as BackloggedTask['status'],
      source: row.source as BackloggedTask['source'],
      createdAt: row.created_at,
      completedAt: row.completed_at ?? undefined,
      backloggedAt: row.backlogged_at,
      backlogReason: row.backlog_reason as BacklogReason,
      sourceSessionId: row.source_session_id,
      workspaceId: row.workspace_id,
      restoredToSessionId: row.restored_to_session_id ?? undefined,
      restoredAt: row.restored_at ?? undefined,
      metadata: row.metadata ? JSON.parse(row.metadata) : undefined,
    };
  }

  /**
   * Parse metadata JSON string
   */
  private parseMetadata(json: string | null): Record<string, unknown> {
    if (!json) return {};
    try {
      return JSON.parse(json);
    } catch {
      return {};
    }
  }
}

/**
 * Create a BacklogService instance
 */
export function createBacklogService(db: Database.Database): BacklogService {
  return new BacklogService(db);
}
