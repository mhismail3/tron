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
  // Rich Entity Snapshots — Tasks
  // =========================================================================

  describe('create returns rich task snapshot', () => {
    it('includes action line and entity header', async () => {
      const result = await tool.execute({ action: 'create', title: 'Fix login bug' });
      expect(result.isError).toBe(false);
      expect(result.content).toMatch(/^Created task task_\w+: Fix login bug \[pending\]/);
      expect(result.content).toContain('# Fix login bug');
      expect(result.content).toMatch(/ID: task_\w+ \| Status: pending \| Priority: medium/);
    });

    it('includes source and timestamps', async () => {
      const result = await tool.execute({ action: 'create', title: 'Test task' });
      expect(result.content).toContain('Source: agent');
      expect(result.content).toContain('Created:');
      expect(result.content).toContain('Updated:');
    });

    it('includes optional fields when provided', async () => {
      const area = service.createArea({ title: 'Security' });
      const project = service.createProject({ title: 'Auth Refactor', areaId: area.id });

      const result = await tool.execute({
        action: 'create',
        title: 'Add 2FA',
        description: 'Implement two-factor auth',
        priority: 'high',
        addTags: ['security', 'auth'],
        dueDate: '2026-03-01',
        estimatedMinutes: 120,
        projectId: project.id,
        areaId: area.id,
      });

      expect(result.content).toContain('Priority: high');
      expect(result.content).toContain('Implement two-factor auth');
      expect(result.content).toContain('Tags: security, auth');
      expect(result.content).toContain('Due: 2026-03-01');
      expect(result.content).toContain('Auth Refactor');
      expect(result.content).toContain('Security');
    });
  });

  describe('update returns rich task snapshot', () => {
    it('includes action line and updated entity', async () => {
      const task = service.createTask({ title: 'Fix bug' });
      const result = await tool.execute({
        action: 'update',
        taskId: task.id,
        status: 'in_progress',
        priority: 'high',
      });

      expect(result.isError).toBe(false);
      expect(result.content).toMatch(/^Updated task task_\w+: Fix bug \[in_progress\]/);
      expect(result.content).toContain('# Fix bug');
      expect(result.content).toContain('Status: in_progress');
      expect(result.content).toContain('Priority: high');
    });

    it('includes dependencies after update', async () => {
      const taskA = service.createTask({ title: 'Task A' });
      const taskB = service.createTask({ title: 'Task B' });
      const result = await tool.execute({
        action: 'update',
        taskId: taskA.id,
        addBlocks: [taskB.id],
      });

      expect(result.content).toContain('Blocks:');
      expect(result.content).toContain(taskB.id);
    });
  });

  describe('delete returns rich task snapshot', () => {
    it('includes action line and pre-deletion snapshot', async () => {
      const task = service.createTask({
        title: 'Obsolete task',
        description: 'No longer needed',
        priority: 'low',
      });

      const result = await tool.execute({ action: 'delete', taskId: task.id });

      expect(result.isError).toBe(false);
      expect(result.content).toMatch(/^Deleted task task_\w+: Obsolete task/);
      expect(result.content).toContain('# Obsolete task');
      expect(result.content).toContain('Priority: low');
      expect(result.content).toContain('No longer needed');
    });
  });

  describe('get returns rich task snapshot', () => {
    it('returns formatted detail with all metadata', async () => {
      const area = service.createArea({ title: 'Backend' });
      const project = service.createProject({ title: 'API Rewrite', areaId: area.id });
      const task = service.createTask({
        title: 'Migrate endpoints',
        description: 'Move all v1 endpoints to v2',
        priority: 'high',
        tags: ['api', 'migration'],
        dueDate: '2026-04-01',
        estimatedMinutes: 480,
        projectId: project.id,
        areaId: area.id,
      });

      const result = await tool.execute({ action: 'get', taskId: task.id });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('# Migrate endpoints');
      expect(result.content).toContain('Status: pending');
      expect(result.content).toContain('Priority: high');
      expect(result.content).toContain('Move all v1 endpoints to v2');
      expect(result.content).toContain('Tags: api, migration');
      expect(result.content).toContain('Due: 2026-04-01');
      expect(result.content).toContain('API Rewrite');
      expect(result.content).toContain(project.id);
      expect(result.content).toContain('Backend');
      expect(result.content).toContain(area.id);
      expect(result.content).toContain('Source: agent');
      expect(result.content).toContain('Created:');
      expect(result.content).toContain('Updated:');
    });

    it('includes subtasks with status marks', async () => {
      const parent = service.createTask({ title: 'Parent' });
      service.createTask({ title: 'Sub 1', parentTaskId: parent.id, status: 'completed' });
      service.createTask({ title: 'Sub 2', parentTaskId: parent.id, status: 'in_progress' });
      service.createTask({ title: 'Sub 3', parentTaskId: parent.id });

      const result = await tool.execute({ action: 'get', taskId: parent.id });

      expect(result.content).toContain('Subtasks (3)');
      expect(result.content).toContain('[x]');
      expect(result.content).toContain('[>]');
      expect(result.content).toContain('[ ]');
    });
  });

  describe('log_time returns rich task snapshot', () => {
    it('includes action line and updated entity', async () => {
      const task = service.createTask({ title: 'Review PR', estimatedMinutes: 30 });
      const result = await tool.execute({
        action: 'log_time',
        taskId: task.id,
        minutes: 15,
        timeNote: 'Initial review',
      });

      expect(result.isError).toBe(false);
      expect(result.content).toMatch(/^Logged 15min on task_\w+/);
      expect(result.content).toContain('# Review PR');
      expect(result.content).toContain('15/30min');
    });
  });

  // =========================================================================
  // Rich Entity Snapshots — Projects
  // =========================================================================

  describe('create_project returns rich project snapshot', () => {
    it('includes action line and entity header', async () => {
      const result = await tool.execute({
        action: 'create_project',
        projectTitle: 'Auth Refactor',
        projectDescription: 'Rewrite auth system',
      } as any);

      expect(result.isError).toBe(false);
      expect(result.content).toMatch(/^Created project proj_\w+: Auth Refactor/);
      expect(result.content).toContain('# Auth Refactor');
      expect(result.content).toContain('Status: active');
      expect(result.content).toContain('Rewrite auth system');
      expect(result.content).toContain('Created:');
    });
  });

  describe('update_project returns rich project snapshot', () => {
    it('includes action line and updated entity', async () => {
      const project = service.createProject({ title: 'My Project' });
      service.createTask({ title: 'Task 1', projectId: project.id, status: 'completed' });
      service.createTask({ title: 'Task 2', projectId: project.id, priority: 'high' });

      const result = await tool.execute({
        action: 'update_project',
        projectId: project.id,
        projectStatus: 'paused',
      } as any);

      expect(result.isError).toBe(false);
      expect(result.content).toMatch(/^Updated project proj_\w+: My Project \[paused\]/);
      expect(result.content).toContain('# My Project');
      expect(result.content).toContain('Status: paused');
      expect(result.content).toContain('Task 1');
      expect(result.content).toContain('[high]');
    });
  });

  describe('delete_project returns rich project snapshot', () => {
    it('includes action line and pre-deletion snapshot', async () => {
      const project = service.createProject({
        title: 'To Delete',
        description: 'Will be removed',
      });

      const result = await tool.execute({
        action: 'delete_project',
        projectId: project.id,
      } as any);

      expect(result.isError).toBe(false);
      expect(result.content).toMatch(/^Deleted project proj_\w+: To Delete/);
      expect(result.content).toContain('# To Delete');
      expect(result.content).toContain('Will be removed');
    });
  });

  describe('get_project returns rich project snapshot', () => {
    it('returns formatted detail with tasks and priority', async () => {
      const area = service.createArea({ title: 'Engineering' });
      const project = service.createProject({
        title: 'Auth Overhaul',
        tags: ['security'],
        areaId: area.id,
      });
      service.createTask({ title: 'T1', projectId: project.id, status: 'completed' });
      service.createTask({ title: 'T2', projectId: project.id, priority: 'high' });

      const result = await tool.execute({ action: 'get_project', projectId: project.id } as any);

      expect(result.isError).toBe(false);
      expect(result.content).toContain('# Auth Overhaul');
      expect(result.content).toContain('1/2 tasks');
      expect(result.content).toContain('[x]');
      expect(result.content).toContain('[high]');
      expect(result.content).toContain('Tags: security');
      expect(result.content).toContain('Engineering');
      expect(result.content).toContain('Created:');
      expect(result.content).toContain('Updated:');
    });
  });

  // =========================================================================
  // Rich Entity Snapshots — Areas
  // =========================================================================

  describe('create_area returns rich area snapshot', () => {
    it('includes action line and entity header', async () => {
      const result = await tool.execute({
        action: 'create_area',
        areaTitle: 'Security',
        areaDescription: 'Ongoing security work',
        areaTags: ['infra'],
      } as any);

      expect(result.isError).toBe(false);
      expect(result.content).toMatch(/^Created area area_\w+: Security \[active\]/);
      expect(result.content).toContain('# Security');
      expect(result.content).toContain('Status: active');
      expect(result.content).toContain('Ongoing security work');
      expect(result.content).toContain('Tags: infra');
      expect(result.content).toContain('Created:');
    });
  });

  describe('update_area returns rich area snapshot', () => {
    it('includes action line and updated entity', async () => {
      const area = service.createArea({ title: 'Original' });
      service.createProject({ title: 'P1', areaId: area.id });
      service.createTask({ title: 'T1', areaId: area.id });

      const result = await tool.execute({
        action: 'update_area',
        areaId: area.id,
        areaTitle: 'Renamed',
        areaStatus: 'archived',
      } as any);

      expect(result.isError).toBe(false);
      expect(result.content).toMatch(/^Updated area area_\w+: Renamed \[archived\]/);
      expect(result.content).toContain('# Renamed');
      expect(result.content).toContain('Status: archived');
      expect(result.content).toContain('1 project');
      expect(result.content).toContain('1 task');
    });
  });

  describe('delete_area returns rich area snapshot', () => {
    it('includes action line and pre-deletion snapshot', async () => {
      const area = service.createArea({
        title: 'To delete',
        description: 'Removing this area',
      });

      const result = await tool.execute({ action: 'delete_area', areaId: area.id } as any);

      expect(result.isError).toBe(false);
      expect(result.content).toMatch(/^Deleted area area_\w+: To delete/);
      expect(result.content).toContain('# To delete');
      expect(result.content).toContain('Removing this area');
    });
  });

  describe('get_area returns rich area snapshot', () => {
    it('returns formatted area detail with counts and timestamps', async () => {
      const area = service.createArea({ title: 'Security', description: 'Security ops' });
      service.createProject({ title: 'Audit', areaId: area.id });
      service.createTask({ title: 'Check perms', areaId: area.id });

      const result = await tool.execute({ action: 'get_area', areaId: area.id } as any);

      expect(result.isError).toBe(false);
      expect(result.content).toContain('# Security');
      expect(result.content).toContain('1 project');
      expect(result.content).toContain('1 task');
      expect(result.content).toContain('Security ops');
      expect(result.content).toContain('Created:');
      expect(result.content).toContain('Updated:');
    });

    it('returns error for non-existent', async () => {
      const result = await tool.execute({ action: 'get_area', areaId: 'area_nope' } as any);
      expect(result.isError).toBe(true);
    });
  });

  // =========================================================================
  // Error Cases
  // =========================================================================

  describe('error cases', () => {
    it('create requires title', async () => {
      const result = await tool.execute({ action: 'create' });
      expect(result.isError).toBe(true);
      expect(result.content).toContain('title is required');
    });

    it('update requires taskId', async () => {
      const result = await tool.execute({ action: 'update' });
      expect(result.isError).toBe(true);
    });

    it('get requires taskId', async () => {
      const result = await tool.execute({ action: 'get' });
      expect(result.isError).toBe(true);
    });

    it('delete requires taskId', async () => {
      const result = await tool.execute({ action: 'delete' });
      expect(result.isError).toBe(true);
    });

    it('create_area requires areaTitle', async () => {
      const result = await tool.execute({ action: 'create_area' } as any);
      expect(result.isError).toBe(true);
    });

    it('create_project requires projectTitle', async () => {
      const result = await tool.execute({ action: 'create_project' } as any);
      expect(result.isError).toBe(true);
    });

    it('get_project requires projectId', async () => {
      const result = await tool.execute({ action: 'get_project' } as any);
      expect(result.isError).toBe(true);
    });

    it('delete_project requires projectId', async () => {
      const result = await tool.execute({ action: 'delete_project' } as any);
      expect(result.isError).toBe(true);
    });

    it('get_project returns error for non-existent', async () => {
      const result = await tool.execute({ action: 'get_project', projectId: 'proj_nope' } as any);
      expect(result.isError).toBe(true);
    });

    it('delete_project returns error for non-existent', async () => {
      const result = await tool.execute({ action: 'delete_project', projectId: 'proj_nope' } as any);
      expect(result.isError).toBe(true);
    });

    it('delete_area returns error for non-existent', async () => {
      const result = await tool.execute({ action: 'delete_area', areaId: 'area_nope' } as any);
      expect(result.isError).toBe(true);
    });

    it('unknown action returns error', async () => {
      const result = await tool.execute({ action: 'invalid_action' as any });
      expect(result.isError).toBe(true);
      expect(result.content).toContain('Unknown action');
    });
  });

  // =========================================================================
  // List/Search (unchanged format)
  // =========================================================================

  describe('list and search remain unchanged', () => {
    it('list still works', async () => {
      service.createTask({ title: 'A' });
      const result = await tool.execute({ action: 'list' });
      expect(result.isError).toBe(false);
      expect(result.content).toContain('A');
      expect(result.content).toMatch(/Tasks \(\d+\/\d+\)/);
    });

    it('search still works', async () => {
      service.createTask({ title: 'Fix login bug' });
      const result = await tool.execute({ action: 'search', query: 'login' });
      expect(result.isError).toBe(false);
      expect(result.content).toContain('Fix login bug');
    });

    it('list_projects still works', async () => {
      service.createProject({ title: 'P1' });
      const result = await tool.execute({ action: 'list_projects' } as any);
      expect(result.isError).toBe(false);
      expect(result.content).toContain('P1');
    });

    it('list_areas still works', async () => {
      service.createArea({ title: 'Security' });
      service.createArea({ title: 'Quality' });
      const result = await tool.execute({ action: 'list_areas' } as any);
      expect(result.isError).toBe(false);
      expect(result.content).toContain('Areas (2)');
    });

    it('list_areas filters by status', async () => {
      service.createArea({ title: 'Active' });
      const archived = service.createArea({ title: 'Archived' });
      service.updateArea(archived.id, { status: 'archived' });
      const result = await tool.execute({ action: 'list_areas', areaStatus: 'archived' } as any);
      expect(result.content).toContain('Archived');
      expect(result.content).not.toContain('Active');
    });
  });
});
