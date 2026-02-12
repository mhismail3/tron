/**
 * @fileoverview Tests for TaskManagerTool
 *
 * Integration tests using real DB + migrations + TaskRepository + TaskService + TaskManagerTool.
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { DatabaseConnection } from '@infrastructure/events/sqlite/database.js';
import { runMigrations } from '@infrastructure/events/sqlite/migrations/index.js';
import { TaskRepository } from '../../../tasks/task-repository.js';
import { TaskService } from '../../../tasks/task-service.js';
import { TaskManagerTool } from '../task-manager.js';

describe('TaskManagerTool', () => {
  let connection: DatabaseConnection;
  let repo: TaskRepository;
  let service: TaskService;
  let tool: TaskManagerTool;

  beforeEach(() => {
    connection = new DatabaseConnection(':memory:');
    const db = connection.open();
    runMigrations(db);
    repo = new TaskRepository(connection);
    service = new TaskService(repo);
    tool = new TaskManagerTool({
      service,
      getSessionId: () => 'sess_test',
      getWorkspaceId: () => undefined,
    });
  });

  afterEach(() => {
    connection.close();
  });

  // =========================================================================
  // Area Actions
  // =========================================================================

  describe('create_area', () => {
    it('requires areaTitle', async () => {
      const result = await tool.execute({ action: 'create_area' } as any);
      expect(result.isError).toBe(true);
      expect(result.content).toContain('areaTitle is required');
    });

    it('creates area and returns confirmation', async () => {
      const result = await tool.execute({
        action: 'create_area',
        areaTitle: 'Security',
        areaDescription: 'Ongoing security',
      } as any);

      expect(result.isError).toBe(false);
      expect(result.content).toContain('Security');
      expect(result.content).toContain('area_');
    });
  });

  describe('update_area', () => {
    it('requires areaId', async () => {
      const result = await tool.execute({ action: 'update_area' } as any);
      expect(result.isError).toBe(true);
      expect(result.content).toContain('areaId is required');
    });

    it('updates area fields', async () => {
      const area = service.createArea({ title: 'Original' });
      const result = await tool.execute({
        action: 'update_area',
        areaId: area.id,
        areaTitle: 'Renamed',
        areaStatus: 'archived',
      } as any);

      expect(result.isError).toBe(false);
      expect(result.content).toContain('Renamed');
      expect(result.content).toContain('archived');
    });
  });

  describe('get_area', () => {
    it('requires areaId', async () => {
      const result = await tool.execute({ action: 'get_area' } as any);
      expect(result.isError).toBe(true);
      expect(result.content).toContain('areaId is required');
    });

    it('returns formatted area detail', async () => {
      const area = service.createArea({ title: 'Security', description: 'Security ops' });
      service.createProject({ title: 'Audit', areaId: area.id });
      service.createTask({ title: 'Check perms', areaId: area.id });

      const result = await tool.execute({ action: 'get_area', areaId: area.id } as any);

      expect(result.isError).toBe(false);
      expect(result.content).toContain('Security');
      expect(result.content).toContain('1 project');
      expect(result.content).toContain('1 task');
    });

    it('returns error for non-existent', async () => {
      const result = await tool.execute({ action: 'get_area', areaId: 'area_nope' } as any);
      expect(result.isError).toBe(true);
    });
  });

  describe('delete_area', () => {
    it('requires areaId', async () => {
      const result = await tool.execute({ action: 'delete_area' } as any);
      expect(result.isError).toBe(true);
    });

    it('deletes area and returns confirmation with name', async () => {
      const area = service.createArea({ title: 'To delete' });
      const result = await tool.execute({ action: 'delete_area', areaId: area.id } as any);

      expect(result.isError).toBe(false);
      expect(result.content).toContain('Deleted');
      expect(result.content).toContain('To delete');
    });

    it('returns error for non-existent', async () => {
      const result = await tool.execute({ action: 'delete_area', areaId: 'area_nope' } as any);
      expect(result.isError).toBe(true);
    });
  });

  describe('list_areas', () => {
    it('returns formatted list with counts', async () => {
      service.createArea({ title: 'Security' });
      service.createArea({ title: 'Quality' });

      const result = await tool.execute({ action: 'list_areas' } as any);

      expect(result.isError).toBe(false);
      expect(result.content).toContain('Areas (2)');
      expect(result.content).toContain('Security');
      expect(result.content).toContain('Quality');
    });

    it('returns "No areas found." when empty', async () => {
      const result = await tool.execute({ action: 'list_areas' } as any);

      expect(result.isError).toBe(false);
      expect(result.content).toBe('No areas found.');
    });

    it('filters by status', async () => {
      service.createArea({ title: 'Active' });
      const archived = service.createArea({ title: 'Archived' });
      service.updateArea(archived.id, { status: 'archived' });

      const result = await tool.execute({ action: 'list_areas', areaStatus: 'archived' } as any);

      expect(result.isError).toBe(false);
      expect(result.content).toContain('Archived');
      expect(result.content).not.toContain('Active');
    });
  });

  // =========================================================================
  // Project Get/Delete
  // =========================================================================

  describe('get_project', () => {
    it('requires projectId', async () => {
      const result = await tool.execute({ action: 'get_project' } as any);
      expect(result.isError).toBe(true);
      expect(result.content).toContain('projectId is required');
    });

    it('returns formatted project detail with tasks', async () => {
      const project = service.createProject({ title: 'Auth Overhaul' });
      service.createTask({ title: 'T1', projectId: project.id, status: 'completed' });
      service.createTask({ title: 'T2', projectId: project.id });

      const result = await tool.execute({ action: 'get_project', projectId: project.id } as any);

      expect(result.isError).toBe(false);
      expect(result.content).toContain('Auth Overhaul');
      expect(result.content).toContain('T1');
      expect(result.content).toContain('T2');
    });

    it('returns error for non-existent', async () => {
      const result = await tool.execute({ action: 'get_project', projectId: 'proj_nope' } as any);
      expect(result.isError).toBe(true);
    });
  });

  describe('delete_project', () => {
    it('requires projectId', async () => {
      const result = await tool.execute({ action: 'delete_project' } as any);
      expect(result.isError).toBe(true);
      expect(result.content).toContain('projectId is required');
    });

    it('deletes project and returns confirmation with name', async () => {
      const project = service.createProject({ title: 'To delete' });
      const result = await tool.execute({ action: 'delete_project', projectId: project.id } as any);

      expect(result.isError).toBe(false);
      expect(result.content).toContain('Deleted');
      expect(result.content).toContain('To delete');
    });

    it('returns error for non-existent', async () => {
      const result = await tool.execute({ action: 'delete_project', projectId: 'proj_nope' } as any);
      expect(result.isError).toBe(true);
    });
  });

  // =========================================================================
  // Existing Actions Still Work
  // =========================================================================

  describe('existing actions', () => {
    it('create still works', async () => {
      const result = await tool.execute({ action: 'create', title: 'Test task' });
      expect(result.isError).toBe(false);
      expect(result.content).toContain('Test task');
    });

    it('update still works', async () => {
      const task = service.createTask({ title: 'Test' });
      const result = await tool.execute({ action: 'update', taskId: task.id, status: 'completed' });
      expect(result.isError).toBe(false);
    });

    it('list still works', async () => {
      service.createTask({ title: 'A' });
      const result = await tool.execute({ action: 'list' });
      expect(result.isError).toBe(false);
      expect(result.content).toContain('A');
    });

    it('unknown action returns error', async () => {
      const result = await tool.execute({ action: 'invalid_action' as any });
      expect(result.isError).toBe(true);
      expect(result.content).toContain('Unknown action');
    });
  });
});
