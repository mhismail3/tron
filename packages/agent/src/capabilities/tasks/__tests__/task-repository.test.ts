/**
 * @fileoverview Tests for TaskRepository
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { DatabaseConnection } from '@infrastructure/events/sqlite/database.js';
import { runMigrations } from '@infrastructure/events/sqlite/migrations/index.js';
import { TaskRepository } from '../task-repository.js';

describe('TaskRepository', () => {
  let connection: DatabaseConnection;
  let repo: TaskRepository;

  beforeEach(() => {
    connection = new DatabaseConnection(':memory:');
    const db = connection.open();
    runMigrations(db);
    repo = new TaskRepository(connection);
  });

  afterEach(() => {
    connection.close();
  });

  // =========================================================================
  // Task CRUD
  // =========================================================================

  describe('createTask', () => {
    it('creates a task with defaults', () => {
      const task = repo.createTask({ title: 'Fix bug' });

      expect(task.id).toMatch(/^task_[a-f0-9]+$/);
      expect(task.title).toBe('Fix bug');
      expect(task.status).toBe('pending');
      expect(task.priority).toBe('medium');
      expect(task.source).toBe('agent');
      expect(task.tags).toEqual([]);
      expect(task.actualMinutes).toBe(0);
      expect(task.sortOrder).toBeGreaterThan(0);
    });

    it('creates a task with all params', () => {
      const task = repo.createTask({
        title: 'Deploy v2',
        description: 'Deploy the new version',
        activeForm: 'Deploying v2',
        status: 'in_progress',
        priority: 'high',
        source: 'user',
        tags: ['deploy', 'v2'],
        dueDate: '2026-03-01',
        deferredUntil: '2026-02-15',
        estimatedMinutes: 60,
        createdBySessionId: 'sess_abc',
        workspaceId: null,
      });

      expect(task.title).toBe('Deploy v2');
      expect(task.description).toBe('Deploy the new version');
      expect(task.activeForm).toBe('Deploying v2');
      expect(task.status).toBe('in_progress');
      expect(task.priority).toBe('high');
      expect(task.source).toBe('user');
      expect(task.tags).toEqual(['deploy', 'v2']);
      expect(task.dueDate).toBe('2026-03-01');
      expect(task.deferredUntil).toBe('2026-02-15');
      expect(task.estimatedMinutes).toBe(60);
      expect(task.createdBySessionId).toBe('sess_abc');
    });

    it('assigns sequential sort orders within same project', () => {
      const t1 = repo.createTask({ title: 'First' });
      const t2 = repo.createTask({ title: 'Second' });
      const t3 = repo.createTask({ title: 'Third' });

      expect(t2.sortOrder).toBeGreaterThan(t1.sortOrder);
      expect(t3.sortOrder).toBeGreaterThan(t2.sortOrder);
    });
  });

  describe('getTask', () => {
    it('returns undefined for non-existent ID', () => {
      expect(repo.getTask('task_nonexistent')).toBeUndefined();
    });

    it('returns full task by ID', () => {
      const created = repo.createTask({ title: 'Test' });
      const found = repo.getTask(created.id);

      expect(found).toBeDefined();
      expect(found!.id).toBe(created.id);
      expect(found!.title).toBe('Test');
    });
  });

  describe('updateTask', () => {
    it('updates scalar fields', () => {
      const task = repo.createTask({ title: 'Original' });
      const updated = repo.updateTask(task.id, { title: 'Updated', priority: 'high' });

      expect(updated!.title).toBe('Updated');
      expect(updated!.priority).toBe('high');
    });

    it('updates tags as JSON', () => {
      const task = repo.createTask({ title: 'Test' });
      const updated = repo.updateTask(task.id, { tags: ['a', 'b'] });

      expect(updated!.tags).toEqual(['a', 'b']);
    });

    it('returns undefined for non-existent task', () => {
      const result = repo.updateTask('task_nonexistent', { title: 'X' });
      expect(result).toBeUndefined();
    });
  });

  describe('deleteTask', () => {
    it('deletes an existing task', () => {
      const task = repo.createTask({ title: 'To delete' });
      expect(repo.deleteTask(task.id)).toBe(true);
      expect(repo.getTask(task.id)).toBeUndefined();
    });

    it('returns false for non-existent task', () => {
      expect(repo.deleteTask('task_nonexistent')).toBe(false);
    });

    it('cascades to subtasks', () => {
      const parent = repo.createTask({ title: 'Parent' });
      const child = repo.createTask({ title: 'Child', parentTaskId: parent.id });

      repo.deleteTask(parent.id);
      expect(repo.getTask(child.id)).toBeUndefined();
    });
  });

  describe('incrementActualMinutes', () => {
    it('atomically increments actual_minutes', () => {
      const task = repo.createTask({ title: 'Time test' });
      repo.incrementActualMinutes(task.id, 30);
      repo.incrementActualMinutes(task.id, 15);

      const updated = repo.getTask(task.id)!;
      expect(updated.actualMinutes).toBe(45);
    });
  });

  // =========================================================================
  // Task Queries
  // =========================================================================

  describe('listTasks', () => {
    it('returns empty list for no tasks', () => {
      const result = repo.listTasks();
      expect(result.tasks).toEqual([]);
      expect(result.total).toBe(0);
    });

    it('excludes completed and cancelled by default', () => {
      repo.createTask({ title: 'Pending', status: 'pending' });
      repo.createTask({ title: 'Done', status: 'completed' });
      repo.createTask({ title: 'Cancelled', status: 'cancelled' });

      const result = repo.listTasks();
      expect(result.tasks).toHaveLength(1);
      expect(result.tasks[0].title).toBe('Pending');
    });

    it('excludes backlog by default', () => {
      repo.createTask({ title: 'Active', status: 'pending' });
      repo.createTask({ title: 'Backlogged', status: 'backlog' });

      const result = repo.listTasks();
      expect(result.tasks).toHaveLength(1);
      expect(result.tasks[0].title).toBe('Active');
    });

    it('includes completed when filter set', () => {
      repo.createTask({ title: 'Done', status: 'completed' });

      const result = repo.listTasks({ includeCompleted: true });
      expect(result.tasks).toHaveLength(1);
    });

    it('filters by status', () => {
      repo.createTask({ title: 'A', status: 'pending' });
      repo.createTask({ title: 'B', status: 'in_progress' });

      const result = repo.listTasks({ status: 'in_progress' });
      expect(result.tasks).toHaveLength(1);
      expect(result.tasks[0].title).toBe('B');
    });

    it('filters by multiple statuses', () => {
      repo.createTask({ title: 'A', status: 'pending' });
      repo.createTask({ title: 'B', status: 'in_progress' });
      repo.createTask({ title: 'C', status: 'completed' });

      const result = repo.listTasks({ status: ['pending', 'in_progress'] });
      expect(result.tasks).toHaveLength(2);
    });

    it('filters by priority', () => {
      repo.createTask({ title: 'Low', priority: 'low' });
      repo.createTask({ title: 'High', priority: 'high' });

      const result = repo.listTasks({ priority: 'high' });
      expect(result.tasks).toHaveLength(1);
      expect(result.tasks[0].title).toBe('High');
    });

    it('filters by tags', () => {
      repo.createTask({ title: 'Tagged', tags: ['deploy', 'v2'] });
      repo.createTask({ title: 'Untagged' });

      const result = repo.listTasks({ tags: ['deploy'] });
      expect(result.tasks).toHaveLength(1);
      expect(result.tasks[0].title).toBe('Tagged');
    });

    it('filters by projectId', () => {
      const project = repo.createProject({ title: 'Proj' });
      repo.createTask({ title: 'In project', projectId: project.id });
      repo.createTask({ title: 'No project' });

      const result = repo.listTasks({ projectId: project.id });
      expect(result.tasks).toHaveLength(1);
      expect(result.tasks[0].title).toBe('In project');
    });

    it('filters by parentTaskId null (top-level only)', () => {
      const parent = repo.createTask({ title: 'Parent' });
      repo.createTask({ title: 'Child', parentTaskId: parent.id });

      const result = repo.listTasks({ parentTaskId: null });
      expect(result.tasks).toHaveLength(1);
      expect(result.tasks[0].title).toBe('Parent');
    });

    it('respects limit and offset', () => {
      for (let i = 0; i < 10; i++) {
        repo.createTask({ title: `Task ${i}` });
      }

      const page1 = repo.listTasks({}, 3, 0);
      expect(page1.tasks).toHaveLength(3);
      expect(page1.total).toBe(10);

      const page2 = repo.listTasks({}, 3, 3);
      expect(page2.tasks).toHaveLength(3);
    });

    it('orders by priority then updated_at', () => {
      repo.createTask({ title: 'Low', priority: 'low' });
      repo.createTask({ title: 'Critical', priority: 'critical' });
      repo.createTask({ title: 'Medium', priority: 'medium' });

      const result = repo.listTasks();
      expect(result.tasks[0].title).toBe('Critical');
      expect(result.tasks[2].title).toBe('Low');
    });
  });

  describe('getSubtasks', () => {
    it('returns subtasks in sort order', () => {
      const parent = repo.createTask({ title: 'Parent' });
      repo.createTask({ title: 'Sub A', parentTaskId: parent.id });
      repo.createTask({ title: 'Sub B', parentTaskId: parent.id });

      const subtasks = repo.getSubtasks(parent.id);
      expect(subtasks).toHaveLength(2);
      expect(subtasks[0].title).toBe('Sub A');
      expect(subtasks[1].title).toBe('Sub B');
    });
  });

  describe('searchTasks', () => {
    it('finds tasks by title', () => {
      repo.createTask({ title: 'Fix authentication token refresh' });
      repo.createTask({ title: 'Add logging' });

      const results = repo.searchTasks('authentication');
      expect(results).toHaveLength(1);
      expect(results[0].title).toContain('authentication');
    });

    it('finds tasks by description', () => {
      repo.createTask({ title: 'Bug fix', description: 'The webhook endpoint fails silently' });

      const results = repo.searchTasks('webhook');
      expect(results).toHaveLength(1);
    });

    it('returns empty for no matches', () => {
      repo.createTask({ title: 'Something else' });
      const results = repo.searchTasks('nonexistent term xyz');
      expect(results).toHaveLength(0);
    });
  });

  // =========================================================================
  // Project CRUD
  // =========================================================================

  describe('createProject', () => {
    it('creates a project with defaults', () => {
      const project = repo.createProject({ title: 'Auth Overhaul' });

      expect(project.id).toMatch(/^proj_[a-f0-9]+$/);
      expect(project.title).toBe('Auth Overhaul');
      expect(project.status).toBe('active');
      expect(project.tags).toEqual([]);
    });

    it('creates with all params', () => {
      const project = repo.createProject({
        title: 'Deploy',
        description: 'Deploy v2',
        tags: ['infra'],
      });

      expect(project.description).toBe('Deploy v2');
      expect(project.tags).toEqual(['infra']);
    });
  });

  describe('updateProject', () => {
    it('updates project fields', () => {
      const project = repo.createProject({ title: 'Original' });
      const updated = repo.updateProject(project.id, { title: 'Renamed', status: 'paused' });

      expect(updated!.title).toBe('Renamed');
      expect(updated!.status).toBe('paused');
    });
  });

  describe('listProjects', () => {
    it('returns projects with task progress', () => {
      const project = repo.createProject({ title: 'Auth' });
      repo.createTask({ title: 'Task 1', projectId: project.id });
      repo.createTask({ title: 'Task 2', projectId: project.id, status: 'completed' });

      const result = repo.listProjects();
      expect(result.projects).toHaveLength(1);
      expect(result.projects[0].taskCount).toBe(2);
      expect(result.projects[0].completedTaskCount).toBe(1);
    });

    it('filters by status', () => {
      repo.createProject({ title: 'Active' });
      const archived = repo.createProject({ title: 'Archived' });
      repo.updateProject(archived.id, { status: 'archived' });

      const result = repo.listProjects({ status: 'active' });
      expect(result.projects).toHaveLength(1);
      expect(result.projects[0].title).toBe('Active');
    });
  });

  // =========================================================================
  // Dependencies
  // =========================================================================

  describe('addDependency / getBlockedBy / getBlocks', () => {
    it('creates a blocking dependency', () => {
      const a = repo.createTask({ title: 'A' });
      const b = repo.createTask({ title: 'B' });

      repo.addDependency(a.id, b.id);

      const blockedBy = repo.getBlockedBy(b.id);
      expect(blockedBy).toHaveLength(1);
      expect(blockedBy[0].blockerTaskId).toBe(a.id);

      const blocks = repo.getBlocks(a.id);
      expect(blocks).toHaveLength(1);
      expect(blocks[0].blockedTaskId).toBe(b.id);
    });

    it('ignores duplicate dependencies', () => {
      const a = repo.createTask({ title: 'A' });
      const b = repo.createTask({ title: 'B' });

      repo.addDependency(a.id, b.id);
      repo.addDependency(a.id, b.id); // duplicate

      const blockedBy = repo.getBlockedBy(b.id);
      expect(blockedBy).toHaveLength(1);
    });
  });

  describe('removeDependency', () => {
    it('removes an existing dependency', () => {
      const a = repo.createTask({ title: 'A' });
      const b = repo.createTask({ title: 'B' });
      repo.addDependency(a.id, b.id);

      expect(repo.removeDependency(a.id, b.id)).toBe(true);
      expect(repo.getBlockedBy(b.id)).toHaveLength(0);
    });

    it('returns false for non-existent', () => {
      expect(repo.removeDependency('task_x', 'task_y')).toBe(false);
    });
  });

  describe('hasCircularDependency', () => {
    it('detects direct cycle A→B→A', () => {
      const a = repo.createTask({ title: 'A' });
      const b = repo.createTask({ title: 'B' });
      repo.addDependency(a.id, b.id);

      expect(repo.hasCircularDependency(b.id, a.id)).toBe(true);
    });

    it('detects transitive cycle A→B→C→A', () => {
      const a = repo.createTask({ title: 'A' });
      const b = repo.createTask({ title: 'B' });
      const c = repo.createTask({ title: 'C' });
      repo.addDependency(a.id, b.id);
      repo.addDependency(b.id, c.id);

      expect(repo.hasCircularDependency(c.id, a.id)).toBe(true);
    });

    it('allows non-circular dependency', () => {
      const a = repo.createTask({ title: 'A' });
      const b = repo.createTask({ title: 'B' });
      const c = repo.createTask({ title: 'C' });
      repo.addDependency(a.id, b.id);

      expect(repo.hasCircularDependency(c.id, a.id)).toBe(false);
    });
  });

  describe('getBlockedTaskCount', () => {
    it('counts tasks blocked by incomplete blockers', () => {
      const a = repo.createTask({ title: 'Blocker' });
      const b = repo.createTask({ title: 'Blocked' });
      repo.addDependency(a.id, b.id);

      expect(repo.getBlockedTaskCount()).toBe(1);
    });

    it('does not count tasks blocked by completed blocker', () => {
      const a = repo.createTask({ title: 'Blocker', status: 'completed' });
      const b = repo.createTask({ title: 'Blocked' });
      repo.addDependency(a.id, b.id);

      expect(repo.getBlockedTaskCount()).toBe(0);
    });
  });

  // =========================================================================
  // Activity
  // =========================================================================

  describe('logActivity / getActivity', () => {
    it('logs and retrieves activity', () => {
      const task = repo.createTask({ title: 'Test' });
      repo.logActivity({
        taskId: task.id,
        action: 'created',
        detail: 'Created task',
      });

      const activity = repo.getActivity(task.id);
      expect(activity).toHaveLength(1);
      expect(activity[0].action).toBe('created');
      expect(activity[0].detail).toBe('Created task');
    });

    it('returns activity in reverse chronological order', () => {
      const task = repo.createTask({ title: 'Test' });
      repo.logActivity({ taskId: task.id, action: 'created', detail: 'First' });
      repo.logActivity({ taskId: task.id, action: 'updated', detail: 'Second' });

      const activity = repo.getActivity(task.id);
      expect(activity[0].detail).toBe('Second');
      expect(activity[1].detail).toBe('First');
    });

    it('cascades deletion with task', () => {
      const task = repo.createTask({ title: 'Test' });
      repo.logActivity({ taskId: task.id, action: 'created' });
      repo.deleteTask(task.id);

      // Activity for deleted task should be gone
      const activity = repo.getActivity(task.id);
      expect(activity).toHaveLength(0);
    });
  });

  // =========================================================================
  // Context Summary
  // =========================================================================

  describe('getActiveTaskSummary', () => {
    it('returns correct counts', () => {
      repo.createTask({ title: 'WIP', status: 'in_progress' });
      repo.createTask({ title: 'Todo 1', status: 'pending' });
      repo.createTask({ title: 'Todo 2', status: 'pending' });
      repo.createTask({ title: 'Done', status: 'completed' });

      const summary = repo.getActiveTaskSummary();
      expect(summary.inProgress).toHaveLength(1);
      expect(summary.pendingCount).toBe(2);
    });

    it('counts overdue tasks', () => {
      repo.createTask({ title: 'Overdue', dueDate: '2020-01-01' });
      repo.createTask({ title: 'Future', dueDate: '2030-01-01' });

      const summary = repo.getActiveTaskSummary();
      expect(summary.overdueCount).toBe(1);
    });
  });

  describe('getActiveProjectProgress', () => {
    it('returns project progress', () => {
      const project = repo.createProject({ title: 'Auth' });
      repo.createTask({ title: 'T1', projectId: project.id, status: 'completed' });
      repo.createTask({ title: 'T2', projectId: project.id });
      repo.createTask({ title: 'T3', projectId: project.id });

      const progress = repo.getActiveProjectProgress();
      expect(progress).toHaveLength(1);
      expect(progress[0].title).toBe('Auth');
      expect(progress[0].done).toBe(1);
      expect(progress[0].total).toBe(3);
    });
  });

  // =========================================================================
  // Area CRUD
  // =========================================================================

  describe('createArea', () => {
    it('creates area with defaults', () => {
      const area = repo.createArea({ title: 'Code Quality' });

      expect(area.id).toMatch(/^area_[a-f0-9]+$/);
      expect(area.title).toBe('Code Quality');
      expect(area.status).toBe('active');
      expect(area.tags).toEqual([]);
      expect(area.workspaceId).toBe('default');
      expect(area.metadata).toEqual({});
    });

    it('creates area with all params', () => {
      const area = repo.createArea({
        title: 'Security',
        description: 'Ongoing security maintenance',
        tags: ['security', 'compliance'],
        workspaceId: 'ws_1',
        metadata: { priority: 'high' },
      });

      expect(area.title).toBe('Security');
      expect(area.description).toBe('Ongoing security maintenance');
      expect(area.tags).toEqual(['security', 'compliance']);
      expect(area.workspaceId).toBe('ws_1');
      expect(area.metadata).toEqual({ priority: 'high' });
    });

    it('assigns sequential sort orders', () => {
      const a1 = repo.createArea({ title: 'First' });
      const a2 = repo.createArea({ title: 'Second' });
      const a3 = repo.createArea({ title: 'Third' });

      expect(a2.sortOrder).toBeGreaterThan(a1.sortOrder);
      expect(a3.sortOrder).toBeGreaterThan(a2.sortOrder);
    });
  });

  describe('getArea', () => {
    it('returns undefined for non-existent ID', () => {
      expect(repo.getArea('area_nonexistent')).toBeUndefined();
    });

    it('returns full area by ID', () => {
      const created = repo.createArea({ title: 'Test Area' });
      const found = repo.getArea(created.id);

      expect(found).toBeDefined();
      expect(found!.id).toBe(created.id);
      expect(found!.title).toBe('Test Area');
    });
  });

  describe('updateArea', () => {
    it('updates scalar fields', () => {
      const area = repo.createArea({ title: 'Original' });
      const updated = repo.updateArea(area.id, { title: 'Renamed', description: 'New desc' });

      expect(updated!.title).toBe('Renamed');
      expect(updated!.description).toBe('New desc');
    });

    it('updates tags as JSON', () => {
      const area = repo.createArea({ title: 'Test' });
      const updated = repo.updateArea(area.id, { tags: ['a', 'b'] });

      expect(updated!.tags).toEqual(['a', 'b']);
    });

    it('updates metadata', () => {
      const area = repo.createArea({ title: 'Test' });
      const updated = repo.updateArea(area.id, { metadata: { key: 'value' } });

      expect(updated!.metadata).toEqual({ key: 'value' });
    });

    it('returns undefined for non-existent area', () => {
      expect(repo.updateArea('area_nope', { title: 'X' })).toBeUndefined();
    });
  });

  describe('deleteArea', () => {
    it('deletes an existing area and returns true', () => {
      const area = repo.createArea({ title: 'To delete' });
      expect(repo.deleteArea(area.id)).toBe(true);
      expect(repo.getArea(area.id)).toBeUndefined();
    });

    it('returns false for non-existent', () => {
      expect(repo.deleteArea('area_nope')).toBe(false);
    });

    it('cascades: sets area_id=NULL on linked projects', () => {
      const area = repo.createArea({ title: 'Area' });
      const project = repo.createProject({ title: 'Proj', areaId: area.id });

      repo.deleteArea(area.id);

      const updated = repo.getProject(project.id);
      expect(updated!.areaId).toBeNull();
    });

    it('cascades: sets area_id=NULL on linked tasks', () => {
      const area = repo.createArea({ title: 'Area' });
      const task = repo.createTask({ title: 'Task', areaId: area.id });

      repo.deleteArea(area.id);

      const updated = repo.getTask(task.id);
      expect(updated!.areaId).toBeNull();
    });
  });

  describe('listAreas', () => {
    it('returns empty list when no areas exist', () => {
      const result = repo.listAreas();
      expect(result.areas).toEqual([]);
      expect(result.total).toBe(0);
    });

    it('returns areas with project/task/activeTask counts', () => {
      const area = repo.createArea({ title: 'Code Quality' });
      repo.createProject({ title: 'Proj', areaId: area.id });
      repo.createTask({ title: 'T1', areaId: area.id, status: 'pending' });
      repo.createTask({ title: 'T2', areaId: area.id, status: 'completed' });

      const result = repo.listAreas();
      expect(result.areas).toHaveLength(1);
      expect(result.areas[0].projectCount).toBe(1);
      expect(result.areas[0].taskCount).toBe(2);
      expect(result.areas[0].activeTaskCount).toBe(1);
    });

    it('filters by status', () => {
      repo.createArea({ title: 'Active' });
      const archived = repo.createArea({ title: 'Archived' });
      repo.updateArea(archived.id, { status: 'archived' });

      const result = repo.listAreas({ status: 'active' });
      expect(result.areas).toHaveLength(1);
      expect(result.areas[0].title).toBe('Active');
    });

    it('filters by workspaceId', () => {
      repo.createArea({ title: 'Default' });
      repo.createArea({ title: 'Custom', workspaceId: 'ws_1' });

      const result = repo.listAreas({ workspaceId: 'ws_1' });
      expect(result.areas).toHaveLength(1);
      expect(result.areas[0].title).toBe('Custom');
    });

    it('respects limit and offset', () => {
      for (let i = 0; i < 5; i++) {
        repo.createArea({ title: `Area ${i}` });
      }

      const page1 = repo.listAreas({}, 2, 0);
      expect(page1.areas).toHaveLength(2);
      expect(page1.total).toBe(5);

      const page2 = repo.listAreas({}, 2, 2);
      expect(page2.areas).toHaveLength(2);
    });
  });

  describe('searchAreas', () => {
    it('finds areas by title', () => {
      repo.createArea({ title: 'Security compliance monitoring' });
      repo.createArea({ title: 'Code quality' });

      const results = repo.searchAreas('security');
      expect(results).toHaveLength(1);
      expect(results[0].title).toContain('Security');
    });

    it('finds areas by description', () => {
      repo.createArea({ title: 'Ops', description: 'Infrastructure reliability monitoring' });

      const results = repo.searchAreas('infrastructure');
      expect(results).toHaveLength(1);
    });

    it('returns empty for no matches', () => {
      repo.createArea({ title: 'Something' });
      const results = repo.searchAreas('nonexistent xyz');
      expect(results).toHaveLength(0);
    });
  });

  // =========================================================================
  // Project deleteProject
  // =========================================================================

  describe('deleteProject', () => {
    it('deletes project and returns true', () => {
      const project = repo.createProject({ title: 'To delete' });
      expect(repo.deleteProject(project.id)).toBe(true);
      expect(repo.getProject(project.id)).toBeUndefined();
    });

    it('returns false for non-existent', () => {
      expect(repo.deleteProject('proj_nope')).toBe(false);
    });

    it('orphans tasks: sets project_id=NULL on linked tasks', () => {
      const project = repo.createProject({ title: 'Proj' });
      const task = repo.createTask({ title: 'Task', projectId: project.id });

      repo.deleteProject(project.id);

      const updated = repo.getTask(task.id);
      expect(updated).toBeDefined();
      expect(updated!.projectId).toBeNull();
    });
  });

  // =========================================================================
  // area_id on Projects
  // =========================================================================

  describe('area_id on projects', () => {
    it('createProject with areaId stores correctly', () => {
      const area = repo.createArea({ title: 'Area' });
      const project = repo.createProject({ title: 'Proj', areaId: area.id });

      expect(project.areaId).toBe(area.id);
    });

    it('updateProject can set areaId', () => {
      const area = repo.createArea({ title: 'Area' });
      const project = repo.createProject({ title: 'Proj' });

      const updated = repo.updateProject(project.id, { areaId: area.id });
      expect(updated!.areaId).toBe(area.id);
    });

    it('updateProject can clear areaId', () => {
      const area = repo.createArea({ title: 'Area' });
      const project = repo.createProject({ title: 'Proj', areaId: area.id });

      const updated = repo.updateProject(project.id, { areaId: null });
      expect(updated!.areaId).toBeNull();
    });

    it('listProjects filters by areaId', () => {
      const area = repo.createArea({ title: 'Area' });
      repo.createProject({ title: 'In area', areaId: area.id });
      repo.createProject({ title: 'No area' });

      const result = repo.listProjects({ areaId: area.id });
      expect(result.projects).toHaveLength(1);
      expect(result.projects[0].title).toBe('In area');
    });

    it('getProject returns areaId', () => {
      const area = repo.createArea({ title: 'Area' });
      const project = repo.createProject({ title: 'Proj', areaId: area.id });

      const found = repo.getProject(project.id);
      expect(found!.areaId).toBe(area.id);
    });
  });

  // =========================================================================
  // area_id on Tasks
  // =========================================================================

  describe('area_id on tasks', () => {
    it('createTask with areaId stores correctly', () => {
      const area = repo.createArea({ title: 'Area' });
      const task = repo.createTask({ title: 'Task', areaId: area.id });

      expect(task.areaId).toBe(area.id);
    });

    it('updateTask can set areaId', () => {
      const area = repo.createArea({ title: 'Area' });
      const task = repo.createTask({ title: 'Task' });

      const updated = repo.updateTask(task.id, { areaId: area.id });
      expect(updated!.areaId).toBe(area.id);
    });

    it('updateTask can clear areaId', () => {
      const area = repo.createArea({ title: 'Area' });
      const task = repo.createTask({ title: 'Task', areaId: area.id });

      const updated = repo.updateTask(task.id, { areaId: null });
      expect(updated!.areaId).toBeNull();
    });

    it('listTasks filters by areaId', () => {
      const area = repo.createArea({ title: 'Area' });
      repo.createTask({ title: 'In area', areaId: area.id });
      repo.createTask({ title: 'No area' });

      const result = repo.listTasks({ areaId: area.id });
      expect(result.tasks).toHaveLength(1);
      expect(result.tasks[0].title).toBe('In area');
    });
  });
});
