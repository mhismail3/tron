/**
 * @fileoverview Tests for TaskManagerTool
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { DatabaseConnection } from '@infrastructure/events/sqlite/database.js';
import { runMigrations } from '@infrastructure/events/sqlite/migrations/index.js';
import { TaskRepository } from '../../../tasks/task-repository.js';
import { TaskService } from '../../../tasks/task-service.js';
import { TaskManagerTool } from '../task-manager.js';

describe('TaskManagerTool', () => {
  let connection: DatabaseConnection;
  let service: TaskService;
  let tool: TaskManagerTool;

  beforeEach(() => {
    connection = new DatabaseConnection(':memory:');
    const db = connection.open();
    runMigrations(db);
    // Create a workspace for FK compliance
    db.prepare("INSERT INTO workspaces (id, path, created_at, last_activity_at) VALUES (?, ?, ?, ?)")
      .run('ws_test', '/test', new Date().toISOString(), new Date().toISOString());
    const repo = new TaskRepository(connection);
    service = new TaskService(repo);
    tool = new TaskManagerTool({
      service,
      getSessionId: () => 'sess_test',
      getWorkspaceId: () => 'ws_test',
    });
  });

  afterEach(() => {
    connection.close();
  });

  describe('create', () => {
    it('creates a task', async () => {
      const result = await tool.execute({ action: 'create', title: 'Fix bug' });
      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('Created task');
      expect(result.content).toContain('Fix bug');
    });

    it('errors without title', async () => {
      const result = await tool.execute({ action: 'create' } as any);
      expect(result.isError).toBe(true);
      expect(result.content).toContain('title is required');
    });
  });

  describe('update', () => {
    it('updates task status', async () => {
      const created = service.createTask({ title: 'Test' });
      const result = await tool.execute({
        action: 'update',
        taskId: created.id,
        status: 'in_progress',
      });
      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('in_progress');
    });

    it('errors without taskId', async () => {
      const result = await tool.execute({ action: 'update', title: 'X' } as any);
      expect(result.isError).toBe(true);
    });

    it('handles dependencies', async () => {
      const a = service.createTask({ title: 'A' });
      const b = service.createTask({ title: 'B' });

      await tool.execute({
        action: 'update',
        taskId: b.id,
        addBlockedBy: [a.id],
      });

      const details = service.getTask(b.id)!;
      expect(details.blockedBy).toHaveLength(1);
    });
  });

  describe('get', () => {
    it('returns task details', async () => {
      const task = service.createTask({ title: 'Detailed task', description: 'Some description' });
      const result = await tool.execute({ action: 'get', taskId: task.id });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('Detailed task');
      expect(result.content).toContain('Some description');
    });

    it('errors for non-existent', async () => {
      const result = await tool.execute({ action: 'get', taskId: 'task_nope' });
      expect(result.isError).toBe(true);
    });
  });

  describe('list', () => {
    it('lists tasks', async () => {
      service.createTask({ title: 'Task A' });
      service.createTask({ title: 'Task B' });

      const result = await tool.execute({ action: 'list' });
      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('Task A');
      expect(result.content).toContain('Task B');
    });

    it('shows empty message', async () => {
      const result = await tool.execute({ action: 'list' });
      expect(result.content).toContain('No tasks found');
    });
  });

  describe('search', () => {
    it('searches tasks', async () => {
      service.createTask({ title: 'Fix authentication bug' });
      service.createTask({ title: 'Add logging' });

      const result = await tool.execute({ action: 'search', query: 'authentication' });
      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('authentication');
    });

    it('errors without query', async () => {
      const result = await tool.execute({ action: 'search' } as any);
      expect(result.isError).toBe(true);
    });
  });

  describe('log_time', () => {
    it('logs time on a task', async () => {
      const task = service.createTask({ title: 'Test' });
      const result = await tool.execute({
        action: 'log_time',
        taskId: task.id,
        minutes: 30,
        timeNote: 'Research',
      });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('30min');
    });

    it('errors without minutes', async () => {
      const task = service.createTask({ title: 'Test' });
      const result = await tool.execute({ action: 'log_time', taskId: task.id } as any);
      expect(result.isError).toBe(true);
    });
  });

  describe('delete', () => {
    it('deletes a task', async () => {
      const task = service.createTask({ title: 'To delete' });
      const result = await tool.execute({ action: 'delete', taskId: task.id });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('Deleted');
    });
  });

  describe('create_project', () => {
    it('creates a project', async () => {
      const result = await tool.execute({
        action: 'create_project',
        projectTitle: 'Auth Overhaul',
      });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('Auth Overhaul');
    });
  });

  describe('update_project', () => {
    it('updates a project', async () => {
      const project = service.createProject({ title: 'Test' });
      const result = await tool.execute({
        action: 'update_project',
        projectId: project.id,
        projectTitle: 'Renamed',
        projectStatus: 'completed',
      });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('Renamed');
    });
  });

  describe('list_projects', () => {
    it('lists projects', async () => {
      service.createProject({ title: 'Auth' });
      service.createProject({ title: 'Deploy' });

      const result = await tool.execute({ action: 'list_projects' });
      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('Auth');
      expect(result.content).toContain('Deploy');
    });
  });

  describe('error handling', () => {
    it('handles unknown action', async () => {
      const result = await tool.execute({ action: 'unknown' } as any);
      expect(result.isError).toBe(true);
      expect(result.content).toContain('Unknown action');
    });

    it('catches service errors gracefully', async () => {
      const result = await tool.execute({
        action: 'update',
        taskId: 'task_nonexistent',
        title: 'X',
      });
      expect(result.isError).toBe(true);
      expect(result.content).toContain('Task not found');
    });
  });
});
