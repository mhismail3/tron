/**
 * @fileoverview Tests for Branch Repository
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { DatabaseConnection } from '../../../../src/events/sqlite/database.js';
import { runMigrations } from '../../../../src/events/sqlite/migrations/index.js';
import { BranchRepository } from '../../../../src/events/sqlite/repositories/branch.repo.js';
import { SessionId, EventId, WorkspaceId } from '../../../../src/events/types.js';

describe('BranchRepository', () => {
  let connection: DatabaseConnection;
  let repo: BranchRepository;
  let testSessionId: SessionId;
  let testEventId1: EventId;
  let testEventId2: EventId;

  beforeEach(() => {
    connection = new DatabaseConnection(':memory:');
    const db = connection.open();
    runMigrations(db);
    repo = new BranchRepository(connection);

    // Create test workspace
    const workspaceId = WorkspaceId('ws_test');
    db.prepare(`
      INSERT INTO workspaces (id, path, name, created_at, last_activity_at)
      VALUES (?, ?, ?, datetime('now'), datetime('now'))
    `).run(workspaceId, '/test', 'Test');

    // Create test session
    testSessionId = SessionId('sess_test');
    db.prepare(`
      INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
      VALUES (?, ?, ?, ?, datetime('now'), datetime('now'))
    `).run(testSessionId, workspaceId, 'test-model', '/test');

    // Create test events
    testEventId1 = EventId('evt_test1');
    testEventId2 = EventId('evt_test2');
    db.prepare(`
      INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
      VALUES (?, ?, ?, ?, datetime('now'), '{}', ?)
    `).run(testEventId1, testSessionId, 0, 'message.user', workspaceId);
    db.prepare(`
      INSERT INTO events (id, session_id, parent_id, sequence, type, timestamp, payload, workspace_id)
      VALUES (?, ?, ?, ?, ?, datetime('now'), '{}', ?)
    `).run(testEventId2, testSessionId, testEventId1, 1, 'message.assistant', workspaceId);
  });

  afterEach(() => {
    connection.close();
  });

  describe('create', () => {
    it('should create a branch', () => {
      const branch = repo.create({
        sessionId: testSessionId,
        name: 'main',
        rootEventId: testEventId1,
        headEventId: testEventId2,
      });

      expect(branch.id).toMatch(/^br_[a-f0-9]+$/);
      expect(branch.sessionId).toBe(testSessionId);
      expect(branch.name).toBe('main');
      expect(branch.rootEventId).toBe(testEventId1);
      expect(branch.headEventId).toBe(testEventId2);
      expect(branch.isDefault).toBe(false);
    });

    it('should create a branch with description', () => {
      const branch = repo.create({
        sessionId: testSessionId,
        name: 'feature',
        description: 'A feature branch',
        rootEventId: testEventId1,
        headEventId: testEventId2,
      });

      expect(branch.description).toBe('A feature branch');
    });

    it('should create a default branch', () => {
      const branch = repo.create({
        sessionId: testSessionId,
        name: 'main',
        rootEventId: testEventId1,
        headEventId: testEventId2,
        isDefault: true,
      });

      expect(branch.isDefault).toBe(true);
    });
  });

  describe('getById', () => {
    it('should return null for non-existent branch', () => {
      const branch = repo.getById('br_nonexistent' as any);
      expect(branch).toBeNull();
    });

    it('should return branch by ID', () => {
      const created = repo.create({
        sessionId: testSessionId,
        name: 'main',
        rootEventId: testEventId1,
        headEventId: testEventId2,
      });

      const found = repo.getById(created.id);
      expect(found).toBeDefined();
      expect(found?.id).toBe(created.id);
      expect(found?.name).toBe('main');
    });
  });

  describe('getBySession', () => {
    it('should return empty array when no branches', () => {
      const branches = repo.getBySession(testSessionId);
      expect(branches).toEqual([]);
    });

    it('should return all branches for session', () => {
      repo.create({
        sessionId: testSessionId,
        name: 'branch1',
        rootEventId: testEventId1,
        headEventId: testEventId2,
      });
      repo.create({
        sessionId: testSessionId,
        name: 'branch2',
        rootEventId: testEventId1,
        headEventId: testEventId2,
      });

      const branches = repo.getBySession(testSessionId);
      expect(branches).toHaveLength(2);
    });

    it('should order by created_at ascending', () => {
      const b1 = repo.create({
        sessionId: testSessionId,
        name: 'first',
        rootEventId: testEventId1,
        headEventId: testEventId2,
      });
      const b2 = repo.create({
        sessionId: testSessionId,
        name: 'second',
        rootEventId: testEventId1,
        headEventId: testEventId2,
      });

      const branches = repo.getBySession(testSessionId);
      expect(branches[0].name).toBe('first');
      expect(branches[1].name).toBe('second');
    });
  });

  describe('getDefault', () => {
    it('should return null when no default branch', () => {
      repo.create({
        sessionId: testSessionId,
        name: 'not-default',
        rootEventId: testEventId1,
        headEventId: testEventId2,
        isDefault: false,
      });

      const defaultBranch = repo.getDefault(testSessionId);
      expect(defaultBranch).toBeNull();
    });

    it('should return default branch', () => {
      repo.create({
        sessionId: testSessionId,
        name: 'main',
        rootEventId: testEventId1,
        headEventId: testEventId2,
        isDefault: true,
      });

      const defaultBranch = repo.getDefault(testSessionId);
      expect(defaultBranch).toBeDefined();
      expect(defaultBranch?.isDefault).toBe(true);
    });
  });

  describe('updateHead', () => {
    it('should update branch head event', async () => {
      const branch = repo.create({
        sessionId: testSessionId,
        name: 'main',
        rootEventId: testEventId1,
        headEventId: testEventId1, // Start at root
      });

      // Small delay to ensure different timestamp
      await new Promise(resolve => setTimeout(resolve, 10));

      repo.updateHead(branch.id, testEventId2);

      const updated = repo.getById(branch.id);
      expect(updated?.headEventId).toBe(testEventId2);
      expect(updated?.lastActivityAt).not.toBe(branch.lastActivityAt);
    });
  });

  describe('updateName', () => {
    it('should update branch name', () => {
      const branch = repo.create({
        sessionId: testSessionId,
        name: 'old-name',
        rootEventId: testEventId1,
        headEventId: testEventId2,
      });

      repo.updateName(branch.id, 'new-name');

      const updated = repo.getById(branch.id);
      expect(updated?.name).toBe('new-name');
    });
  });

  describe('updateDescription', () => {
    it('should update branch description', () => {
      const branch = repo.create({
        sessionId: testSessionId,
        name: 'main',
        rootEventId: testEventId1,
        headEventId: testEventId2,
      });

      repo.updateDescription(branch.id, 'New description');

      const updated = repo.getById(branch.id);
      expect(updated?.description).toBe('New description');
    });

    it('should clear description when null', () => {
      const branch = repo.create({
        sessionId: testSessionId,
        name: 'main',
        description: 'Has description',
        rootEventId: testEventId1,
        headEventId: testEventId2,
      });

      repo.updateDescription(branch.id, null);

      const updated = repo.getById(branch.id);
      expect(updated?.description).toBeNull();
    });
  });

  describe('setDefault', () => {
    it('should set branch as default', () => {
      const branch = repo.create({
        sessionId: testSessionId,
        name: 'main',
        rootEventId: testEventId1,
        headEventId: testEventId2,
        isDefault: false,
      });

      repo.setDefault(branch.id);

      const updated = repo.getById(branch.id);
      expect(updated?.isDefault).toBe(true);
    });

    it('should unset other defaults', () => {
      const b1 = repo.create({
        sessionId: testSessionId,
        name: 'first',
        rootEventId: testEventId1,
        headEventId: testEventId2,
        isDefault: true,
      });
      const b2 = repo.create({
        sessionId: testSessionId,
        name: 'second',
        rootEventId: testEventId1,
        headEventId: testEventId2,
      });

      repo.setDefault(b2.id);

      expect(repo.getById(b1.id)?.isDefault).toBe(false);
      expect(repo.getById(b2.id)?.isDefault).toBe(true);
    });
  });

  describe('delete', () => {
    it('should delete branch', () => {
      const branch = repo.create({
        sessionId: testSessionId,
        name: 'main',
        rootEventId: testEventId1,
        headEventId: testEventId2,
      });

      const deleted = repo.delete(branch.id);
      expect(deleted).toBe(true);
      expect(repo.getById(branch.id)).toBeNull();
    });

    it('should return false for non-existent branch', () => {
      const deleted = repo.delete('br_nonexistent' as any);
      expect(deleted).toBe(false);
    });
  });

  describe('deleteBySession', () => {
    it('should delete all branches for session', () => {
      repo.create({
        sessionId: testSessionId,
        name: 'branch1',
        rootEventId: testEventId1,
        headEventId: testEventId2,
      });
      repo.create({
        sessionId: testSessionId,
        name: 'branch2',
        rootEventId: testEventId1,
        headEventId: testEventId2,
      });

      const deleted = repo.deleteBySession(testSessionId);
      expect(deleted).toBe(2);
      expect(repo.getBySession(testSessionId)).toHaveLength(0);
    });
  });

  describe('countBySession', () => {
    it('should return 0 when no branches', () => {
      expect(repo.countBySession(testSessionId)).toBe(0);
    });

    it('should return count of branches', () => {
      repo.create({
        sessionId: testSessionId,
        name: 'branch1',
        rootEventId: testEventId1,
        headEventId: testEventId2,
      });
      repo.create({
        sessionId: testSessionId,
        name: 'branch2',
        rootEventId: testEventId1,
        headEventId: testEventId2,
      });

      expect(repo.countBySession(testSessionId)).toBe(2);
    });
  });

  describe('exists', () => {
    it('should return false for non-existent branch', () => {
      expect(repo.exists('br_nonexistent' as any)).toBe(false);
    });

    it('should return true for existing branch', () => {
      const branch = repo.create({
        sessionId: testSessionId,
        name: 'main',
        rootEventId: testEventId1,
        headEventId: testEventId2,
      });

      expect(repo.exists(branch.id)).toBe(true);
    });
  });
});
