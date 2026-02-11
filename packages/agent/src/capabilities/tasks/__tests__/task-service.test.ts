/**
 * @fileoverview Tests for TaskService
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { DatabaseConnection } from '@infrastructure/events/sqlite/database.js';
import { runMigrations } from '@infrastructure/events/sqlite/migrations/index.js';
import { TaskRepository } from '../task-repository.js';
import { TaskService } from '../task-service.js';

describe('TaskService', () => {
  let connection: DatabaseConnection;
  let repo: TaskRepository;
  let service: TaskService;

  beforeEach(() => {
    connection = new DatabaseConnection(':memory:');
    const db = connection.open();
    runMigrations(db);
    repo = new TaskRepository(connection);
    service = new TaskService(repo);
  });

  afterEach(() => {
    connection.close();
  });

  // =========================================================================
  // Task Creation
  // =========================================================================

  describe('createTask', () => {
    it('creates a task with defaults', () => {
      const task = service.createTask({ title: 'Fix bug' });

      expect(task.title).toBe('Fix bug');
      expect(task.status).toBe('pending');
      expect(task.priority).toBe('medium');
      expect(task.source).toBe('agent');
    });

    it('logs creation activity', () => {
      const task = service.createTask({ title: 'Test', sessionId: 'sess_1' });
      const activity = repo.getActivity(task.id);

      expect(activity).toHaveLength(1);
      expect(activity[0].action).toBe('created');
      expect(activity[0].sessionId).toBe('sess_1');
    });

    it('auto-sets startedAt when created as in_progress', () => {
      const task = service.createTask({ title: 'WIP', status: 'in_progress' });
      expect(task.startedAt).toBeDefined();
    });

    it('auto-sets completedAt when created as completed', () => {
      const task = service.createTask({ title: 'Done', status: 'completed' });
      expect(task.completedAt).toBeDefined();
    });

    it('rejects 3-level nesting', () => {
      const parent = service.createTask({ title: 'Parent' });
      const child = service.createTask({ title: 'Child', parentTaskId: parent.id });

      expect(() => {
        service.createTask({ title: 'Grandchild', parentTaskId: child.id });
      }).toThrow('max 2-level hierarchy');
    });

    it('allows 2-level nesting', () => {
      const parent = service.createTask({ title: 'Parent' });
      const child = service.createTask({ title: 'Child', parentTaskId: parent.id });

      expect(child.parentTaskId).toBe(parent.id);
    });
  });

  // =========================================================================
  // Task Updates
  // =========================================================================

  describe('updateTask', () => {
    it('throws on non-existent task', () => {
      expect(() => {
        service.updateTask('task_nonexistent', { title: 'X' });
      }).toThrow('Task not found');
    });

    it('updates simple fields', () => {
      const task = service.createTask({ title: 'Original' });
      const updated = service.updateTask(task.id, { title: 'Updated', priority: 'high' });

      expect(updated.title).toBe('Updated');
      expect(updated.priority).toBe('high');
    });

    it('adds and removes tags', () => {
      const task = service.createTask({ title: 'Test', tags: ['a', 'b'] });

      const updated = service.updateTask(task.id, {
        addTags: ['c'],
        removeTags: ['a'],
      });

      expect(updated.tags).toEqual(['b', 'c']);
    });

    it('does not duplicate tags', () => {
      const task = service.createTask({ title: 'Test', tags: ['a'] });
      const updated = service.updateTask(task.id, { addTags: ['a'] });
      expect(updated.tags).toEqual(['a']);
    });

    it('appends timestamped notes', () => {
      const task = service.createTask({ title: 'Test' });

      const u1 = service.updateTask(task.id, { notes: 'First note' });
      expect(u1.notes).toContain('First note');

      const u2 = service.updateTask(task.id, { notes: 'Second note' });
      expect(u2.notes).toContain('First note');
      expect(u2.notes).toContain('Second note');
    });

    it('logs note_added activity', () => {
      const task = service.createTask({ title: 'Test' });
      service.updateTask(task.id, { notes: 'A note' });

      const activity = repo.getActivity(task.id);
      const noteActivity = activity.find(a => a.action === 'note_added');
      expect(noteActivity).toBeDefined();
      expect(noteActivity!.detail).toBe('A note');
    });
  });

  // =========================================================================
  // Status Transitions
  // =========================================================================

  describe('status transitions', () => {
    it('auto-sets startedAt on transition to in_progress', () => {
      const task = service.createTask({ title: 'Test' });
      expect(task.startedAt).toBeNull();

      const updated = service.updateTask(task.id, { status: 'in_progress' });
      expect(updated.startedAt).toBeDefined();
    });

    it('does not overwrite startedAt on second in_progress transition', () => {
      const task = service.createTask({ title: 'Test', status: 'in_progress' });
      const firstStarted = task.startedAt;

      // Go back to pending, then in_progress again
      service.updateTask(task.id, { status: 'pending' });
      const updated = service.updateTask(task.id, { status: 'in_progress' });

      // startedAt should remain from first time
      expect(updated.startedAt).toBe(firstStarted);
    });

    it('auto-sets completedAt on completion', () => {
      const task = service.createTask({ title: 'Test' });
      const updated = service.updateTask(task.id, { status: 'completed' });
      expect(updated.completedAt).toBeDefined();
    });

    it('auto-sets completedAt on cancellation', () => {
      const task = service.createTask({ title: 'Test' });
      const updated = service.updateTask(task.id, { status: 'cancelled' });
      expect(updated.completedAt).toBeDefined();
    });

    it('clears completedAt when reopening from completed', () => {
      const task = service.createTask({ title: 'Test', status: 'completed' });
      expect(task.completedAt).toBeDefined();

      const reopened = service.updateTask(task.id, { status: 'pending' });
      expect(reopened.completedAt).toBeNull();
    });

    it('logs status change activity', () => {
      const task = service.createTask({ title: 'Test' });
      service.updateTask(task.id, { status: 'in_progress' });

      const activity = repo.getActivity(task.id);
      const statusChange = activity.find(a => a.action === 'status_changed');
      expect(statusChange).toBeDefined();
      expect(statusChange!.oldValue).toBe('pending');
      expect(statusChange!.newValue).toBe('in_progress');
    });

    it('is idempotent (same status does not log)', () => {
      const task = service.createTask({ title: 'Test' });
      service.updateTask(task.id, { status: 'pending' }); // same as current

      const activity = repo.getActivity(task.id);
      const statusChanges = activity.filter(a => a.action === 'status_changed');
      expect(statusChanges).toHaveLength(0);
    });
  });

  // =========================================================================
  // Session Tracking
  // =========================================================================

  describe('session tracking', () => {
    it('updates last_session_id on mutation', () => {
      const task = service.createTask({ title: 'Test', sessionId: 'sess_1' });
      expect(task.lastSessionId).toBe('sess_1');

      const updated = service.updateTask(task.id, { title: 'Changed', sessionId: 'sess_2' });
      expect(updated.lastSessionId).toBe('sess_2');
      expect(updated.lastSessionAt).toBeDefined();
    });
  });

  // =========================================================================
  // Hierarchy Enforcement
  // =========================================================================

  describe('hierarchy enforcement', () => {
    it('prevents moving task under a subtask', () => {
      const parent = service.createTask({ title: 'Parent' });
      const child = service.createTask({ title: 'Child', parentTaskId: parent.id });
      const other = service.createTask({ title: 'Other' });

      expect(() => {
        service.updateTask(other.id, { parentTaskId: child.id });
      }).toThrow('max 2-level hierarchy');
    });

    it('allows moving task under a top-level task', () => {
      const parent = service.createTask({ title: 'Parent' });
      const other = service.createTask({ title: 'Other' });

      const moved = service.updateTask(other.id, { parentTaskId: parent.id });
      expect(moved.parentTaskId).toBe(parent.id);
    });
  });

  // =========================================================================
  // Time Tracking
  // =========================================================================

  describe('logTime', () => {
    it('increments actual minutes', () => {
      const task = service.createTask({ title: 'Test' });

      service.logTime(task.id, 30);
      service.logTime(task.id, 15);

      const updated = repo.getTask(task.id)!;
      expect(updated.actualMinutes).toBe(45);
    });

    it('logs time_logged activity', () => {
      const task = service.createTask({ title: 'Test' });
      service.logTime(task.id, 30, 'sess_1', 'Research phase');

      const activity = repo.getActivity(task.id);
      const timeLog = activity.find(a => a.action === 'time_logged');
      expect(timeLog).toBeDefined();
      expect(timeLog!.minutesLogged).toBe(30);
      expect(timeLog!.detail).toBe('Research phase');
    });

    it('throws on non-existent task', () => {
      expect(() => service.logTime('task_x', 30)).toThrow('Task not found');
    });
  });

  // =========================================================================
  // Dependencies
  // =========================================================================

  describe('addDependency', () => {
    it('adds a blocking dependency', () => {
      const a = service.createTask({ title: 'A' });
      const b = service.createTask({ title: 'B' });

      service.addDependency(a.id, b.id);

      const details = service.getTask(b.id)!;
      expect(details.blockedBy).toHaveLength(1);
      expect(details.blockedBy[0].blockerTaskId).toBe(a.id);
    });

    it('rejects circular dependencies', () => {
      const a = service.createTask({ title: 'A' });
      const b = service.createTask({ title: 'B' });
      service.addDependency(a.id, b.id);

      expect(() => service.addDependency(b.id, a.id)).toThrow('Circular dependency');
    });

    it('logs activity on both tasks', () => {
      const a = service.createTask({ title: 'A' });
      const b = service.createTask({ title: 'B' });
      service.addDependency(a.id, b.id);

      const aActivity = repo.getActivity(a.id);
      const bActivity = repo.getActivity(b.id);
      expect(aActivity.some(act => act.action === 'dependency_added')).toBe(true);
      expect(bActivity.some(act => act.action === 'dependency_added')).toBe(true);
    });
  });

  describe('removeDependency', () => {
    it('removes dependency and logs activity', () => {
      const a = service.createTask({ title: 'A' });
      const b = service.createTask({ title: 'B' });
      service.addDependency(a.id, b.id);

      service.removeDependency(a.id, b.id);

      const details = service.getTask(b.id)!;
      expect(details.blockedBy).toHaveLength(0);

      const activity = repo.getActivity(b.id);
      expect(activity.some(act => act.action === 'dependency_removed')).toBe(true);
    });
  });

  // =========================================================================
  // Get / List / Search
  // =========================================================================

  describe('getTask', () => {
    it('returns task with details', () => {
      const task = service.createTask({ title: 'Parent' });
      service.createTask({ title: 'Sub', parentTaskId: task.id });

      const details = service.getTask(task.id);
      expect(details).toBeDefined();
      expect(details!.subtasks).toHaveLength(1);
      expect(details!.recentActivity.length).toBeGreaterThan(0);
    });

    it('returns undefined for non-existent', () => {
      expect(service.getTask('task_nope')).toBeUndefined();
    });
  });

  describe('deleteTask', () => {
    it('deletes task and returns true', () => {
      const task = service.createTask({ title: 'Test' });
      expect(service.deleteTask(task.id)).toBe(true);
      expect(service.getTask(task.id)).toBeUndefined();
    });

    it('returns false for non-existent', () => {
      expect(service.deleteTask('task_nope')).toBe(false);
    });
  });

  // =========================================================================
  // Project Operations
  // =========================================================================

  describe('project operations', () => {
    it('creates and lists projects', () => {
      service.createProject({ title: 'Auth' });
      service.createProject({ title: 'Deploy' });

      const result = service.listProjects();
      expect(result.projects).toHaveLength(2);
    });

    it('updates project fields', () => {
      const project = service.createProject({ title: 'Original' });
      const updated = service.updateProject(project.id, { title: 'New', status: 'completed' });

      expect(updated.title).toBe('New');
      expect(updated.status).toBe('completed');
      expect(updated.completedAt).toBeDefined();
    });

    it('throws on non-existent project update', () => {
      expect(() => service.updateProject('proj_x', { title: 'X' })).toThrow('Project not found');
    });
  });
});
