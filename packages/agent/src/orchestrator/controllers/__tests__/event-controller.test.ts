/**
 * @fileoverview EventController Tests
 *
 * Tests for the EventController which consolidates all event query and mutation
 * operations with proper linearization for active sessions.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { EventStore } from '../../../events/event-store.js';
import type {
  SessionId,
  EventId,
  SessionEvent,
  WorkspaceId,
  EventType,
} from '../../../events/types.js';
import {
  EventController,
  createEventController,
  type EventControllerConfig,
} from '../event-controller.js';
import type { ActiveSession } from '../../types.js';
import { SessionContext, createSessionContext } from '../../session/session-context.js';
import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';

describe('EventController', () => {
  let eventStore: EventStore;
  let controller: EventController;
  let dbPath: string;
  let activeSessions: Map<string, ActiveSession>;
  let emittedEvents: Array<{ event: string; data: unknown }>;

  beforeEach(async () => {
    // Create temp database
    const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), 'event-controller-test-'));
    dbPath = path.join(tempDir, 'test.db');

    eventStore = new EventStore(dbPath);
    await eventStore.initialize();

    activeSessions = new Map();
    emittedEvents = [];

    controller = createEventController({
      eventStore,
      getActiveSession: (sessionId: string) => activeSessions.get(sessionId),
      getAllActiveSessions: () => activeSessions.entries(),
      onEventCreated: (event, sessionId) => {
        emittedEvents.push({ event: 'event_new', data: { event, sessionId } });
      },
    });
  });

  afterEach(async () => {
    await eventStore.close();
    // Clean up temp directory
    try {
      await fs.rm(path.dirname(dbPath), { recursive: true });
    } catch {
      // Ignore cleanup errors
    }
  });

  // ===========================================================================
  // Helper Functions
  // ===========================================================================

  async function createTestSession(): Promise<{ sessionId: SessionId; rootEventId: EventId }> {
    const { session, rootEvent } = await eventStore.createSession({
      workspacePath: '/tmp/test',
      workingDirectory: '/tmp/test',
      model: 'claude-sonnet-4-20250514',
    });
    return {
      sessionId: session.id,
      rootEventId: rootEvent.id,
    };
  }

  function createMockActiveSession(
    sessionId: SessionId,
    headEventId: EventId
  ): ActiveSession {
    const sessionContext = createSessionContext({
      sessionId,
      eventStore,
      initialHeadEventId: headEventId,
      model: 'claude-sonnet-4-20250514',
      workingDirectory: '/tmp/test',
    });

    return {
      sessionId,
      agent: {} as any,
      contextManager: {} as any,
      sessionContext,
      skillTracker: new Map(),
      subagentTracker: {} as any,
      workingDir: undefined,
      lastActivity: new Date(),
    };
  }

  // ===========================================================================
  // Query Operations
  // ===========================================================================

  describe('getState', () => {
    it('returns session state at head', async () => {
      const { sessionId } = await createTestSession();

      const state = await controller.getState(sessionId);

      expect(state).toBeDefined();
      expect(state.model).toBe('claude-sonnet-4-20250514');
    });

    it('returns session state at specific event', async () => {
      const { sessionId, rootEventId } = await createTestSession();

      // Append some events
      const event1 = await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello' },
        parentId: rootEventId,
      });

      await eventStore.append({
        sessionId,
        type: 'config.model_switch',
        payload: { model: 'claude-opus-4-20250514', previousModel: 'claude-sonnet-4-20250514' },
        parentId: event1.id,
      });

      // Get state at first event (before model switch)
      const stateAtEvent1 = await controller.getState(sessionId, event1.id);
      expect(stateAtEvent1.model).toBe('claude-sonnet-4-20250514');
    });
  });

  describe('getMessages', () => {
    it('returns messages at head', async () => {
      const { sessionId, rootEventId } = await createTestSession();

      // Append user message
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello' },
        parentId: rootEventId,
      });

      const messages = await controller.getMessages(sessionId);

      expect(messages).toHaveLength(1);
      expect(messages[0].role).toBe('user');
    });

    it('returns messages at specific event', async () => {
      const { sessionId, rootEventId } = await createTestSession();

      const event1 = await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'First' },
        parentId: rootEventId,
      });

      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Second' },
        parentId: event1.id,
      });

      // Get messages at first event
      const messagesAtEvent1 = await controller.getMessages(sessionId, event1.id);
      expect(messagesAtEvent1).toHaveLength(1);
      expect(messagesAtEvent1[0].content).toBe('First');
    });
  });

  describe('getEvents', () => {
    it('returns all events for a session', async () => {
      const { sessionId, rootEventId } = await createTestSession();

      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello' },
        parentId: rootEventId,
      });

      const events = await controller.getEvents(sessionId);

      // Should have root + user message
      expect(events.length).toBeGreaterThanOrEqual(2);
    });
  });

  describe('getAncestors', () => {
    it('returns ancestor chain for an event', async () => {
      const { sessionId, rootEventId } = await createTestSession();

      const event1 = await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'First' },
        parentId: rootEventId,
      });

      const event2 = await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Second' },
        parentId: event1.id,
      });

      const ancestors = await controller.getAncestors(event2.id);

      // Should include root, event1, event2 (in order from root to event)
      expect(ancestors.length).toBeGreaterThanOrEqual(3);
      // Last element should be the event we asked for
      expect(ancestors[ancestors.length - 1].id).toBe(event2.id);
    });
  });

  describe('search', () => {
    it('searches events by query', async () => {
      const { sessionId, rootEventId } = await createTestSession();

      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'searchable content here' },
        parentId: rootEventId,
      });

      const results = await controller.search('searchable');

      expect(results.length).toBeGreaterThanOrEqual(1);
    });

    it('filters by session ID', async () => {
      const { sessionId: session1, rootEventId: root1 } = await createTestSession();
      const { sessionId: session2, rootEventId: root2 } = await createTestSession();

      await eventStore.append({
        sessionId: session1,
        type: 'message.user',
        payload: { content: 'unique1 content' },
        parentId: root1,
      });

      await eventStore.append({
        sessionId: session2,
        type: 'message.user',
        payload: { content: 'unique2 content' },
        parentId: root2,
      });

      const results = await controller.search('unique1', { sessionId: session1 });

      expect(results.length).toBeGreaterThanOrEqual(1);
      results.forEach(r => {
        expect(r.sessionId).toBe(session1);
      });
    });
  });

  // ===========================================================================
  // Mutation Operations - Inactive Sessions
  // ===========================================================================

  describe('append (inactive session)', () => {
    it('appends event directly for inactive session', async () => {
      const { sessionId, rootEventId } = await createTestSession();

      const event = await controller.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello' },
        parentId: rootEventId,
      });

      expect(event).toBeDefined();
      expect(event.type).toBe('message.user');
      expect(event.parentId).toBe(rootEventId);
    });

    it('emits event_new for appended event', async () => {
      const { sessionId, rootEventId } = await createTestSession();

      await controller.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello' },
        parentId: rootEventId,
      });

      expect(emittedEvents).toHaveLength(1);
      expect(emittedEvents[0].event).toBe('event_new');
    });
  });

  // ===========================================================================
  // Mutation Operations - Active Sessions (Linearization)
  // ===========================================================================

  describe('append (active session with linearization)', () => {
    it('uses SessionContext for linearized append', async () => {
      const { sessionId, rootEventId } = await createTestSession();

      // Create active session
      const active = createMockActiveSession(sessionId, rootEventId);
      activeSessions.set(sessionId, active);

      // Append via controller (should use linearization)
      const event = await controller.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello' },
      });

      expect(event).toBeDefined();
      expect(event.type).toBe('message.user');

      // Verify event is chained from root
      expect(event.parentId).toBe(rootEventId);
    });

    it('maintains linear chain with sequential appends', async () => {
      const { sessionId, rootEventId } = await createTestSession();

      // Create active session
      const active = createMockActiveSession(sessionId, rootEventId);
      activeSessions.set(sessionId, active);

      // Append events sequentially
      const event1 = await controller.append({
        sessionId,
        type: 'message.user',
        payload: { content: '1' },
      });
      const event2 = await controller.append({
        sessionId,
        type: 'message.user',
        payload: { content: '2' },
      });
      const event3 = await controller.append({
        sessionId,
        type: 'message.user',
        payload: { content: '3' },
      });

      // Verify linear chain: root -> event1 -> event2 -> event3
      expect(event1.parentId).toBe(rootEventId);
      expect(event2.parentId).toBe(event1.id);
      expect(event3.parentId).toBe(event2.id);

      // Verify pending head is updated
      expect(active.sessionContext.getPendingHeadEventId()).toBe(event3.id);
    });

    it('updates pending head after append', async () => {
      const { sessionId, rootEventId } = await createTestSession();

      const active = createMockActiveSession(sessionId, rootEventId);
      activeSessions.set(sessionId, active);

      const event = await controller.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello' },
      });

      // The session context should have updated pending head
      expect(active.sessionContext.getPendingHeadEventId()).toBe(event.id);
    });
  });

  // ===========================================================================
  // Delete Message
  // ===========================================================================

  describe('deleteMessage', () => {
    it('deletes message for inactive session', async () => {
      const { sessionId, rootEventId } = await createTestSession();

      const msg = await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'To delete' },
        parentId: rootEventId,
      });

      const deleteEvent = await controller.deleteMessage(sessionId, msg.id, 'user_request');

      expect(deleteEvent).toBeDefined();
      expect(deleteEvent.type).toBe('message.deleted');
      expect((deleteEvent.payload as any).targetEventId).toBe(msg.id);
    });

    it('deletes message for active session with linearization', async () => {
      const { sessionId, rootEventId } = await createTestSession();

      const msg = await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'To delete' },
        parentId: rootEventId,
      });

      // Create active session
      const active = createMockActiveSession(sessionId, msg.id);
      activeSessions.set(sessionId, active);

      const deleteEvent = await controller.deleteMessage(sessionId, msg.id, 'user_request');

      expect(deleteEvent).toBeDefined();
      expect(deleteEvent.type).toBe('message.deleted');

      // Should be chained from the active session's pending head
      expect(deleteEvent.parentId).toBe(msg.id);
    });

    it('emits event_new for delete event', async () => {
      const { sessionId, rootEventId } = await createTestSession();

      const msg = await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'To delete' },
        parentId: rootEventId,
      });

      emittedEvents = []; // Reset

      await controller.deleteMessage(sessionId, msg.id);

      expect(emittedEvents).toHaveLength(1);
      expect(emittedEvents[0].event).toBe('event_new');
    });
  });

  // ===========================================================================
  // Flush Operations
  // ===========================================================================

  describe('flush', () => {
    it('flushes pending events for active session', async () => {
      const { sessionId, rootEventId } = await createTestSession();

      const active = createMockActiveSession(sessionId, rootEventId);
      activeSessions.set(sessionId, active);

      // Fire-and-forget append
      active.sessionContext.appendEventFireAndForget('message.user', { content: 'Hello' });

      // Flush should wait for pending appends
      await controller.flush(sessionId);

      // Verify event was persisted
      const events = await controller.getEvents(sessionId);
      const userMessages = events.filter(e => e.type === 'message.user');
      expect(userMessages.length).toBeGreaterThanOrEqual(1);
    });

    it('does nothing for inactive session', async () => {
      const { sessionId } = await createTestSession();

      // Should not throw
      await controller.flush(sessionId);
    });
  });

  describe('flushAll', () => {
    it('flushes all active sessions', async () => {
      const { sessionId: s1, rootEventId: r1 } = await createTestSession();
      const { sessionId: s2, rootEventId: r2 } = await createTestSession();

      const active1 = createMockActiveSession(s1, r1);
      const active2 = createMockActiveSession(s2, r2);

      activeSessions.set(s1, active1);
      activeSessions.set(s2, active2);

      // Fire-and-forget appends
      active1.sessionContext.appendEventFireAndForget('message.user', { content: 'Hello 1' });
      active2.sessionContext.appendEventFireAndForget('message.user', { content: 'Hello 2' });

      // Flush all
      await controller.flushAll();

      // Verify both events were persisted
      const events1 = await controller.getEvents(s1);
      const events2 = await controller.getEvents(s2);

      expect(events1.some(e => e.type === 'message.user')).toBe(true);
      expect(events2.some(e => e.type === 'message.user')).toBe(true);
    });
  });

  // ===========================================================================
  // Error Handling
  // ===========================================================================

  describe('error handling', () => {
    it('throws for append with active session when linearization fails', async () => {
      const { sessionId, rootEventId } = await createTestSession();

      const active = createMockActiveSession(sessionId, rootEventId);
      activeSessions.set(sessionId, active);

      // Force an error in sessionContext by closing the event store
      await eventStore.close();

      await expect(
        controller.append({
          sessionId,
          type: 'message.user',
          payload: { content: 'Will fail' },
        })
      ).rejects.toThrow();
    });
  });
});
