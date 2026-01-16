/**
 * @fileoverview Workspace Repository
 *
 * Handles workspace (project/directory context) operations.
 */

import { BaseRepository } from './base.js';
import { WorkspaceId, type Workspace } from '../../types.js';
import type { WorkspaceDbRow } from '../types.js';

/**
 * Options for creating a workspace
 */
export interface CreateWorkspaceOptions {
  path: string;
  name?: string;
}

/**
 * Repository for workspace operations
 */
export class WorkspaceRepository extends BaseRepository {
  /**
   * Create a new workspace
   */
  create(options: CreateWorkspaceOptions): Workspace {
    const id = WorkspaceId(`ws_${this.generateId('').slice(1)}`);
    const now = this.now();

    this.run(
      `INSERT INTO workspaces (id, path, name, created_at, last_activity_at)
       VALUES (?, ?, ?, ?, ?)`,
      id,
      options.path,
      options.name ?? null,
      now,
      now
    );

    return {
      id,
      path: options.path,
      name: options.name,
      created: now,
      lastActivity: now,
      sessionCount: 0,
    };
  }

  /**
   * Get workspace by ID
   */
  getById(workspaceId: WorkspaceId): Workspace | null {
    const row = this.get<WorkspaceDbRow & { session_count?: number }>(
      `SELECT w.*, (SELECT COUNT(*) FROM sessions WHERE workspace_id = w.id) as session_count
       FROM workspaces w
       WHERE id = ?`,
      workspaceId
    );

    if (!row) return null;
    return this.rowToWorkspace(row);
  }

  /**
   * Get workspace by file system path
   */
  getByPath(path: string): Workspace | null {
    const row = this.get<WorkspaceDbRow & { session_count?: number }>(
      `SELECT w.*, (SELECT COUNT(*) FROM sessions WHERE workspace_id = w.id) as session_count
       FROM workspaces w
       WHERE path = ?`,
      path
    );

    if (!row) return null;
    return this.rowToWorkspace(row);
  }

  /**
   * Get or create a workspace for the given path
   */
  getOrCreate(path: string, name?: string): Workspace {
    const existing = this.getByPath(path);
    if (existing) return existing;
    return this.create({ path, name });
  }

  /**
   * List all workspaces, ordered by last activity
   */
  list(): Workspace[] {
    const rows = this.all<WorkspaceDbRow & { session_count: number }>(
      `SELECT w.*, (SELECT COUNT(*) FROM sessions WHERE workspace_id = w.id) as session_count
       FROM workspaces w
       ORDER BY last_activity_at DESC`
    );

    return rows.map(row => this.rowToWorkspace(row));
  }

  /**
   * Update workspace last activity timestamp
   */
  updateLastActivity(workspaceId: WorkspaceId): void {
    this.run(
      'UPDATE workspaces SET last_activity_at = ? WHERE id = ?',
      this.now(),
      workspaceId
    );
  }

  /**
   * Update workspace name
   */
  updateName(workspaceId: WorkspaceId, name: string | null): void {
    this.run(
      'UPDATE workspaces SET name = ? WHERE id = ?',
      name,
      workspaceId
    );
  }

  /**
   * Delete a workspace
   * Note: This will fail if there are sessions referencing the workspace
   */
  delete(workspaceId: WorkspaceId): boolean {
    const result = this.run('DELETE FROM workspaces WHERE id = ?', workspaceId);
    return result.changes > 0;
  }

  /**
   * Get total workspace count
   */
  count(): number {
    const row = this.get<{ count: number }>('SELECT COUNT(*) as count FROM workspaces');
    return row?.count ?? 0;
  }

  /**
   * Check if a workspace exists
   */
  exists(workspaceId: WorkspaceId): boolean {
    const row = this.get<{ id: string }>('SELECT id FROM workspaces WHERE id = ?', workspaceId);
    return row !== undefined;
  }

  /**
   * Convert database row to Workspace entity
   */
  private rowToWorkspace(row: WorkspaceDbRow & { session_count?: number }): Workspace {
    return {
      id: WorkspaceId(row.id),
      path: row.path,
      name: row.name ?? undefined,
      created: row.created_at,
      lastActivity: row.last_activity_at,
      sessionCount: row.session_count ?? 0,
    };
  }
}
