/**
 * @fileoverview Tests for EventStore mock factory
 *
 * TDD: Verify that mock factory produces properly typed objects
 */

import { describe, it, expect, vi } from 'vitest';
import {
  createMockEventStore,
  createMockSessionEvent,
  createMockSessionRow,
  createMockCreateSessionResult,
  type MockEventStoreOptions,
} from '../event-store.js';
import type { EventStoreMethods } from '../event-store.js';
import type { SessionEvent, SessionId, EventId, WorkspaceId, Message } from '@infrastructure/events/types.js';

describe('event-store mock factories', () => {
  describe('createMockEventStore', () => {
    it('should create a valid EventStore-like object with defaults', () => {
      const mockStore = createMockEventStore();

      // Should have all required methods
      expect(typeof mockStore.initialize).toBe('function');
      expect(typeof mockStore.close).toBe('function');
      expect(typeof mockStore.isInitialized).toBe('function');
      expect(typeof mockStore.getDatabase).toBe('function');
      expect(typeof mockStore.createSession).toBe('function');
      expect(typeof mockStore.append).toBe('function');
      expect(typeof mockStore.getEvent).toBe('function');
      expect(typeof mockStore.getEventsBySession).toBe('function');
      expect(typeof mockStore.getAncestors).toBe('function');
      expect(typeof mockStore.getChildren).toBe('function');
      expect(typeof mockStore.getMessagesAtHead).toBe('function');
      expect(typeof mockStore.getMessagesAt).toBe('function');
      expect(typeof mockStore.getStateAtHead).toBe('function');
      expect(typeof mockStore.getStateAt).toBe('function');
      expect(typeof mockStore.fork).toBe('function');
      expect(typeof mockStore.search).toBe('function');
      expect(typeof mockStore.getSession).toBe('function');
      expect(typeof mockStore.getSessionsByIds).toBe('function');
      expect(typeof mockStore.listSessions).toBe('function');
      expect(typeof mockStore.getSessionMessagePreviews).toBe('function');
      expect(typeof mockStore.archiveSession).toBe('function');
      expect(typeof mockStore.unarchiveSession).toBe('function');
      expect(typeof mockStore.deleteSession).toBe('function');
      expect(typeof mockStore.updateSessionTitle).toBe('function');
      expect(typeof mockStore.listSessionsWithCount).toBe('function');
      expect(typeof mockStore.updateLatestModel).toBe('function');
      expect(typeof mockStore.deleteMessage).toBe('function');
      expect(typeof mockStore.getWorkspaceByPath).toBe('function');
      expect(typeof mockStore.getDbPath).toBe('function');
      expect(typeof mockStore.updateSessionSpawnInfo).toBe('function');
      expect(typeof mockStore.getLogsForSession).toBe('function');
    });

    it('should have vitest mock functions', () => {
      const mockStore = createMockEventStore();

      expect(vi.isMockFunction(mockStore.initialize)).toBe(true);
      expect(vi.isMockFunction(mockStore.append)).toBe(true);
      expect(vi.isMockFunction(mockStore.getSession)).toBe(true);
    });

    it('should be assignable to EventStoreMethods type', () => {
      // This test verifies TypeScript compatibility at compile time
      const mockStore: EventStoreMethods = createMockEventStore();

      expect(mockStore).toBeDefined();
    });

    it('should return default values for queries', async () => {
      const mockStore = createMockEventStore();

      expect(await mockStore.getSession('sess_123' as SessionId)).toBeNull();
      expect(await mockStore.getEvent('evt_123' as EventId)).toBeNull();
      expect(await mockStore.getEventsBySession('sess_123' as SessionId)).toEqual([]);
      expect(await mockStore.listSessions()).toEqual([]);
      expect(await mockStore.getMessagesAtHead('sess_123' as SessionId)).toEqual([]);
    });

    it('should allow overriding specific methods', async () => {
      const customSession = createMockSessionRow({ id: 'sess_custom' as SessionId });
      const mockStore = createMockEventStore({
        getSession: vi.fn().mockResolvedValue(customSession),
      });

      // Custom override should work
      await expect(mockStore.getSession('sess_123' as SessionId)).resolves.toEqual(customSession);

      // Other methods should still be defaults
      await expect(mockStore.getEvent('evt_123' as EventId)).resolves.toBeNull();
    });

    it('should track appended events', async () => {
      const mockStore = createMockEventStore();

      await mockStore.append({
        sessionId: 'sess_123' as SessionId,
        type: 'message.user',
        payload: { content: 'Hello' },
      });

      // The mock should have been called
      expect(mockStore.append).toHaveBeenCalledTimes(1);
      expect(mockStore.append).toHaveBeenCalledWith({
        sessionId: 'sess_123',
        type: 'message.user',
        payload: { content: 'Hello' },
      });
    });

    it('should return valid event from append', async () => {
      const mockStore = createMockEventStore();

      const event = await mockStore.append({
        sessionId: 'sess_123' as SessionId,
        type: 'message.user',
        payload: { content: 'Hello' },
      });

      expect(event.id).toMatch(/^evt_/);
      expect(event.type).toBe('message.user');
      expect(event.sessionId).toBe('sess_123');
    });

    it('should return valid result from createSession', async () => {
      const mockStore = createMockEventStore();

      const result = await mockStore.createSession({
        workspacePath: '/project',
        workingDirectory: '/project/src',
        model: 'claude-3',
      });

      expect(result.session).toBeDefined();
      expect(result.session.id).toMatch(/^sess_/);
      expect(result.session.workingDirectory).toBe('/project/src');
      expect(result.rootEvent).toBeDefined();
      expect(result.rootEvent.id).toMatch(/^evt_/);
    });

    it('should return dbPath from getDbPath', () => {
      const mockStore = createMockEventStore({ dbPath: '/custom/path.db' });

      expect(mockStore.getDbPath()).toBe('/custom/path.db');
    });

    it('should return isInitialized state', () => {
      const mockStoreNotInit = createMockEventStore({ initialized: false });
      const mockStoreInit = createMockEventStore({ initialized: true });

      expect(mockStoreNotInit.isInitialized()).toBe(false);
      expect(mockStoreInit.isInitialized()).toBe(true);
    });
  });

  describe('createMockSessionEvent', () => {
    it('should create a valid SessionEvent with defaults', () => {
      const event = createMockSessionEvent();

      expect(event.id).toMatch(/^evt_/);
      expect(event.sessionId).toMatch(/^sess_/);
      expect(event.workspaceId).toMatch(/^ws_/);
      expect(event.type).toBe('message.user');
      expect(typeof event.sequence).toBe('number');
      expect(event.timestamp).toBeDefined();
      expect(event.payload).toBeDefined();
    });

    it('should allow overriding event properties', () => {
      const event = createMockSessionEvent({
        id: 'evt_custom' as EventId,
        type: 'message.assistant',
        payload: { content: [{ type: 'text', text: 'Hello' }] },
      });

      expect(event.id).toBe('evt_custom');
      expect(event.type).toBe('message.assistant');
      expect(event.payload).toEqual({ content: [{ type: 'text', text: 'Hello' }] });
    });

    it('should set parentId when provided', () => {
      const event = createMockSessionEvent({
        parentId: 'evt_parent' as EventId,
      });

      expect(event.parentId).toBe('evt_parent');
    });

    it('should be assignable to SessionEvent type', () => {
      const event: SessionEvent = createMockSessionEvent();

      expect(event).toBeDefined();
    });
  });

  describe('createMockSessionRow', () => {
    it('should create a valid SessionRow with defaults', () => {
      const session = createMockSessionRow();

      expect(session.id).toMatch(/^sess_/);
      expect(session.workspaceId).toMatch(/^ws_/);
      expect(session.workingDirectory).toBeDefined();
      expect(session.latestModel).toBeDefined();
      expect(session.isArchived).toBe(false);
      expect(session.eventCount).toBe(0);
      expect(session.messageCount).toBe(0);
    });

    it('should allow overriding session properties', () => {
      const session = createMockSessionRow({
        id: 'sess_custom' as SessionId,
        isArchived: true,
        eventCount: 10,
        latestModel: 'gpt-4',
      });

      expect(session.id).toBe('sess_custom');
      expect(session.isArchived).toBe(true);
      expect(session.eventCount).toBe(10);
      expect(session.latestModel).toBe('gpt-4');
    });
  });

  describe('createMockCreateSessionResult', () => {
    it('should create a valid CreateSessionResult', () => {
      const result = createMockCreateSessionResult();

      expect(result.session).toBeDefined();
      expect(result.session.id).toMatch(/^sess_/);
      expect(result.rootEvent).toBeDefined();
      expect(result.rootEvent.id).toMatch(/^evt_/);
      expect(result.rootEvent.type).toBe('session.start');
    });

    it('should allow overriding session and event', () => {
      const result = createMockCreateSessionResult({
        session: { latestModel: 'claude-3' },
        rootEvent: { id: 'evt_root' as EventId },
      });

      expect(result.session.latestModel).toBe('claude-3');
      expect(result.rootEvent.id).toBe('evt_root');
    });
  });

  describe('event tracking', () => {
    it('should track appended events when trackEvents is true', async () => {
      const mockStore = createMockEventStore({ trackEvents: true });

      await mockStore.append({
        sessionId: 'sess_1' as SessionId,
        type: 'message.user',
        payload: { content: 'Hello' },
      });

      await mockStore.append({
        sessionId: 'sess_1' as SessionId,
        type: 'message.assistant',
        payload: { content: [{ type: 'text', text: 'Hi' }] },
      });

      expect(mockStore.events).toHaveLength(2);
      expect(mockStore.events[0].type).toBe('message.user');
      expect(mockStore.events[1].type).toBe('message.assistant');
    });

    it('should allow clearing tracked events', async () => {
      const mockStore = createMockEventStore({ trackEvents: true });

      await mockStore.append({
        sessionId: 'sess_1' as SessionId,
        type: 'message.user',
        payload: { content: 'Hello' },
      });

      expect(mockStore.events).toHaveLength(1);

      mockStore.clearEvents();

      expect(mockStore.events).toHaveLength(0);
    });

    it('should find events by type', async () => {
      const mockStore = createMockEventStore({ trackEvents: true });

      await mockStore.append({
        sessionId: 'sess_1' as SessionId,
        type: 'worktree.acquired',
        payload: { path: '/test', isolated: false },
      });

      await mockStore.append({
        sessionId: 'sess_1' as SessionId,
        type: 'message.user',
        payload: { content: 'Hello' },
      });

      const acquiredEvent = mockStore.events.find(e => e.type === 'worktree.acquired');
      expect(acquiredEvent).toBeDefined();
      expect(acquiredEvent?.payload).toMatchObject({ path: '/test', isolated: false });
    });
  });

  describe('integration with vitest mocking', () => {
    it('should work with vi.mocked pattern', async () => {
      const mockStore = createMockEventStore();

      // Mock specific return values
      const customEvent = createMockSessionEvent({ type: 'tool.call' });
      vi.mocked(mockStore.getEvent).mockResolvedValueOnce(customEvent);

      const event = await mockStore.getEvent('evt_123' as EventId);
      expect(event?.type).toBe('tool.call');
    });

    it('should allow mocking createSession with custom result', async () => {
      const mockStore = createMockEventStore();

      const customResult = createMockCreateSessionResult({
        session: { id: 'sess_test' as SessionId, latestModel: 'test-model' },
      });
      vi.mocked(mockStore.createSession).mockResolvedValueOnce(customResult);

      const result = await mockStore.createSession({
        workspacePath: '/test',
        workingDirectory: '/test',
        model: 'test-model',
      });

      expect(result.session.id).toBe('sess_test');
    });
  });
});
