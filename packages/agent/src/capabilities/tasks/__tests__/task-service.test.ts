/**
 * @fileoverview Tests for TaskService
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { DatabaseConnection } from '@infrastructure/events/sqlite/database.js';
import { runMigrations } from '@infrastructure/events/sqlite/migrations/index.js';
import { TaskRepository } from '../task-repository.js';
import { TaskService } from '../task-service.js';

describe('TaskService', () => {
  let connection: DatabaseConnection;
  let repo: TaskRepository;
  let service: TaskService;
  let emitSpy: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    connection = new DatabaseConnection(':memory:');
    const db = connection.open();
    runMigrations(db);
    repo = new TaskRepository(connection);
    emitSpy = vi.fn();
    service = new TaskService(repo, emitSpy);
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

  // =========================================================================
  // Area Operations
  // =========================================================================

  describe('area operations', () => {
    it('creates area with title', () => {
      const area = service.createArea({ title: 'Security' });
      expect(area.title).toBe('Security');
      expect(area.status).toBe('active');
    });

    it('validates title required', () => {
      expect(() => service.createArea({ title: '' })).toThrow('title is required');
    });

    it('returns area with counts from getArea', () => {
      const area = service.createArea({ title: 'Ops' });
      const found = service.getArea(area.id);
      expect(found).toBeDefined();
      expect(found!.projectCount).toBe(0);
      expect(found!.taskCount).toBe(0);
    });

    it('returns undefined for non-existent area', () => {
      expect(service.getArea('area_nope')).toBeUndefined();
    });

    it('updates area fields', () => {
      const area = service.createArea({ title: 'Original' });
      const updated = service.updateArea(area.id, { title: 'Renamed', description: 'New' });
      expect(updated.title).toBe('Renamed');
      expect(updated.description).toBe('New');
    });

    it('throws on non-existent area update', () => {
      expect(() => service.updateArea('area_nope', { title: 'X' })).toThrow('Area not found');
    });

    it('archives area', () => {
      const area = service.createArea({ title: 'To archive' });
      const archived = service.updateArea(area.id, { status: 'archived' });
      expect(archived.status).toBe('archived');
    });

    it('deletes area and returns true', () => {
      const area = service.createArea({ title: 'To delete' });
      expect(service.deleteArea(area.id)).toBe(true);
      expect(service.getArea(area.id)).toBeUndefined();
    });

    it('returns false for non-existent delete', () => {
      expect(service.deleteArea('area_nope')).toBe(false);
    });

    it('unlinks projects and tasks on delete', () => {
      const area = service.createArea({ title: 'Area' });
      const project = service.createProject({ title: 'Proj', areaId: area.id });
      const task = service.createTask({ title: 'Task', areaId: area.id });

      service.deleteArea(area.id);

      expect(repo.getProject(project.id)!.areaId).toBeNull();
      expect(repo.getTask(task.id)!.areaId).toBeNull();
    });

    it('lists active areas with counts', () => {
      service.createArea({ title: 'A' });
      service.createArea({ title: 'B' });

      const result = service.listAreas();
      expect(result.areas).toHaveLength(2);
    });

    it('filters areas by status', () => {
      service.createArea({ title: 'Active' });
      const archived = service.createArea({ title: 'Archived' });
      service.updateArea(archived.id, { status: 'archived' });

      const result = service.listAreas({ status: 'active' });
      expect(result.areas).toHaveLength(1);
    });

    it('searches areas', () => {
      service.createArea({ title: 'Security monitoring' });
      service.createArea({ title: 'Code quality' });

      const results = service.searchAreas('security');
      expect(results).toHaveLength(1);
    });
  });

  // =========================================================================
  // Project Delete + Get with Details
  // =========================================================================

  describe('deleteProject', () => {
    it('deletes project and returns true', () => {
      const project = service.createProject({ title: 'To delete' });
      expect(service.deleteProject(project.id)).toBe(true);
      expect(service.getProject(project.id)).toBeUndefined();
    });

    it('orphans tasks (project_id set to null, tasks still exist)', () => {
      const project = service.createProject({ title: 'Proj' });
      const task = service.createTask({ title: 'Task', projectId: project.id });

      service.deleteProject(project.id);

      const updated = repo.getTask(task.id);
      expect(updated).toBeDefined();
      expect(updated!.projectId).toBeNull();
    });

    it('returns false for non-existent', () => {
      expect(service.deleteProject('proj_nope')).toBe(false);
    });
  });

  describe('getProjectWithDetails', () => {
    it('returns project with task list', () => {
      const project = service.createProject({ title: 'Proj' });
      service.createTask({ title: 'T1', projectId: project.id });
      service.createTask({ title: 'T2', projectId: project.id });

      const details = service.getProjectWithDetails(project.id);
      expect(details).toBeDefined();
      expect(details!.title).toBe('Proj');
      expect(details!.tasks).toHaveLength(2);
    });

    it('returns project with area info when linked', () => {
      const area = service.createArea({ title: 'Area' });
      const project = service.createProject({ title: 'Proj', areaId: area.id });

      const details = service.getProjectWithDetails(project.id);
      expect(details!.area).toBeDefined();
      expect(details!.area!.title).toBe('Area');
    });

    it('returns undefined for non-existent', () => {
      expect(service.getProjectWithDetails('proj_nope')).toBeUndefined();
    });
  });

  // =========================================================================
  // areaId on Tasks / Projects
  // =========================================================================

  describe('areaId on tasks', () => {
    it('createTask with areaId stores it', () => {
      const area = service.createArea({ title: 'Area' });
      const task = service.createTask({ title: 'Task', areaId: area.id });
      expect(task.areaId).toBe(area.id);
    });

    it('updateTask can change areaId', () => {
      const area = service.createArea({ title: 'Area' });
      const task = service.createTask({ title: 'Task' });
      const updated = service.updateTask(task.id, { areaId: area.id });
      expect(updated.areaId).toBe(area.id);
    });

    it('updateTask can clear areaId', () => {
      const area = service.createArea({ title: 'Area' });
      const task = service.createTask({ title: 'Task', areaId: area.id });
      const updated = service.updateTask(task.id, { areaId: null });
      expect(updated.areaId).toBeNull();
    });
  });

  describe('areaId on projects', () => {
    it('createProject with areaId stores it', () => {
      const area = service.createArea({ title: 'Area' });
      const project = service.createProject({ title: 'Proj', areaId: area.id });
      expect(project.areaId).toBe(area.id);
    });

    it('updateProject can change areaId', () => {
      const area = service.createArea({ title: 'Area' });
      const project = service.createProject({ title: 'Proj' });
      const updated = service.updateProject(project.id, { areaId: area.id });
      expect(updated.areaId).toBe(area.id);
    });

    it('updateProject can clear areaId', () => {
      const area = service.createArea({ title: 'Area' });
      const project = service.createProject({ title: 'Proj', areaId: area.id });
      const updated = service.updateProject(project.id, { areaId: null });
      expect(updated.areaId).toBeNull();
    });
  });

  // =========================================================================
  // Event Emission
  // =========================================================================

  describe('event emission', () => {
    it('createTask emits task.created', () => {
      service.createTask({ title: 'Test' });
      expect(emitSpy).toHaveBeenCalledWith('task.created', expect.objectContaining({ title: 'Test' }));
    });

    it('updateTask emits task.updated with changedFields', () => {
      const task = service.createTask({ title: 'Test' });
      emitSpy.mockClear();
      service.updateTask(task.id, { title: 'New', priority: 'high' });
      expect(emitSpy).toHaveBeenCalledWith('task.updated', expect.objectContaining({
        taskId: task.id,
        changedFields: expect.arrayContaining(['title', 'priority']),
      }));
    });

    it('deleteTask emits task.deleted', () => {
      const task = service.createTask({ title: 'Test' });
      emitSpy.mockClear();
      service.deleteTask(task.id);
      expect(emitSpy).toHaveBeenCalledWith('task.deleted', expect.objectContaining({ taskId: task.id }));
    });

    it('createArea emits area.created', () => {
      service.createArea({ title: 'Area' });
      expect(emitSpy).toHaveBeenCalledWith('area.created', expect.objectContaining({ title: 'Area' }));
    });

    it('updateArea emits area.updated', () => {
      const area = service.createArea({ title: 'Area' });
      emitSpy.mockClear();
      service.updateArea(area.id, { title: 'New' });
      expect(emitSpy).toHaveBeenCalledWith('area.updated', expect.objectContaining({ areaId: area.id }));
    });

    it('deleteArea emits area.deleted', () => {
      const area = service.createArea({ title: 'Area' });
      emitSpy.mockClear();
      service.deleteArea(area.id);
      expect(emitSpy).toHaveBeenCalledWith('area.deleted', expect.objectContaining({ areaId: area.id }));
    });

    it('createProject emits project.created', () => {
      service.createProject({ title: 'Proj' });
      expect(emitSpy).toHaveBeenCalledWith('project.created', expect.objectContaining({ title: 'Proj' }));
    });

    it('deleteProject emits project.deleted', () => {
      const project = service.createProject({ title: 'Proj' });
      emitSpy.mockClear();
      service.deleteProject(project.id);
      expect(emitSpy).toHaveBeenCalledWith('project.deleted', expect.objectContaining({ projectId: project.id }));
    });

    it('updateProject emits project.updated', () => {
      const project = service.createProject({ title: 'Proj' });
      emitSpy.mockClear();
      service.updateProject(project.id, { title: 'New' });
      expect(emitSpy).toHaveBeenCalledWith('project.updated', expect.objectContaining({ projectId: project.id }));
    });
  });
});
