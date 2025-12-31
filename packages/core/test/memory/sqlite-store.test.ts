/**
 * @fileoverview Tests for SQLite memory store
 *
 * TDD: Tests for persistent memory storage with FTS5
 * Uses real in-memory SQLite for accurate testing
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { SQLiteMemoryStore } from '../../src/memory/sqlite-store.js';
import type { SessionMemory, MemoryEntry, HandoffRecord } from '../../src/memory/types.js';

describe('SQLiteMemoryStore', () => {
  let store: SQLiteMemoryStore;

  beforeEach(() => {
    // Use in-memory database for tests
    store = new SQLiteMemoryStore({ dbPath: ':memory:' });
  });

  afterEach(async () => {
    await store.close();
  });

  describe('initialization', () => {
    it('should create store with in-memory database', () => {
      expect(store).toBeInstanceOf(SQLiteMemoryStore);
    });
  });

  describe('session operations', () => {
    it('should create a new session', async () => {
      const session = await store.createSession({
        startedAt: new Date().toISOString(),
        messages: [],
        toolCalls: [],
        workingDirectory: '/test/project',
        activeFiles: [],
        context: {},
      });

      expect(session.sessionId).toBeTruthy();
      expect(session.sessionId).toMatch(/^sess_/);
      expect(session.workingDirectory).toBe('/test/project');
    });

    it('should get session by id', async () => {
      const created = await store.createSession({
        startedAt: new Date().toISOString(),
        messages: [],
        toolCalls: [],
        workingDirectory: '/test/project',
        activeFiles: ['/test/file.ts'],
        context: { key: 'value' },
      });

      const retrieved = await store.getSession(created.sessionId);

      expect(retrieved).not.toBeNull();
      expect(retrieved?.sessionId).toBe(created.sessionId);
      expect(retrieved?.workingDirectory).toBe('/test/project');
      expect(retrieved?.activeFiles).toContain('/test/file.ts');
    });

    it('should update session', async () => {
      const session = await store.createSession({
        startedAt: new Date().toISOString(),
        messages: [],
        toolCalls: [],
        workingDirectory: '/test/project',
        activeFiles: [],
        context: {},
      });

      await store.updateSession(session.sessionId, {
        activeFiles: ['/test/file.ts', '/test/other.ts'],
        context: { updated: true },
      });

      const updated = await store.getSession(session.sessionId);
      expect(updated?.activeFiles).toHaveLength(2);
      expect(updated?.context).toHaveProperty('updated', true);
    });

    it('should end session and create handoff', async () => {
      const session = await store.createSession({
        startedAt: new Date().toISOString(),
        messages: [],
        toolCalls: [],
        workingDirectory: '/test/project',
        activeFiles: [],
        context: {},
      });

      const handoff = await store.endSession(session.sessionId);

      expect(handoff.sessionId).toBe(session.sessionId);
      expect(handoff.createdAt).toBeTruthy();

      // Session should have ended_at set
      const ended = await store.getSession(session.sessionId);
      expect(ended?.endedAt).toBeTruthy();
    });

    it('should return null for non-existent session', async () => {
      const session = await store.getSession('sess_nonexistent');
      expect(session).toBeNull();
    });
  });

  describe('memory entry operations', () => {
    it('should add a memory entry', async () => {
      const entry = await store.addEntry({
        type: 'pattern',
        content: 'Always use strict mode',
        source: 'project',
      });

      expect(entry.id).toBeTruthy();
      expect(entry.id).toMatch(/^mem_/);
      expect(entry.type).toBe('pattern');
      expect(entry.timestamp).toBeTruthy();
    });

    it('should get entry by id', async () => {
      const created = await store.addEntry({
        type: 'decision',
        content: 'Use TypeScript',
        source: 'project',
        metadata: { reason: 'type safety' },
      });

      const retrieved = await store.getEntry(created.id);

      expect(retrieved).not.toBeNull();
      expect(retrieved?.id).toBe(created.id);
      expect(retrieved?.content).toBe('Use TypeScript');
      expect(retrieved?.metadata).toHaveProperty('reason', 'type safety');
    });

    it('should search entries by type', async () => {
      await store.addEntry({ type: 'pattern', content: 'Pattern 1', source: 'project' });
      await store.addEntry({ type: 'pattern', content: 'Pattern 2', source: 'project' });
      await store.addEntry({ type: 'decision', content: 'Decision 1', source: 'project' });

      const results = await store.searchEntries({ type: 'pattern' });

      expect(results.entries.length).toBe(2);
      expect(results.totalCount).toBe(2);
      expect(results.entries.every(e => e.type === 'pattern')).toBe(true);
    });

    it('should search entries by source', async () => {
      await store.addEntry({ type: 'pattern', content: 'Project pattern', source: 'project' });
      await store.addEntry({ type: 'lesson', content: 'Global lesson', source: 'global' });

      const results = await store.searchEntries({ source: 'project' });

      expect(results.entries.length).toBe(1);
      expect(results.entries[0].content).toBe('Project pattern');
    });

    it('should search entries by text (FTS)', async () => {
      await store.addEntry({ type: 'pattern', content: 'Always use async/await for promises', source: 'project' });
      await store.addEntry({ type: 'pattern', content: 'Use strict TypeScript settings', source: 'project' });

      const results = await store.searchEntries({ searchText: 'async' });

      expect(results.entries.length).toBeGreaterThanOrEqual(1);
      expect(results.entries.some(e => e.content.includes('async'))).toBe(true);
    });

    it('should delete entry', async () => {
      const entry = await store.addEntry({
        type: 'lesson',
        content: 'Test lesson',
        source: 'global',
      });

      await store.deleteEntry(entry.id);
      const found = await store.getEntry(entry.id);

      expect(found).toBeNull();
    });

    it('should support pagination', async () => {
      // Add 5 entries
      for (let i = 0; i < 5; i++) {
        await store.addEntry({ type: 'pattern', content: `Pattern ${i}`, source: 'project' });
      }

      const page1 = await store.searchEntries({ type: 'pattern', limit: 2 });
      expect(page1.entries.length).toBe(2);
      expect(page1.hasMore).toBe(true);
      expect(page1.totalCount).toBe(5);

      const page2 = await store.searchEntries({ type: 'pattern', limit: 2, offset: 2 });
      expect(page2.entries.length).toBe(2);
    });
  });

  describe('handoff operations', () => {
    it('should create handoff', async () => {
      const session = await store.createSession({
        startedAt: new Date().toISOString(),
        messages: [],
        toolCalls: [],
        workingDirectory: '/test/project',
        activeFiles: [],
        context: {},
      });

      const handoff = await store.createHandoff(session.sessionId, 'Implemented feature X');

      expect(handoff.id).toBeTruthy();
      expect(handoff.id).toMatch(/^handoff_/);
      expect(handoff.summary).toBe('Implemented feature X');
      expect(handoff.sessionId).toBe(session.sessionId);
    });

    it('should get handoff by id', async () => {
      const session = await store.createSession({
        startedAt: new Date().toISOString(),
        messages: [],
        toolCalls: [],
        workingDirectory: '/test/project',
        activeFiles: [],
        context: {},
      });

      const created = await store.createHandoff(session.sessionId, 'Test handoff');
      const retrieved = await store.getHandoff(created.id);

      expect(retrieved).not.toBeNull();
      expect(retrieved?.id).toBe(created.id);
      expect(retrieved?.summary).toBe('Test handoff');
    });

    it('should list handoffs', async () => {
      const session = await store.createSession({
        startedAt: new Date().toISOString(),
        messages: [],
        toolCalls: [],
        workingDirectory: '/test/project',
        activeFiles: [],
        context: {},
      });

      await store.createHandoff(session.sessionId, 'Handoff 1');
      await store.createHandoff(session.sessionId, 'Handoff 2');

      const handoffs = await store.listHandoffs();

      expect(handoffs.length).toBeGreaterThanOrEqual(2);
    });
  });

  describe('ledger operations', () => {
    it('should add ledger entry', async () => {
      const entry = await store.addLedgerEntry({
        sessionId: 'sess_123',
        action: 'create_file',
        description: 'Created index.ts',
        filesModified: ['/src/index.ts'],
        success: true,
      });

      expect(entry.id).toBeTruthy();
      expect(entry.id).toMatch(/^ledger_/);
      expect(entry.action).toBe('create_file');
      expect(entry.success).toBe(true);
    });

    it('should get ledger entries by session', async () => {
      await store.addLedgerEntry({
        sessionId: 'sess_test1',
        action: 'edit_file',
        description: 'Edited index.ts',
        success: true,
      });

      await store.addLedgerEntry({
        sessionId: 'sess_test1',
        action: 'create_file',
        description: 'Created util.ts',
        success: true,
      });

      await store.addLedgerEntry({
        sessionId: 'sess_other',
        action: 'delete_file',
        description: 'Deleted old.ts',
        success: true,
      });

      const entries = await store.getLedgerEntries('sess_test1');

      expect(entries.length).toBe(2);
      expect(entries.every(e => e.sessionId === 'sess_test1')).toBe(true);
    });
  });

  describe('project memory', () => {
    it('should return null for non-existent project', async () => {
      const memory = await store.getProjectMemory('/nonexistent/project');
      expect(memory).toBeNull();
    });

    it('should create and update project memory', async () => {
      await store.updateProjectMemory('/test/project', {
        projectName: 'test',
        patterns: [],
        decisions: [],
        preferences: { testMode: true },
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      });

      const memory = await store.getProjectMemory('/test/project');

      expect(memory).not.toBeNull();
      expect(memory?.projectName).toBe('test');
      expect(memory?.preferences).toHaveProperty('testMode', true);
    });

    it('should update existing project memory', async () => {
      await store.updateProjectMemory('/test/project', {
        projectName: 'test',
        patterns: [],
        decisions: [],
        preferences: {},
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      });

      await store.updateProjectMemory('/test/project', {
        preferences: { updated: true },
      });

      const memory = await store.getProjectMemory('/test/project');
      expect(memory?.preferences).toHaveProperty('updated', true);
    });
  });

  describe('global memory', () => {
    it('should get global memory with defaults', async () => {
      const memory = await store.getGlobalMemory();

      expect(memory).toBeDefined();
      expect(memory.lessons).toBeInstanceOf(Array);
      expect(memory.statistics).toBeDefined();
      expect(memory.statistics.totalSessions).toBe(0);
    });

    it('should update global memory', async () => {
      await store.updateGlobalMemory({
        statistics: {
          totalSessions: 100,
          totalToolCalls: 5000,
        },
      });

      const memory = await store.getGlobalMemory();
      expect(memory.statistics.totalSessions).toBe(100);
      expect(memory.statistics.totalToolCalls).toBe(5000);
    });
  });

  describe('maintenance', () => {
    it('should compact database', async () => {
      await store.compact();
      // Should not throw
      expect(true).toBe(true);
    });

    it('should vacuum database', async () => {
      await store.vacuum();
      // Should not throw
      expect(true).toBe(true);
    });
  });
});
