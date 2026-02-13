/**
 * @fileoverview Tests for DashboardSessionRepository
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { DashboardSessionRepository } from '../dashboard-session.repo.js';
import {
  createSQLiteEventStore,
  SQLiteEventStore,
  SessionId,
  WorkspaceId,
  EventId,
} from '@tron/agent';
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';

describe('DashboardSessionRepository', () => {
  let store: SQLiteEventStore;
  let repo: DashboardSessionRepository;
  let dbPath: string;

  beforeEach(async () => {
    // Create temp database
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dashboard-test-'));
    dbPath = path.join(tmpDir, 'test.db');
    store = await createSQLiteEventStore(dbPath);
    repo = new DashboardSessionRepository(store);

    // Create test workspace
    await store.createWorkspace({ path: '/test/workspace', name: 'test' });
  });

  afterEach(async () => {
    await store.close();
    // Clean up temp files
    if (fs.existsSync(dbPath)) {
      fs.unlinkSync(dbPath);
      fs.rmdirSync(path.dirname(dbPath));
    }
  });

  describe('listWithStats', () => {
    it('returns empty array when no sessions exist', async () => {
      const sessions = await repo.listWithStats();
      expect(sessions).toEqual([]);
    });

    it('returns sessions ordered by last activity (desc by default)', async () => {
      const workspace = await store.getWorkspaceByPath('/test/workspace');
      const workspaceId = workspace!.id;

      // Create two sessions
      const session1 = await store.createSession({
        workspaceId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project1',
        title: 'Session 1',
      });

      // Small delay to ensure different timestamps
      await new Promise((r) => setTimeout(r, 10));

      const session2 = await store.createSession({
        workspaceId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project2',
        title: 'Session 2',
      });

      const sessions = await repo.listWithStats();

      expect(sessions).toHaveLength(2);
      expect(sessions[0].id).toBe(session2.id); // Most recent first
      expect(sessions[1].id).toBe(session1.id);
    });

    it('filters by archived state', async () => {
      const workspace = await store.getWorkspaceByPath('/test/workspace');
      const workspaceId = workspace!.id;

      const session1 = await store.createSession({
        workspaceId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project1',
      });

      const session2 = await store.createSession({
        workspaceId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project2',
      });

      await store.archiveSession(session1.id);

      // Filter non-archived sessions
      const activeSessions = await repo.listWithStats({ archived: false });
      expect(activeSessions).toHaveLength(1);
      expect(activeSessions[0].id).toBe(session2.id);

      // Filter archived sessions
      const archivedSessions = await repo.listWithStats({ archived: true });
      expect(archivedSessions).toHaveLength(1);
      expect(archivedSessions[0].id).toBe(session1.id);
    });

    it('respects limit and offset', async () => {
      const workspace = await store.getWorkspaceByPath('/test/workspace');
      const workspaceId = workspace!.id;

      // Create 5 sessions
      for (let i = 0; i < 5; i++) {
        await store.createSession({
          workspaceId,
          model: 'claude-sonnet-4-20250514',
          workingDirectory: `/test/project${i}`,
          title: `Session ${i}`,
        });
        await new Promise((r) => setTimeout(r, 5));
      }

      const page1 = await repo.listWithStats({ limit: 2, offset: 0 });
      expect(page1).toHaveLength(2);

      const page2 = await repo.listWithStats({ limit: 2, offset: 2 });
      expect(page2).toHaveLength(2);
      expect(page2[0].id).not.toBe(page1[0].id);

      const page3 = await repo.listWithStats({ limit: 2, offset: 4 });
      expect(page3).toHaveLength(1);
    });
  });

  describe('getById', () => {
    it('returns null for non-existent session', async () => {
      const session = await repo.getById('sess_nonexistent' as SessionId);
      expect(session).toBeNull();
    });

    it('returns session with all stats', async () => {
      const workspace = await store.getWorkspaceByPath('/test/workspace');
      const workspaceId = workspace!.id;

      const created = await store.createSession({
        workspaceId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
        title: 'Test Session',
        tags: ['test', 'unit'],
      });

      const session = await repo.getById(created.id);

      expect(session).not.toBeNull();
      expect(session!.id).toBe(created.id);
      expect(session!.title).toBe('Test Session');
      expect(session!.model).toBe('claude-sonnet-4-20250514');
      expect(session!.workingDirectory).toBe('/test/project');
      expect(session!.isArchived).toBe(false);
      expect(session!.tags).toEqual(['test', 'unit']);
    });
  });

  describe('getTokenUsageBySession', () => {
    it('returns zero usage for empty session', async () => {
      const workspace = await store.getWorkspaceByPath('/test/workspace');
      const workspaceId = workspace!.id;

      const session = await store.createSession({
        workspaceId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      const usage = await repo.getTokenUsageBySession(session.id);

      expect(usage.inputTokens).toBe(0);
      expect(usage.outputTokens).toBe(0);
      expect(usage.totalTokens).toBe(0);
    });

    it('aggregates token usage from session counters', async () => {
      const workspace = await store.getWorkspaceByPath('/test/workspace');
      const workspaceId = workspace!.id;

      const session = await store.createSession({
        workspaceId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      // Increment counters
      await store.incrementSessionCounters(session.id, {
        inputTokens: 1000,
        outputTokens: 500,
        cacheReadTokens: 100,
        cacheCreationTokens: 50,
        cost: 0.05,
      });

      const usage = await repo.getTokenUsageBySession(session.id);

      expect(usage.inputTokens).toBe(1000);
      expect(usage.outputTokens).toBe(500);
      expect(usage.totalTokens).toBe(1500);
      expect(usage.cacheReadTokens).toBe(100);
      expect(usage.cacheCreationTokens).toBe(50);
      expect(usage.estimatedCost).toBe(0.05);
    });
  });

  describe('getStats', () => {
    it('returns dashboard-wide statistics', async () => {
      const workspace = await store.getWorkspaceByPath('/test/workspace');
      const workspaceId = workspace!.id;

      // Create sessions
      const session1 = await store.createSession({
        workspaceId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project1',
      });

      const session2 = await store.createSession({
        workspaceId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project2',
      });

      await store.archiveSession(session1.id);

      // Add some token usage
      await store.incrementSessionCounters(session1.id, {
        inputTokens: 1000,
        cost: 0.05,
      });

      const stats = await repo.getStats();

      expect(stats.totalSessions).toBe(2);
      expect(stats.activeSessions).toBe(1);
      expect(stats.totalTokensUsed).toBeGreaterThanOrEqual(1000);
    });
  });

  describe('count', () => {
    it('counts all sessions', async () => {
      const workspace = await store.getWorkspaceByPath('/test/workspace');
      const workspaceId = workspace!.id;

      await store.createSession({
        workspaceId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project1',
      });

      await store.createSession({
        workspaceId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project2',
      });

      const count = await repo.count();
      expect(count).toBe(2);
    });

    it('counts with filters', async () => {
      const workspace = await store.getWorkspaceByPath('/test/workspace');
      const workspaceId = workspace!.id;

      const session1 = await store.createSession({
        workspaceId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project1',
      });

      await store.createSession({
        workspaceId,
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project2',
      });

      await store.archiveSession(session1.id);

      const activeCount = await repo.count({ archived: false });
      expect(activeCount).toBe(1);
    });
  });
});
