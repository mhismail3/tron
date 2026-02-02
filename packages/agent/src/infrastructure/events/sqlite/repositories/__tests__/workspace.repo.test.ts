/**
 * @fileoverview Tests for Workspace Repository
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { DatabaseConnection } from '../../database.js';
import { runMigrations } from '../../migrations/index.js';
import { WorkspaceRepository } from '../../repositories/workspace.repo.js';

describe('WorkspaceRepository', () => {
  let connection: DatabaseConnection;
  let repo: WorkspaceRepository;

  beforeEach(() => {
    connection = new DatabaseConnection(':memory:');
    const db = connection.open();
    runMigrations(db);
    repo = new WorkspaceRepository(connection);
  });

  afterEach(() => {
    connection.close();
  });

  describe('create', () => {
    it('should create a workspace with path', () => {
      const workspace = repo.create({ path: '/home/user/project' });

      expect(workspace.id).toMatch(/^ws_[a-f0-9]+$/);
      expect(workspace.path).toBe('/home/user/project');
      expect(workspace.name).toBeUndefined();
      expect(workspace.sessionCount).toBe(0);
    });

    it('should create a workspace with name', () => {
      const workspace = repo.create({
        path: '/home/user/project',
        name: 'My Project',
      });

      expect(workspace.name).toBe('My Project');
    });

    it('should set timestamps', () => {
      const workspace = repo.create({ path: '/test' });

      expect(workspace.created).toBeDefined();
      expect(workspace.lastActivity).toBeDefined();
      expect(new Date(workspace.created).getTime()).toBeLessThanOrEqual(Date.now());
    });
  });

  describe('getById', () => {
    it('should return null for non-existent workspace', () => {
      const workspace = repo.getById('ws_nonexistent' as any);
      expect(workspace).toBeNull();
    });

    it('should return workspace by ID', () => {
      const created = repo.create({ path: '/test', name: 'Test' });
      const found = repo.getById(created.id);

      expect(found).toBeDefined();
      expect(found?.id).toBe(created.id);
      expect(found?.path).toBe('/test');
      expect(found?.name).toBe('Test');
    });
  });

  describe('getByPath', () => {
    it('should return null for non-existent path', () => {
      const workspace = repo.getByPath('/nonexistent');
      expect(workspace).toBeNull();
    });

    it('should return workspace by path', () => {
      repo.create({ path: '/home/user/project' });
      const found = repo.getByPath('/home/user/project');

      expect(found).toBeDefined();
      expect(found?.path).toBe('/home/user/project');
    });
  });

  describe('getOrCreate', () => {
    it('should create workspace if not exists', () => {
      const workspace = repo.getOrCreate('/new/path', 'New Project');

      expect(workspace.path).toBe('/new/path');
      expect(workspace.name).toBe('New Project');
      expect(repo.count()).toBe(1);
    });

    it('should return existing workspace', () => {
      const created = repo.create({ path: '/existing', name: 'Original Name' });
      const found = repo.getOrCreate('/existing', 'Different Name');

      expect(found.id).toBe(created.id);
      expect(found.name).toBe('Original Name'); // Keeps original name
      expect(repo.count()).toBe(1);
    });
  });

  describe('list', () => {
    it('should return empty array when no workspaces', () => {
      const workspaces = repo.list();
      expect(workspaces).toEqual([]);
    });

    it('should return all workspaces', () => {
      repo.create({ path: '/project1' });
      repo.create({ path: '/project2' });
      repo.create({ path: '/project3' });

      const workspaces = repo.list();
      expect(workspaces).toHaveLength(3);
    });

    it('should order by last activity descending', async () => {
      const ws1 = repo.create({ path: '/first' });
      const ws2 = repo.create({ path: '/second' });
      const ws3 = repo.create({ path: '/third' });

      // Small delay to ensure different timestamp
      await new Promise(resolve => setTimeout(resolve, 10));

      // Update middle workspace to be most recent
      repo.updateLastActivity(ws2.id);

      const workspaces = repo.list();
      expect(workspaces[0].id).toBe(ws2.id);
    });
  });

  describe('updateLastActivity', () => {
    it('should update last activity timestamp', async () => {
      const workspace = repo.create({ path: '/test' });
      const originalActivity = workspace.lastActivity;

      // Small delay to ensure different timestamp
      await new Promise(resolve => setTimeout(resolve, 10));

      repo.updateLastActivity(workspace.id);
      const updated = repo.getById(workspace.id);

      expect(updated?.lastActivity).not.toBe(originalActivity);
    });
  });

  describe('updateName', () => {
    it('should update workspace name', () => {
      const workspace = repo.create({ path: '/test', name: 'Original' });
      repo.updateName(workspace.id, 'Updated');

      const updated = repo.getById(workspace.id);
      expect(updated?.name).toBe('Updated');
    });

    it('should clear name when null', () => {
      const workspace = repo.create({ path: '/test', name: 'Has Name' });
      repo.updateName(workspace.id, null);

      const updated = repo.getById(workspace.id);
      expect(updated?.name).toBeUndefined();
    });
  });

  describe('delete', () => {
    it('should delete workspace', () => {
      const workspace = repo.create({ path: '/test' });
      expect(repo.count()).toBe(1);

      const deleted = repo.delete(workspace.id);
      expect(deleted).toBe(true);
      expect(repo.count()).toBe(0);
    });

    it('should return false for non-existent workspace', () => {
      const deleted = repo.delete('ws_nonexistent' as any);
      expect(deleted).toBe(false);
    });
  });

  describe('count', () => {
    it('should return 0 for empty table', () => {
      expect(repo.count()).toBe(0);
    });

    it('should return number of workspaces', () => {
      repo.create({ path: '/project1' });
      repo.create({ path: '/project2' });

      expect(repo.count()).toBe(2);
    });
  });

  describe('exists', () => {
    it('should return false for non-existent workspace', () => {
      expect(repo.exists('ws_nonexistent' as any)).toBe(false);
    });

    it('should return true for existing workspace', () => {
      const workspace = repo.create({ path: '/test' });
      expect(repo.exists(workspace.id)).toBe(true);
    });
  });
});
