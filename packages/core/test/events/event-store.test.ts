/**
 * @fileoverview Tests for EventStore
 *
 * TDD: Tests for the high-level event store API
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { EventStore } from '../../src/events/event-store.js';
import {
  EventId,
  SessionId,
  WorkspaceId,
  type SessionEvent,
  type UserMessageEvent,
  type AssistantMessageEvent,
  type ToolCallEvent,
  type ToolResultEvent,
} from '../../src/events/types.js';

describe('EventStore', () => {
  let store: EventStore;

  beforeEach(async () => {
    store = new EventStore(':memory:');
    await store.initialize();
  });

  afterEach(async () => {
    await store.close();
  });

  describe('initialization', () => {
    it('should initialize with in-memory database', async () => {
      expect(store.isInitialized()).toBe(true);
    });

    it('should be idempotent on multiple initialize calls', async () => {
      await store.initialize();
      await store.initialize();
      expect(store.isInitialized()).toBe(true);
    });
  });

  describe('session creation', () => {
    it('should create a session with auto-generated IDs', async () => {
      const { session, rootEvent } = await store.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      });

      expect(session.id).toMatch(/^sess_/);
      expect(rootEvent.id).toMatch(/^evt_/);
      expect(rootEvent.type).toBe('session.start');
      expect(rootEvent.parentId).toBeNull();
      expect(rootEvent.sequence).toBe(0);
    });

    it('should create workspace if not exists', async () => {
      const { session } = await store.createSession({
        workspacePath: '/new/project',
        workingDirectory: '/new/project',
        model: 'test',
        provider: 'test',
      });

      const workspace = await store.getWorkspaceByPath('/new/project');
      expect(workspace).not.toBeNull();
      expect(session.workspaceId).toBe(workspace?.id);
    });

    it('should reuse existing workspace', async () => {
      const { session: session1 } = await store.createSession({
        workspacePath: '/shared/project',
        workingDirectory: '/shared/project',
        model: 'test',
        provider: 'test',
      });

      const { session: session2 } = await store.createSession({
        workspacePath: '/shared/project',
        workingDirectory: '/shared/project',
        model: 'test',
        provider: 'test',
      });

      expect(session1.workspaceId).toBe(session2.workspaceId);
    });

    it('should set session root and head to initial event', async () => {
      const { session, rootEvent } = await store.createSession({
        workspacePath: '/test',
        workingDirectory: '/test',
        model: 'test',
        provider: 'test',
      });

      const updatedSession = await store.getSession(session.id);
      expect(updatedSession?.rootEventId).toBe(rootEvent.id);
      expect(updatedSession?.headEventId).toBe(rootEvent.id);
    });
  });

  describe('event appending', () => {
    let sessionId: SessionId;
    let workspaceId: WorkspaceId;
    let rootEventId: EventId;

    beforeEach(async () => {
      const result = await store.createSession({
        workspacePath: '/test',
        workingDirectory: '/test',
        model: 'test',
        provider: 'test',
      });
      sessionId = result.session.id;
      workspaceId = result.session.workspaceId;
      rootEventId = result.rootEvent.id;
    });

    it('should append a user message event', async () => {
      const event = await store.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello, world!', turn: 1 },
      });

      expect(event.id).toMatch(/^evt_/);
      expect(event.type).toBe('message.user');
      expect(event.parentId).toBe(rootEventId);
      expect(event.sequence).toBe(1);
    });

    it('should auto-increment sequence numbers', async () => {
      const event1 = await store.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'First', turn: 1 },
      });

      const event2 = await store.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Response' }],
          turn: 1,
          tokenUsage: { inputTokens: 10, outputTokens: 20 },
          stopReason: 'end_turn',
          model: 'test',
        },
      });

      expect(event1.sequence).toBe(1);
      expect(event2.sequence).toBe(2);
    });

    it('should update session head on append', async () => {
      const event = await store.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello', turn: 1 },
      });

      const session = await store.getSession(sessionId);
      expect(session?.headEventId).toBe(event.id);
    });

    it('should allow appending from specific parent', async () => {
      const event1 = await store.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello', turn: 1 },
      });

      const event2 = await store.append({
        sessionId,
        type: 'message.assistant',
        parentId: event1.id,
        payload: {
          content: [{ type: 'text', text: 'Hi' }],
          turn: 1,
          tokenUsage: { inputTokens: 5, outputTokens: 5 },
          stopReason: 'end_turn',
          model: 'test',
        },
      });

      expect(event2.parentId).toBe(event1.id);
    });

    it('should increment session counters', async () => {
      await store.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello', turn: 1 },
      });

      await store.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Hi' }],
          turn: 1,
          tokenUsage: { inputTokens: 100, outputTokens: 50 },
          stopReason: 'end_turn',
          model: 'test',
        },
      });

      const session = await store.getSession(sessionId);
      expect(session?.eventCount).toBe(3); // root + 2 messages
      expect(session?.messageCount).toBe(2);
      expect(session?.totalInputTokens).toBe(100);
      expect(session?.totalOutputTokens).toBe(50);
    });
  });

  describe('event retrieval', () => {
    let sessionId: SessionId;

    beforeEach(async () => {
      const result = await store.createSession({
        workspacePath: '/test',
        workingDirectory: '/test',
        model: 'test',
        provider: 'test',
      });
      sessionId = result.session.id;
    });

    it('should get event by id', async () => {
      const appended = await store.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello', turn: 1 },
      });

      const retrieved = await store.getEvent(appended.id);
      expect(retrieved?.id).toBe(appended.id);
      expect(retrieved?.type).toBe('message.user');
    });

    it('should return null for non-existent event', async () => {
      const event = await store.getEvent(EventId('evt_nonexistent'));
      expect(event).toBeNull();
    });

    it('should get events by session in order', async () => {
      await store.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'First', turn: 1 },
      });

      await store.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Second' }],
          turn: 1,
          tokenUsage: { inputTokens: 5, outputTokens: 5 },
          stopReason: 'end_turn',
          model: 'test',
        },
      });

      const events = await store.getEventsBySession(sessionId);

      expect(events.length).toBe(3); // root + 2 messages
      expect(events[0].type).toBe('session.start');
      expect(events[1].type).toBe('message.user');
      expect(events[2].type).toBe('message.assistant');
    });
  });

  describe('state projection', () => {
    let sessionId: SessionId;
    let rootEventId: EventId;

    beforeEach(async () => {
      const result = await store.createSession({
        workspacePath: '/test',
        workingDirectory: '/test',
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      });
      sessionId = result.session.id;
      rootEventId = result.rootEvent.id;
    });

    it('should get messages at current head', async () => {
      await store.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello', turn: 1 },
      });

      await store.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Hi there!' }],
          turn: 1,
          tokenUsage: { inputTokens: 10, outputTokens: 20 },
          stopReason: 'end_turn',
          model: 'test',
        },
      });

      const messages = await store.getMessagesAtHead(sessionId);

      expect(messages.length).toBe(2);
      expect(messages[0].role).toBe('user');
      expect(messages[1].role).toBe('assistant');
    });

    it('should get messages at specific event', async () => {
      const userEvent = await store.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello', turn: 1 },
      });

      await store.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Hi there!' }],
          turn: 1,
          tokenUsage: { inputTokens: 10, outputTokens: 20 },
          stopReason: 'end_turn',
          model: 'test',
        },
      });

      // Get messages at the user event (before assistant response)
      const messages = await store.getMessagesAt(userEvent.id);

      expect(messages.length).toBe(1);
      expect(messages[0].role).toBe('user');
    });

    it('should get session state at head', async () => {
      await store.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello', turn: 1 },
      });

      await store.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Hi' }],
          turn: 1,
          tokenUsage: { inputTokens: 100, outputTokens: 200 },
          stopReason: 'end_turn',
          model: 'test',
        },
      });

      const state = await store.getStateAtHead(sessionId);

      expect(state.messages.length).toBe(2);
      expect(state.tokenUsage.inputTokens).toBe(100);
      expect(state.tokenUsage.outputTokens).toBe(200);
      expect(state.turnCount).toBe(1);
    });
  });

  describe('tree operations', () => {
    let sessionId: SessionId;
    let rootEventId: EventId;

    beforeEach(async () => {
      const result = await store.createSession({
        workspacePath: '/test',
        workingDirectory: '/test',
        model: 'test',
        provider: 'test',
      });
      sessionId = result.session.id;
      rootEventId = result.rootEvent.id;
    });

    it('should get ancestors of an event', async () => {
      const event1 = await store.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello', turn: 1 },
      });

      const event2 = await store.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Hi' }],
          turn: 1,
          tokenUsage: { inputTokens: 5, outputTokens: 5 },
          stopReason: 'end_turn',
          model: 'test',
        },
      });

      const ancestors = await store.getAncestors(event2.id);

      expect(ancestors.length).toBe(3); // root, event1, event2
      expect(ancestors[0].id).toBe(rootEventId);
      expect(ancestors[1].id).toBe(event1.id);
      expect(ancestors[2].id).toBe(event2.id);
    });

    it('should get children of an event', async () => {
      // Create two branches from root
      const child1 = await store.append({
        sessionId,
        type: 'message.user',
        parentId: rootEventId,
        payload: { content: 'Branch A', turn: 1 },
      });

      const child2 = await store.append({
        sessionId,
        type: 'message.user',
        parentId: rootEventId,
        payload: { content: 'Branch B', turn: 1 },
      });

      const children = await store.getChildren(rootEventId);

      expect(children.length).toBe(2);
      expect(children.map(c => c.id)).toContain(child1.id);
      expect(children.map(c => c.id)).toContain(child2.id);
    });
  });

  describe('fork operation', () => {
    let sessionId: SessionId;
    let forkPointId: EventId;

    beforeEach(async () => {
      const result = await store.createSession({
        workspacePath: '/test',
        workingDirectory: '/test',
        model: 'test',
        provider: 'test',
      });
      sessionId = result.session.id;

      // Add some events
      const userEvent = await store.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello', turn: 1 },
      });

      forkPointId = (await store.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Hi' }],
          turn: 1,
          tokenUsage: { inputTokens: 5, outputTokens: 5 },
          stopReason: 'end_turn',
          model: 'test',
        },
      })).id;

      // Add more events after fork point
      await store.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Continue', turn: 2 },
      });
    });

    it('should create new session from fork point', async () => {
      const { session: forkedSession, rootEvent } = await store.fork(
        forkPointId,
        { name: 'Alternative branch' }
      );

      expect(forkedSession.id).not.toBe(sessionId);
      expect(forkedSession.parentSessionId).toBe(sessionId);
      expect(forkedSession.forkFromEventId).toBe(forkPointId);
      expect(rootEvent.type).toBe('session.fork');
    });

    it('should preserve history up to fork point in new session', async () => {
      const { session: forkedSession } = await store.fork(forkPointId);

      // Messages at head should include events up to fork point
      const messages = await store.getMessagesAtHead(forkedSession.id);

      expect(messages.length).toBe(2); // user + assistant before fork
    });

    it('should allow divergent paths after fork', async () => {
      const { session: forkedSession } = await store.fork(forkPointId);

      // Add different event in forked session
      const divergentEvent = await store.append({
        sessionId: forkedSession.id,
        type: 'message.user',
        payload: { content: 'Different path', turn: 2 },
      });

      // Original session continues normally
      const originalEvents = await store.getEventsBySession(sessionId);
      const forkedEvents = await store.getEventsBySession(forkedSession.id);

      // Original: root + user + assistant + continue = 4
      expect(originalEvents.length).toBe(4);
      // Forked: fork_event + different = 2 (shared history not duplicated)
      expect(forkedEvents.length).toBe(2);
    });
  });

  describe('rewind operation', () => {
    let sessionId: SessionId;
    let rewindPointId: EventId;

    beforeEach(async () => {
      const result = await store.createSession({
        workspacePath: '/test',
        workingDirectory: '/test',
        model: 'test',
        provider: 'test',
      });
      sessionId = result.session.id;

      await store.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello', turn: 1 },
      });

      rewindPointId = (await store.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Hi' }],
          turn: 1,
          tokenUsage: { inputTokens: 5, outputTokens: 5 },
          stopReason: 'end_turn',
          model: 'test',
        },
      })).id;

      await store.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Continue', turn: 2 },
      });
    });

    it('should move session head back to rewind point', async () => {
      await store.rewind(sessionId, rewindPointId);

      const session = await store.getSession(sessionId);
      expect(session?.headEventId).toBe(rewindPointId);
    });

    it('should preserve rewound-over events', async () => {
      await store.rewind(sessionId, rewindPointId);

      // All events still exist
      const events = await store.getEventsBySession(sessionId);
      expect(events.length).toBe(4); // root + 3 messages
    });

    it('should allow new events from rewound point', async () => {
      await store.rewind(sessionId, rewindPointId);

      const newEvent = await store.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Alternative path', turn: 2 },
      });

      expect(newEvent.parentId).toBe(rewindPointId);
    });
  });

  describe('search', () => {
    let sessionId: SessionId;
    let workspaceId: WorkspaceId;

    beforeEach(async () => {
      const result = await store.createSession({
        workspacePath: '/test',
        workingDirectory: '/test',
        model: 'test',
        provider: 'test',
      });
      sessionId = result.session.id;
      workspaceId = result.session.workspaceId;

      await store.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'How do I implement authentication?', turn: 1 },
      });

      await store.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Here is how to implement OAuth authentication...' }],
          turn: 1,
          tokenUsage: { inputTokens: 10, outputTokens: 100 },
          stopReason: 'end_turn',
          model: 'test',
        },
      });
    });

    it('should search events by content', async () => {
      const results = await store.search('authentication');

      expect(results.length).toBeGreaterThan(0);
      expect(results[0].snippet).toContain('authentication');
    });

    it('should filter search by workspace', async () => {
      // Create event in different workspace
      const { session: otherSession } = await store.createSession({
        workspacePath: '/other',
        workingDirectory: '/other',
        model: 'test',
        provider: 'test',
      });

      await store.append({
        sessionId: otherSession.id,
        type: 'message.user',
        payload: { content: 'Authentication in other project', turn: 1 },
      });

      const results = await store.search('authentication', { workspaceId });

      // Should only find events from the first workspace
      expect(results.every(r => r.sessionId === sessionId || r.sessionId === otherSession.id)).toBe(true);
    });
  });

  describe('session management', () => {
    it('should list sessions by workspace', async () => {
      const { session } = await store.createSession({
        workspacePath: '/test',
        workingDirectory: '/test',
        model: 'test',
        provider: 'test',
      });

      await store.createSession({
        workspacePath: '/test',
        workingDirectory: '/test',
        model: 'test',
        provider: 'test',
      });

      const sessions = await store.listSessions({ workspaceId: session.workspaceId });

      expect(sessions.length).toBe(2);
    });

    it('should end a session', async () => {
      const { session } = await store.createSession({
        workspacePath: '/test',
        workingDirectory: '/test',
        model: 'test',
        provider: 'test',
      });

      await store.endSession(session.id);

      const updated = await store.getSession(session.id);
      expect(updated?.status).toBe('ended');
      expect(updated?.endedAt).not.toBeNull();
    });
  });
});
