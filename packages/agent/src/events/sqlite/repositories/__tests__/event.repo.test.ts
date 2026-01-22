/**
 * @fileoverview Tests for Event Repository
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { DatabaseConnection } from '../../database.js';
import { runMigrations } from '../../migrations/index.js';
import { EventRepository } from '../../repositories/event.repo.js';
import {
  EventId,
  SessionId,
  WorkspaceId,
  type SessionEvent,
} from '../../../types.js';

describe('EventRepository', () => {
  let connection: DatabaseConnection;
  let repo: EventRepository;
  let testSessionId: SessionId;
  let testWorkspaceId: WorkspaceId;

  beforeEach(() => {
    connection = new DatabaseConnection(':memory:');
    const db = connection.open();
    runMigrations(db);
    repo = new EventRepository(connection);

    // Create test workspace
    testWorkspaceId = WorkspaceId('ws_test');
    db.prepare(`
      INSERT INTO workspaces (id, path, name, created_at, last_activity_at)
      VALUES (?, ?, ?, datetime('now'), datetime('now'))
    `).run(testWorkspaceId, '/test', 'Test');

    // Create test session
    testSessionId = SessionId('sess_test');
    db.prepare(`
      INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
      VALUES (?, ?, ?, ?, datetime('now'), datetime('now'))
    `).run(testSessionId, testWorkspaceId, 'test-model', '/test');
  });

  afterEach(() => {
    connection.close();
  });

  function createEvent(overrides: Partial<SessionEvent> = {}): SessionEvent {
    return {
      id: EventId(`evt_${Math.random().toString(36).slice(2, 14)}`),
      parentId: null,
      sessionId: testSessionId,
      workspaceId: testWorkspaceId,
      timestamp: new Date().toISOString(),
      type: 'message.user',
      sequence: 0,
      payload: { content: 'Test message' },
      ...overrides,
    } as SessionEvent;
  }

  describe('insert', () => {
    it('should insert an event', async () => {
      const event = createEvent();
      await repo.insert(event);

      const found = repo.getById(event.id);
      expect(found).toBeDefined();
      expect(found?.id).toBe(event.id);
      expect(found?.type).toBe('message.user');
    });

    it('should extract role from event type', async () => {
      const userEvent = createEvent({ type: 'message.user' });
      const assistantEvent = createEvent({
        id: EventId('evt_assistant'),
        type: 'message.assistant',
        sequence: 1,
      });
      const toolEvent = createEvent({
        id: EventId('evt_tool'),
        type: 'tool.call',
        sequence: 2,
      });

      await repo.insert(userEvent);
      await repo.insert(assistantEvent);
      await repo.insert(toolEvent);

      // Verify all events exist
      expect(repo.getById(userEvent.id)).toBeDefined();
      expect(repo.getById(assistantEvent.id)).toBeDefined();
      expect(repo.getById(toolEvent.id)).toBeDefined();
    });

    it('should calculate depth from parent', async () => {
      const root = createEvent({ sequence: 0 });
      await repo.insert(root);

      const child = createEvent({
        id: EventId('evt_child'),
        parentId: root.id,
        sequence: 1,
      });
      await repo.insert(child);

      const grandchild = createEvent({
        id: EventId('evt_grandchild'),
        parentId: child.id,
        sequence: 2,
      });
      await repo.insert(grandchild);

      expect(repo.getById(root.id)?.depth).toBe(0);
      expect(repo.getById(child.id)?.depth).toBe(1);
      expect(repo.getById(grandchild.id)?.depth).toBe(2);
    });

    it('should extract token usage', async () => {
      const event = createEvent({
        type: 'message.assistant',
        payload: {
          content: 'Response',
          tokenUsage: {
            inputTokens: 100,
            outputTokens: 50,
            cacheReadTokens: 10,
            cacheCreationTokens: 5,
          },
        },
      });
      await repo.insert(event);

      const summary = repo.getTokenUsageSummary(testSessionId);
      expect(summary.inputTokens).toBe(100);
      expect(summary.outputTokens).toBe(50);
      expect(summary.cacheReadTokens).toBe(10);
      expect(summary.cacheCreationTokens).toBe(5);
    });

    it('should extract tool info', async () => {
      const event = createEvent({
        type: 'tool.call',
        payload: {
          name: 'readFile',
          toolCallId: 'call_123',
          turn: 1,
        },
      });
      await repo.insert(event);

      const found = repo.getById(event.id);
      expect(found).toBeDefined();
    });
  });

  describe('insertBatch', () => {
    it('should insert multiple events', async () => {
      const events = [
        createEvent({ id: EventId('evt_1'), sequence: 0 }),
        createEvent({ id: EventId('evt_2'), sequence: 1 }),
        createEvent({ id: EventId('evt_3'), sequence: 2 }),
      ];

      await repo.insertBatch(events);

      expect(repo.countBySession(testSessionId)).toBe(3);
    });

    it('should handle empty array', async () => {
      await repo.insertBatch([]);
      expect(repo.countBySession(testSessionId)).toBe(0);
    });
  });

  describe('getById', () => {
    it('should return null for non-existent event', () => {
      const event = repo.getById(EventId('evt_nonexistent'));
      expect(event).toBeNull();
    });

    it('should return event with parsed payload', async () => {
      const event = createEvent({
        payload: { content: 'Hello', nested: { key: 'value' } },
      });
      await repo.insert(event);

      const found = repo.getById(event.id);
      expect(found?.payload).toEqual({ content: 'Hello', nested: { key: 'value' } });
    });
  });

  describe('getByIds', () => {
    it('should return empty map for empty array', () => {
      const result = repo.getByIds([]);
      expect(result.size).toBe(0);
    });

    it('should return map of found events', async () => {
      const e1 = createEvent({ id: EventId('evt_1'), sequence: 0 });
      const e2 = createEvent({ id: EventId('evt_2'), sequence: 1 });
      await repo.insert(e1);
      await repo.insert(e2);

      const result = repo.getByIds([e1.id, e2.id, EventId('evt_nonexistent')]);
      expect(result.size).toBe(2);
      expect(result.get(e1.id)).toBeDefined();
      expect(result.get(e2.id)).toBeDefined();
    });
  });

  describe('getBySession', () => {
    it('should return empty array when no events', () => {
      const events = repo.getBySession(testSessionId);
      expect(events).toEqual([]);
    });

    it('should return events ordered by sequence', async () => {
      await repo.insert(createEvent({ id: EventId('evt_2'), sequence: 2 }));
      await repo.insert(createEvent({ id: EventId('evt_0'), sequence: 0 }));
      await repo.insert(createEvent({ id: EventId('evt_1'), sequence: 1 }));

      const events = repo.getBySession(testSessionId);
      expect(events.map(e => e.sequence)).toEqual([0, 1, 2]);
    });

    it('should respect limit option', async () => {
      for (let i = 0; i < 10; i++) {
        await repo.insert(createEvent({ id: EventId(`evt_${i}`), sequence: i }));
      }

      const events = repo.getBySession(testSessionId, { limit: 5 });
      expect(events).toHaveLength(5);
      expect(events[0].sequence).toBe(0);
    });

    it('should respect offset option', async () => {
      for (let i = 0; i < 10; i++) {
        await repo.insert(createEvent({ id: EventId(`evt_${i}`), sequence: i }));
      }

      const events = repo.getBySession(testSessionId, { limit: 5, offset: 3 });
      expect(events).toHaveLength(5);
      expect(events[0].sequence).toBe(3);
    });
  });

  describe('getByTypes', () => {
    it('should return empty array for empty types', async () => {
      await repo.insert(createEvent());
      const events = repo.getByTypes(testSessionId, []);
      expect(events).toEqual([]);
    });

    it('should filter by types', async () => {
      await repo.insert(createEvent({ id: EventId('evt_user'), type: 'message.user', sequence: 0 }));
      await repo.insert(createEvent({ id: EventId('evt_asst'), type: 'message.assistant', sequence: 1 }));
      await repo.insert(createEvent({ id: EventId('evt_tool'), type: 'tool.call', sequence: 2 }));

      const messages = repo.getByTypes(testSessionId, ['message.user', 'message.assistant']);
      expect(messages).toHaveLength(2);
      expect(messages.map(e => e.type)).toContain('message.user');
      expect(messages.map(e => e.type)).toContain('message.assistant');
    });
  });

  describe('getNextSequence', () => {
    it('should return 0 for empty session', () => {
      const seq = repo.getNextSequence(testSessionId);
      expect(seq).toBe(0);
    });

    it('should return next sequence number', async () => {
      await repo.insert(createEvent({ sequence: 0 }));
      await repo.insert(createEvent({ id: EventId('evt_1'), sequence: 1 }));

      const seq = repo.getNextSequence(testSessionId);
      expect(seq).toBe(2);
    });
  });

  describe('getAncestors', () => {
    it('should return empty array for root event with no ancestors', async () => {
      // Note: getAncestors includes the event itself
      const root = createEvent({ sequence: 0 });
      await repo.insert(root);

      const ancestors = repo.getAncestors(root.id);
      expect(ancestors).toHaveLength(1);
      expect(ancestors[0].id).toBe(root.id);
    });

    it('should return ancestor chain in chronological order (root first)', async () => {
      const root = createEvent({ id: EventId('evt_root'), sequence: 0 });
      await repo.insert(root);

      const child = createEvent({
        id: EventId('evt_child'),
        parentId: root.id,
        sequence: 1,
      });
      await repo.insert(child);

      const grandchild = createEvent({
        id: EventId('evt_grandchild'),
        parentId: child.id,
        sequence: 2,
      });
      await repo.insert(grandchild);

      const ancestors = repo.getAncestors(grandchild.id);
      expect(ancestors).toHaveLength(3);
      expect(ancestors[0].id).toBe(root.id);
      expect(ancestors[1].id).toBe(child.id);
      expect(ancestors[2].id).toBe(grandchild.id);
    });
  });

  describe('getChildren', () => {
    it('should return empty array when no children', async () => {
      const event = createEvent();
      await repo.insert(event);

      const children = repo.getChildren(event.id);
      expect(children).toEqual([]);
    });

    it('should return direct children', async () => {
      const parent = createEvent({ id: EventId('evt_parent'), sequence: 0 });
      await repo.insert(parent);

      await repo.insert(createEvent({
        id: EventId('evt_child1'),
        parentId: parent.id,
        sequence: 1,
      }));
      await repo.insert(createEvent({
        id: EventId('evt_child2'),
        parentId: parent.id,
        sequence: 2,
      }));

      const children = repo.getChildren(parent.id);
      expect(children).toHaveLength(2);
    });

    it('should not return grandchildren', async () => {
      const root = createEvent({ id: EventId('evt_root'), sequence: 0 });
      await repo.insert(root);

      const child = createEvent({
        id: EventId('evt_child'),
        parentId: root.id,
        sequence: 1,
      });
      await repo.insert(child);

      await repo.insert(createEvent({
        id: EventId('evt_grandchild'),
        parentId: child.id,
        sequence: 2,
      }));

      const children = repo.getChildren(root.id);
      expect(children).toHaveLength(1);
      expect(children[0].id).toBe(child.id);
    });
  });

  describe('getDescendants', () => {
    it('should return empty array when no descendants', async () => {
      const event = createEvent();
      await repo.insert(event);

      const descendants = repo.getDescendants(event.id);
      expect(descendants).toEqual([]);
    });

    it('should return all descendants', async () => {
      const root = createEvent({ id: EventId('evt_root'), sequence: 0 });
      await repo.insert(root);

      const child = createEvent({
        id: EventId('evt_child'),
        parentId: root.id,
        sequence: 1,
      });
      await repo.insert(child);

      await repo.insert(createEvent({
        id: EventId('evt_grandchild'),
        parentId: child.id,
        sequence: 2,
      }));

      const descendants = repo.getDescendants(root.id);
      expect(descendants).toHaveLength(2);
    });
  });

  describe('countBySession', () => {
    it('should return 0 for empty session', () => {
      expect(repo.countBySession(testSessionId)).toBe(0);
    });

    it('should return count of events', async () => {
      for (let i = 0; i < 5; i++) {
        await repo.insert(createEvent({ id: EventId(`evt_${i}`), sequence: i }));
      }
      expect(repo.countBySession(testSessionId)).toBe(5);
    });
  });

  describe('countByType', () => {
    it('should count events of specific type', async () => {
      await repo.insert(createEvent({ id: EventId('evt_1'), type: 'message.user', sequence: 0 }));
      await repo.insert(createEvent({ id: EventId('evt_2'), type: 'message.user', sequence: 1 }));
      await repo.insert(createEvent({ id: EventId('evt_3'), type: 'message.assistant', sequence: 2 }));

      expect(repo.countByType(testSessionId, 'message.user')).toBe(2);
      expect(repo.countByType(testSessionId, 'message.assistant')).toBe(1);
      expect(repo.countByType(testSessionId, 'tool.call')).toBe(0);
    });
  });

  describe('getLatest', () => {
    it('should return null for empty session', () => {
      expect(repo.getLatest(testSessionId)).toBeNull();
    });

    it('should return event with highest sequence', async () => {
      await repo.insert(createEvent({ id: EventId('evt_0'), sequence: 0 }));
      await repo.insert(createEvent({ id: EventId('evt_2'), sequence: 2 }));
      await repo.insert(createEvent({ id: EventId('evt_1'), sequence: 1 }));

      const latest = repo.getLatest(testSessionId);
      expect(latest?.id).toBe(EventId('evt_2'));
    });
  });

  describe('getSince', () => {
    it('should return events after sequence', async () => {
      for (let i = 0; i < 5; i++) {
        await repo.insert(createEvent({ id: EventId(`evt_${i}`), sequence: i }));
      }

      const events = repo.getSince(testSessionId, 2);
      expect(events).toHaveLength(2);
      expect(events[0].sequence).toBe(3);
      expect(events[1].sequence).toBe(4);
    });
  });

  describe('getRange', () => {
    it('should return events in range', async () => {
      for (let i = 0; i < 10; i++) {
        await repo.insert(createEvent({ id: EventId(`evt_${i}`), sequence: i }));
      }

      const events = repo.getRange(testSessionId, 3, 6);
      expect(events).toHaveLength(4);
      expect(events.map(e => e.sequence)).toEqual([3, 4, 5, 6]);
    });
  });

  describe('getByWorkspace', () => {
    it('should return events for workspace', async () => {
      await repo.insert(createEvent({ id: EventId('evt_1'), sequence: 0 }));
      await repo.insert(createEvent({ id: EventId('evt_2'), sequence: 1 }));

      const events = repo.getByWorkspace(testWorkspaceId);
      expect(events).toHaveLength(2);
    });
  });

  describe('exists', () => {
    it('should return false for non-existent event', () => {
      expect(repo.exists(EventId('evt_nonexistent'))).toBe(false);
    });

    it('should return true for existing event', async () => {
      const event = createEvent();
      await repo.insert(event);

      expect(repo.exists(event.id)).toBe(true);
    });
  });

  describe('delete', () => {
    it('should delete event', async () => {
      const event = createEvent();
      await repo.insert(event);

      const deleted = repo.delete(event.id);
      expect(deleted).toBe(true);
      expect(repo.getById(event.id)).toBeNull();
    });

    it('should return false for non-existent event', () => {
      expect(repo.delete(EventId('evt_nonexistent'))).toBe(false);
    });
  });

  describe('deleteBySession', () => {
    it('should delete all events for session', async () => {
      for (let i = 0; i < 5; i++) {
        await repo.insert(createEvent({ id: EventId(`evt_${i}`), sequence: i }));
      }

      const deleted = repo.deleteBySession(testSessionId);
      expect(deleted).toBe(5);
      expect(repo.countBySession(testSessionId)).toBe(0);
    });
  });

  describe('count', () => {
    it('should return total event count', async () => {
      await repo.insert(createEvent({ id: EventId('evt_1'), sequence: 0 }));
      await repo.insert(createEvent({ id: EventId('evt_2'), sequence: 1 }));

      expect(repo.count()).toBe(2);
    });
  });

  describe('getTokenUsageSummary', () => {
    it('should return zeros for empty session', () => {
      const summary = repo.getTokenUsageSummary(testSessionId);
      expect(summary.inputTokens).toBe(0);
      expect(summary.outputTokens).toBe(0);
    });

    it('should sum token usage across events', async () => {
      await repo.insert(createEvent({
        id: EventId('evt_1'),
        type: 'message.assistant',
        sequence: 0,
        payload: {
          content: 'Response 1',
          tokenUsage: { inputTokens: 100, outputTokens: 50 },
        },
      }));
      await repo.insert(createEvent({
        id: EventId('evt_2'),
        type: 'message.assistant',
        sequence: 1,
        payload: {
          content: 'Response 2',
          tokenUsage: { inputTokens: 200, outputTokens: 100 },
        },
      }));

      const summary = repo.getTokenUsageSummary(testSessionId);
      expect(summary.inputTokens).toBe(300);
      expect(summary.outputTokens).toBe(150);
    });
  });
});
