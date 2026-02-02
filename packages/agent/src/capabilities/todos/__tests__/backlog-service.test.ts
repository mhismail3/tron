/**
 * @fileoverview Backlog Service Tests
 *
 * Comprehensive tests for the BacklogService including:
 * - Backlogging incomplete tasks
 * - Querying backlogged tasks by workspace
 * - Restoring tasks from backlog
 * - Deletion and count operations
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { DatabaseConnection } from '@infrastructure/events/sqlite/database.js';
import {
  BacklogService,
  createBacklogService,
  type TodoItem,
  type BackloggedTask,
  type BacklogReason,
} from '../index.js';

// =============================================================================
// Test Setup
// =============================================================================

/**
 * Create the task_backlog table schema
 * This mirrors the migration in v002-backlog.ts
 */
function createBacklogTable(db: ReturnType<DatabaseConnection['getDatabase']>): void {
  db.exec(`
    CREATE TABLE IF NOT EXISTS task_backlog (
      id TEXT PRIMARY KEY,
      workspace_id TEXT NOT NULL,
      source_session_id TEXT NOT NULL,
      content TEXT NOT NULL,
      active_form TEXT NOT NULL,
      status TEXT NOT NULL,
      source TEXT NOT NULL,
      created_at TEXT NOT NULL,
      completed_at TEXT,
      backlogged_at TEXT NOT NULL,
      backlog_reason TEXT NOT NULL,
      metadata TEXT,
      restored_to_session_id TEXT,
      restored_at TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_backlog_workspace ON task_backlog(workspace_id, backlogged_at DESC);
    CREATE INDEX IF NOT EXISTS idx_backlog_status ON task_backlog(status, restored_to_session_id);
    CREATE INDEX IF NOT EXISTS idx_backlog_session ON task_backlog(source_session_id);
  `);
}

function createTodo(overrides: Partial<TodoItem> = {}): TodoItem {
  const now = new Date().toISOString();
  return {
    id: `todo_${Math.random().toString(36).slice(2, 10)}`,
    content: 'Test task',
    activeForm: 'Testing task',
    status: 'pending',
    source: 'agent',
    createdAt: now,
    ...overrides,
  };
}

// =============================================================================
// BacklogService Tests
// =============================================================================

describe('BacklogService', () => {
  let connection: DatabaseConnection;
  let service: BacklogService;

  beforeEach(() => {
    connection = new DatabaseConnection(':memory:');
    connection.open();
    createBacklogTable(connection.getDatabase());
    service = new BacklogService(connection.getDatabase());
  });

  afterEach(() => {
    connection.close();
  });

  // =========================================================================
  // Factory Function
  // =========================================================================

  describe('createBacklogService', () => {
    it('creates a new BacklogService instance', () => {
      const svc = createBacklogService(connection.getDatabase());
      expect(svc).toBeInstanceOf(BacklogService);
    });
  });

  // =========================================================================
  // backlogTasks
  // =========================================================================

  describe('backlogTasks', () => {
    it('saves tasks to backlog', () => {
      const tasks = [
        createTodo({ id: 'task1', content: 'Task 1' }),
        createTodo({ id: 'task2', content: 'Task 2' }),
      ];

      service.backlogTasks(tasks, 'session-1', 'workspace-1', 'session_clear');

      const backlog = service.getBacklog('workspace-1');
      expect(backlog).toHaveLength(2);
      expect(backlog.map(t => t.id).sort()).toEqual(['task1', 'task2']);
    });

    it('sets backlog metadata correctly', () => {
      const task = createTodo({
        id: 'task1',
        content: 'Test content',
        activeForm: 'Testing content',
        status: 'in_progress',
        source: 'user',
        createdAt: '2024-01-01T00:00:00Z',
      });

      service.backlogTasks([task], 'session-1', 'workspace-1', 'context_compact');

      const backlog = service.getBacklog('workspace-1');
      expect(backlog).toHaveLength(1);

      const saved = backlog[0];
      expect(saved.content).toBe('Test content');
      expect(saved.activeForm).toBe('Testing content');
      expect(saved.status).toBe('in_progress');
      expect(saved.source).toBe('user');
      expect(saved.createdAt).toBe('2024-01-01T00:00:00Z');
      expect(saved.sourceSessionId).toBe('session-1');
      expect(saved.workspaceId).toBe('workspace-1');
      expect(saved.backlogReason).toBe('context_compact');
      expect(saved.backloggedAt).toBeDefined();
    });

    it('preserves task metadata', () => {
      const task = createTodo({
        id: 'task1',
        metadata: {
          priority: 'high',
          tags: ['urgent', 'bug'],
          customField: 'custom value',
        },
      });

      service.backlogTasks([task], 'session-1', 'workspace-1', 'session_clear');

      const backlog = service.getBacklog('workspace-1');
      expect(backlog[0].metadata).toEqual({
        priority: 'high',
        tags: ['urgent', 'bug'],
        customField: 'custom value',
      });
    });

    it('handles all backlog reasons', () => {
      const reasons: BacklogReason[] = ['session_clear', 'context_compact', 'session_end'];

      for (let i = 0; i < reasons.length; i++) {
        const task = createTodo({ id: `task-${i}` });
        service.backlogTasks([task], `session-${i}`, 'workspace-1', reasons[i]);
      }

      const backlog = service.getBacklog('workspace-1');
      expect(backlog).toHaveLength(3);
      expect(backlog.map(t => t.backlogReason).sort()).toEqual(reasons.sort());
    });

    it('handles empty task list', () => {
      service.backlogTasks([], 'session-1', 'workspace-1', 'session_clear');

      const backlog = service.getBacklog('workspace-1');
      expect(backlog).toHaveLength(0);
    });

    it('handles task without metadata', () => {
      const task = createTodo({ id: 'task1' });
      delete task.metadata;

      service.backlogTasks([task], 'session-1', 'workspace-1', 'session_clear');

      const backlog = service.getBacklog('workspace-1');
      expect(backlog[0].metadata).toBeUndefined();
    });

    it('handles task with completedAt', () => {
      const task = createTodo({
        id: 'task1',
        status: 'completed',
        completedAt: '2024-01-01T12:00:00Z',
      });

      service.backlogTasks([task], 'session-1', 'workspace-1', 'session_clear');

      const backlog = service.getBacklog('workspace-1');
      expect(backlog[0].completedAt).toBe('2024-01-01T12:00:00Z');
    });
  });

  // =========================================================================
  // getBacklog
  // =========================================================================

  describe('getBacklog', () => {
    beforeEach(() => {
      // Set up test data
      const tasks = [
        createTodo({ id: 'task1', status: 'pending' }),
        createTodo({ id: 'task2', status: 'in_progress' }),
        createTodo({ id: 'task3', status: 'pending' }),
      ];
      service.backlogTasks(tasks, 'session-1', 'workspace-1', 'session_clear');
    });

    it('returns tasks for workspace', () => {
      const backlog = service.getBacklog('workspace-1');
      expect(backlog).toHaveLength(3);
    });

    it('excludes tasks from other workspaces', () => {
      service.backlogTasks(
        [createTodo({ id: 'other-task' })],
        'session-2',
        'workspace-2',
        'session_clear'
      );

      const backlog1 = service.getBacklog('workspace-1');
      const backlog2 = service.getBacklog('workspace-2');

      expect(backlog1).toHaveLength(3);
      expect(backlog2).toHaveLength(1);
    });

    it('excludes restored tasks by default', () => {
      // Restore one task
      service.restoreTasks(['task1'], 'target-session', () => 'new-id');

      const backlog = service.getBacklog('workspace-1');
      expect(backlog).toHaveLength(2);
      expect(backlog.find(t => t.id === 'task1')).toBeUndefined();
    });

    it('includes restored tasks when option set', () => {
      service.restoreTasks(['task1'], 'target-session', () => 'new-id');

      const backlog = service.getBacklog('workspace-1', { includeRestored: true });
      expect(backlog).toHaveLength(3);
      expect(backlog.find(t => t.id === 'task1')).toBeDefined();
    });

    it('respects limit option', () => {
      const backlog = service.getBacklog('workspace-1', { limit: 2 });
      expect(backlog).toHaveLength(2);
    });

    it('filters by status', () => {
      const pendingOnly = service.getBacklog('workspace-1', { status: 'pending' });
      expect(pendingOnly).toHaveLength(2);
      expect(pendingOnly.every(t => t.status === 'pending')).toBe(true);

      const inProgressOnly = service.getBacklog('workspace-1', { status: 'in_progress' });
      expect(inProgressOnly).toHaveLength(1);
      expect(inProgressOnly[0].status).toBe('in_progress');
    });

    it('orders by backlogged_at descending', async () => {
      // Add tasks at different times
      const connection2 = new DatabaseConnection(':memory:');
      connection2.open();
      createBacklogTable(connection2.getDatabase());
      const service2 = new BacklogService(connection2.getDatabase());

      service2.backlogTasks([createTodo({ id: 'first' })], 's1', 'w1', 'session_clear');
      // Small delay to ensure different timestamps
      await new Promise(r => setTimeout(r, 10));
      service2.backlogTasks([createTodo({ id: 'second' })], 's2', 'w1', 'session_clear');
      await new Promise(r => setTimeout(r, 10));
      service2.backlogTasks([createTodo({ id: 'third' })], 's3', 'w1', 'session_clear');

      const backlog = service2.getBacklog('w1');
      expect(backlog.map(t => t.id)).toEqual(['third', 'second', 'first']);

      connection2.close();
    });

    it('returns empty array for unknown workspace', () => {
      const backlog = service.getBacklog('unknown-workspace');
      expect(backlog).toEqual([]);
    });
  });

  // =========================================================================
  // getBackloggedTask
  // =========================================================================

  describe('getBackloggedTask', () => {
    beforeEach(() => {
      service.backlogTasks(
        [createTodo({ id: 'task1', content: 'Find me' })],
        'session-1',
        'workspace-1',
        'session_clear'
      );
    });

    it('returns task by ID', () => {
      const task = service.getBackloggedTask('task1');
      expect(task).toBeDefined();
      expect(task?.content).toBe('Find me');
    });

    it('returns undefined for unknown ID', () => {
      const task = service.getBackloggedTask('unknown');
      expect(task).toBeUndefined();
    });
  });

  // =========================================================================
  // restoreTasks
  // =========================================================================

  describe('restoreTasks', () => {
    let idCounter: number;
    let generateId: () => string;

    beforeEach(() => {
      idCounter = 0;
      generateId = () => `new_${++idCounter}`;

      service.backlogTasks([
        createTodo({ id: 'task1', content: 'Task 1', status: 'pending' }),
        createTodo({ id: 'task2', content: 'Task 2', status: 'in_progress' }),
        createTodo({ id: 'task3', content: 'Task 3', status: 'pending' }),
      ], 'source-session', 'workspace-1', 'session_clear');
    });

    it('returns new TodoItems with fresh IDs', () => {
      const restored = service.restoreTasks(['task1'], 'target-session', generateId);

      expect(restored).toHaveLength(1);
      expect(restored[0].id).toBe('new_1');
      expect(restored[0].content).toBe('Task 1');
    });

    it('resets status to pending', () => {
      const restored = service.restoreTasks(['task2'], 'target-session', generateId);

      expect(restored[0].status).toBe('pending');
    });

    it('preserves content and activeForm', () => {
      const restored = service.restoreTasks(['task1'], 'target-session', generateId);

      const original = service.getBackloggedTask('task1');
      expect(restored[0].content).toBe(original?.content);
      expect(restored[0].activeForm).toBe(original?.activeForm);
    });

    it('sets new createdAt timestamp', () => {
      const before = new Date().toISOString();
      const restored = service.restoreTasks(['task1'], 'target-session', generateId);
      const after = new Date().toISOString();

      expect(restored[0].createdAt >= before).toBe(true);
      expect(restored[0].createdAt <= after).toBe(true);
    });

    it('adds restore metadata', () => {
      const originalTask = service.getBackloggedTask('task1');
      const restored = service.restoreTasks(['task1'], 'target-session', generateId);

      expect(restored[0].metadata?.restoredFrom).toBe('task1');
      expect(restored[0].metadata?.originalCreatedAt).toBe(originalTask?.createdAt);
    });

    it('marks original as restored in backlog', () => {
      service.restoreTasks(['task1'], 'target-session', generateId);

      const task = service.getBackloggedTask('task1');
      expect(task?.restoredToSessionId).toBe('target-session');
      expect(task?.restoredAt).toBeDefined();
    });

    it('skips already restored tasks', () => {
      // Restore once
      service.restoreTasks(['task1'], 'session-1', generateId);
      // Try to restore again
      const restored = service.restoreTasks(['task1'], 'session-2', generateId);

      expect(restored).toHaveLength(0);
    });

    it('handles multiple task restore', () => {
      const restored = service.restoreTasks(['task1', 'task2', 'task3'], 'target', generateId);

      expect(restored).toHaveLength(3);
      expect(restored.map(t => t.id)).toEqual(['new_1', 'new_2', 'new_3']);
    });

    it('handles empty task list', () => {
      const restored = service.restoreTasks([], 'target', generateId);
      expect(restored).toEqual([]);
    });

    it('handles unknown task IDs gracefully', () => {
      const restored = service.restoreTasks(['unknown'], 'target', generateId);
      expect(restored).toEqual([]);
    });

    it('handles mix of known and unknown IDs', () => {
      const restored = service.restoreTasks(['task1', 'unknown', 'task2'], 'target', generateId);

      expect(restored).toHaveLength(2);
      expect(restored.map(t => t.content).sort()).toEqual(['Task 1', 'Task 2']);
    });

    it('preserves original metadata on restore', () => {
      // Backlog a task with metadata
      service.backlogTasks([
        createTodo({
          id: 'meta-task',
          metadata: { priority: 'high', tags: ['important'] },
        }),
      ], 'session', 'workspace-1', 'session_clear');

      const restored = service.restoreTasks(['meta-task'], 'target', generateId);

      expect(restored[0].metadata?.priority).toBe('high');
      expect(restored[0].metadata?.tags).toEqual(['important']);
      expect(restored[0].metadata?.restoredFrom).toBe('meta-task');
    });
  });

  // =========================================================================
  // deleteBackloggedTasks
  // =========================================================================

  describe('deleteBackloggedTasks', () => {
    beforeEach(() => {
      service.backlogTasks([
        createTodo({ id: 'task1' }),
        createTodo({ id: 'task2' }),
        createTodo({ id: 'task3' }),
      ], 'session', 'workspace-1', 'session_clear');
    });

    it('deletes specified tasks', () => {
      const deleted = service.deleteBackloggedTasks(['task1', 'task2']);

      expect(deleted).toBe(2);

      const remaining = service.getBacklog('workspace-1');
      expect(remaining).toHaveLength(1);
      expect(remaining[0].id).toBe('task3');
    });

    it('returns count of deleted tasks', () => {
      const deleted = service.deleteBackloggedTasks(['task1']);
      expect(deleted).toBe(1);
    });

    it('handles non-existent IDs', () => {
      const deleted = service.deleteBackloggedTasks(['unknown']);
      expect(deleted).toBe(0);
    });

    it('handles empty ID list', () => {
      const deleted = service.deleteBackloggedTasks([]);
      expect(deleted).toBe(0);
    });

    it('handles mix of existing and non-existing IDs', () => {
      const deleted = service.deleteBackloggedTasks(['task1', 'unknown', 'task2']);
      expect(deleted).toBe(2);
    });
  });

  // =========================================================================
  // getUnrestoredCount
  // =========================================================================

  describe('getUnrestoredCount', () => {
    it('returns 0 for empty workspace', () => {
      expect(service.getUnrestoredCount('empty-workspace')).toBe(0);
    });

    it('counts unrestored tasks', () => {
      service.backlogTasks([
        createTodo({ id: 'task1' }),
        createTodo({ id: 'task2' }),
        createTodo({ id: 'task3' }),
      ], 'session', 'workspace-1', 'session_clear');

      expect(service.getUnrestoredCount('workspace-1')).toBe(3);
    });

    it('excludes restored tasks from count', () => {
      service.backlogTasks([
        createTodo({ id: 'task1' }),
        createTodo({ id: 'task2' }),
        createTodo({ id: 'task3' }),
      ], 'session', 'workspace-1', 'session_clear');

      service.restoreTasks(['task1'], 'target', () => 'new-id');

      expect(service.getUnrestoredCount('workspace-1')).toBe(2);
    });

    it('counts only specified workspace', () => {
      service.backlogTasks([createTodo({ id: 'task1' })], 'session', 'workspace-1', 'session_clear');
      service.backlogTasks([createTodo({ id: 'task2' })], 'session', 'workspace-2', 'session_clear');
      service.backlogTasks([createTodo({ id: 'task3' })], 'session', 'workspace-2', 'session_clear');

      expect(service.getUnrestoredCount('workspace-1')).toBe(1);
      expect(service.getUnrestoredCount('workspace-2')).toBe(2);
    });
  });
});
