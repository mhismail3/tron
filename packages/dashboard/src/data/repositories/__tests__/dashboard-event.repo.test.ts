/**
 * @fileoverview Tests for DashboardEventRepository
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { DashboardEventRepository } from '../dashboard-event.repo.js';
import {
  createSQLiteEventStore,
  SQLiteEventStore,
  SessionId,
  WorkspaceId,
  EventId,
} from '@tron/agent';
// Import test fixtures - we'll create local fixtures for dashboard tests
import {
  createSessionStartEvent,
  createUserMessageEvent,
  createAssistantMessageEvent,
  createToolCallEvent,
  createToolResultEvent,
} from '../../../test-fixtures.js';
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';

describe('DashboardEventRepository', () => {
  let store: SQLiteEventStore;
  let repo: DashboardEventRepository;
  let dbPath: string;
  let workspaceId: WorkspaceId;
  let sessionId: SessionId;

  beforeEach(async () => {
    // Create temp database
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dashboard-event-test-'));
    dbPath = path.join(tmpDir, 'test.db');
    store = await createSQLiteEventStore(dbPath);
    repo = new DashboardEventRepository(store);

    // Create test workspace and session
    const workspace = await store.createWorkspace({ path: '/test/workspace', name: 'test' });
    workspaceId = workspace.id;

    const session = await store.createSession({
      workspaceId,
      model: 'claude-sonnet-4-20250514',
      workingDirectory: '/test/project',
    });
    sessionId = session.id;
  });

  afterEach(async () => {
    await store.close();
    // Clean up temp files
    if (fs.existsSync(dbPath)) {
      fs.unlinkSync(dbPath);
      const shmPath = dbPath + '-shm';
      const walPath = dbPath + '-wal';
      if (fs.existsSync(shmPath)) fs.unlinkSync(shmPath);
      if (fs.existsSync(walPath)) fs.unlinkSync(walPath);
      fs.rmdirSync(path.dirname(dbPath));
    }
  });

  describe('getEventsBySession', () => {
    it('returns empty result for session with no events', async () => {
      const result = await repo.getEventsBySession(sessionId);

      expect(result.items).toEqual([]);
      expect(result.total).toBe(0);
      expect(result.hasMore).toBe(false);
    });

    it('returns all events in sequence order', async () => {
      // Create events
      const start = createSessionStartEvent({ sessionId, workspaceId, sequence: 0 });
      const user = createUserMessageEvent({
        sessionId,
        workspaceId,
        parentId: start.id,
        sequence: 1,
        content: 'Hello',
      });
      const assistant = createAssistantMessageEvent({
        sessionId,
        workspaceId,
        parentId: user.id,
        sequence: 2,
      });

      await store.insertEvent(start);
      await store.insertEvent(user);
      await store.insertEvent(assistant);

      const result = await repo.getEventsBySession(sessionId);

      expect(result.items).toHaveLength(3);
      expect(result.items[0].type).toBe('session.start');
      expect(result.items[1].type).toBe('message.user');
      expect(result.items[2].type).toBe('message.assistant');
    });

    it('respects pagination', async () => {
      // Create 5 events
      const start = createSessionStartEvent({ sessionId, workspaceId, sequence: 0 });
      await store.insertEvent(start);

      let parentId = start.id;
      for (let i = 1; i <= 4; i++) {
        const event = createUserMessageEvent({
          sessionId,
          workspaceId,
          parentId,
          sequence: i,
          content: `Message ${i}`,
        });
        await store.insertEvent(event);
        parentId = event.id;
      }

      // Page 1
      const page1 = await repo.getEventsBySession(sessionId, { limit: 2, offset: 0 });
      expect(page1.items).toHaveLength(2);
      expect(page1.total).toBe(5);
      expect(page1.hasMore).toBe(true);

      // Page 2
      const page2 = await repo.getEventsBySession(sessionId, { limit: 2, offset: 2 });
      expect(page2.items).toHaveLength(2);
      expect(page2.hasMore).toBe(true);

      // Page 3
      const page3 = await repo.getEventsBySession(sessionId, { limit: 2, offset: 4 });
      expect(page3.items).toHaveLength(1);
      expect(page3.hasMore).toBe(false);
    });
  });

  describe('getEventsByType', () => {
    it('filters events by type', async () => {
      const start = createSessionStartEvent({ sessionId, workspaceId, sequence: 0 });
      const user = createUserMessageEvent({
        sessionId,
        workspaceId,
        parentId: start.id,
        sequence: 1,
      });
      const toolCall = createToolCallEvent({
        sessionId,
        workspaceId,
        parentId: user.id,
        sequence: 2,
        name: 'Read',
      });
      const toolResult = createToolResultEvent({
        sessionId,
        workspaceId,
        parentId: toolCall.id,
        sequence: 3,
        toolCallId: toolCall.payload.toolCallId,
      });
      const assistant = createAssistantMessageEvent({
        sessionId,
        workspaceId,
        parentId: toolResult.id,
        sequence: 4,
      });

      await store.insertEvent(start);
      await store.insertEvent(user);
      await store.insertEvent(toolCall);
      await store.insertEvent(toolResult);
      await store.insertEvent(assistant);

      // Filter for tool events only
      const toolEvents = await repo.getEventsByType(sessionId, ['tool.call', 'tool.result']);
      expect(toolEvents.items).toHaveLength(2);
      expect(toolEvents.items[0].type).toBe('tool.call');
      expect(toolEvents.items[1].type).toBe('tool.result');

      // Filter for messages only
      const messageEvents = await repo.getEventsByType(sessionId, [
        'message.user',
        'message.assistant',
      ]);
      expect(messageEvents.items).toHaveLength(2);
    });
  });

  describe('getById', () => {
    it('returns null for non-existent event', async () => {
      const event = await repo.getById('evt_nonexistent' as EventId);
      expect(event).toBeNull();
    });

    it('returns event by ID', async () => {
      const start = createSessionStartEvent({ sessionId, workspaceId });
      await store.insertEvent(start);

      const found = await repo.getById(start.id);
      expect(found).not.toBeNull();
      expect(found!.id).toBe(start.id);
      expect(found!.type).toBe('session.start');
    });
  });

  describe('countBySession', () => {
    it('counts events in a session', async () => {
      const start = createSessionStartEvent({ sessionId, workspaceId, sequence: 0 });
      const user = createUserMessageEvent({
        sessionId,
        workspaceId,
        parentId: start.id,
        sequence: 1,
      });
      const assistant = createAssistantMessageEvent({
        sessionId,
        workspaceId,
        parentId: user.id,
        sequence: 2,
      });

      await store.insertEvent(start);
      await store.insertEvent(user);
      await store.insertEvent(assistant);

      const count = await repo.countBySession(sessionId);
      expect(count).toBe(3);
    });
  });
});
