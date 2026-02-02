/**
 * @fileoverview Branch Repository
 *
 * Handles session branching operations for conversation tree navigation.
 */

import { BaseRepository, rowUtils } from './base.js';
import { BranchId, SessionId, EventId } from '../../types.js';
import type { BranchDbRow } from '../types.js';

/**
 * Branch entity
 */
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

/**
 * Options for creating a branch
 */
export interface CreateBranchOptions {
  sessionId: SessionId;
  name: string;
  description?: string;
  rootEventId: EventId;
  headEventId: EventId;
  isDefault?: boolean;
}

/**
 * Repository for branch operations
 */
export class BranchRepository extends BaseRepository {
  /**
   * Create a new branch
   */
  create(options: CreateBranchOptions): BranchRow {
    const id = BranchId(`br_${this.generateId('').slice(1)}`);
    const now = this.now();

    this.run(
      `INSERT INTO branches (id, session_id, name, description, root_event_id, head_event_id, is_default, created_at, last_activity_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      id,
      options.sessionId,
      options.name,
      options.description ?? null,
      options.rootEventId,
      options.headEventId,
      options.isDefault ? 1 : 0,
      now,
      now
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

  /**
   * Get branch by ID
   */
  getById(branchId: BranchId): BranchRow | null {
    const row = this.get<BranchDbRow>('SELECT * FROM branches WHERE id = ?', branchId);
    if (!row) return null;
    return this.rowToBranch(row);
  }

  /**
   * Get all branches for a session
   */
  getBySession(sessionId: SessionId): BranchRow[] {
    const rows = this.all<BranchDbRow>(
      'SELECT * FROM branches WHERE session_id = ? ORDER BY created_at ASC',
      sessionId
    );
    return rows.map(row => this.rowToBranch(row));
  }

  /**
   * Get the default branch for a session
   */
  getDefault(sessionId: SessionId): BranchRow | null {
    const row = this.get<BranchDbRow>(
      'SELECT * FROM branches WHERE session_id = ? AND is_default = 1',
      sessionId
    );
    if (!row) return null;
    return this.rowToBranch(row);
  }

  /**
   * Update branch head event
   */
  updateHead(branchId: BranchId, headEventId: EventId): void {
    const now = this.now();
    this.run(
      'UPDATE branches SET head_event_id = ?, last_activity_at = ? WHERE id = ?',
      headEventId,
      now,
      branchId
    );
  }

  /**
   * Update branch name
   */
  updateName(branchId: BranchId, name: string): void {
    this.run('UPDATE branches SET name = ? WHERE id = ?', name, branchId);
  }

  /**
   * Update branch description
   */
  updateDescription(branchId: BranchId, description: string | null): void {
    this.run('UPDATE branches SET description = ? WHERE id = ?', description, branchId);
  }

  /**
   * Set branch as default (and unset others in session)
   */
  setDefault(branchId: BranchId): void {
    // Get the session ID for this branch
    const branch = this.getById(branchId);
    if (!branch) return;

    // Unset all defaults for this session
    this.run('UPDATE branches SET is_default = 0 WHERE session_id = ?', branch.sessionId);

    // Set this branch as default
    this.run('UPDATE branches SET is_default = 1 WHERE id = ?', branchId);
  }

  /**
   * Delete a branch
   */
  delete(branchId: BranchId): boolean {
    const result = this.run('DELETE FROM branches WHERE id = ?', branchId);
    return result.changes > 0;
  }

  /**
   * Delete all branches for a session
   */
  deleteBySession(sessionId: SessionId): number {
    const result = this.run('DELETE FROM branches WHERE session_id = ?', sessionId);
    return result.changes;
  }

  /**
   * Count branches for a session
   */
  countBySession(sessionId: SessionId): number {
    const row = this.get<{ count: number }>(
      'SELECT COUNT(*) as count FROM branches WHERE session_id = ?',
      sessionId
    );
    return row?.count ?? 0;
  }

  /**
   * Check if branch exists
   */
  exists(branchId: BranchId): boolean {
    const row = this.get<{ id: string }>('SELECT id FROM branches WHERE id = ?', branchId);
    return row !== undefined;
  }

  /**
   * Convert database row to BranchRow entity
   */
  private rowToBranch(row: BranchDbRow): BranchRow {
    return {
      id: BranchId(row.id),
      sessionId: SessionId(row.session_id),
      name: row.name,
      description: row.description,
      rootEventId: EventId(row.root_event_id),
      headEventId: EventId(row.head_event_id),
      isDefault: rowUtils.toBoolean(row.is_default),
      createdAt: row.created_at,
      lastActivityAt: row.last_activity_at,
    };
  }
}
