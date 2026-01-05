/**
 * @fileoverview Integration tests for EventStore in SessionOrchestrator
 *
 * These tests verify that the orchestrator correctly uses EventStore for:
 * - Session creation and management
 * - Event appending and retrieval
 * - Tree operations (fork, rewind)
 * - Event broadcasting
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { EventStore, EventId, SessionId } from '@tron/core';
import path from 'path';
import os from 'os';
import fs from 'fs';

describe('EventStore Integration', () => {
  let eventStore: EventStore;
  let testDir: string;

  beforeEach(async () => {
    // Create temp directory for test database
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tron-eventstore-test-'));
    const dbPath = path.join(testDir, 'events.db');

    eventStore = new EventStore(dbPath);
    await eventStore.initialize();
  });

  afterEach(async () => {
    await eventStore.close();
    // Clean up temp directory
    fs.rmSync(testDir, { recursive: true, force: true });
  });

  describe('session lifecycle', () => {
    it('should create a session with root event', async () => {
      const result = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
        title: 'Test Session',
      });

      expect(result.session.id).toMatch(/^sess_/);
      expect(result.rootEvent.id).toMatch(/^evt_/);
      expect(result.rootEvent.type).toBe('session.start');
      expect(result.rootEvent.parentId).toBeNull();
    });

    it('should record session metadata in start event', async () => {
      const result = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
        title: 'Test Session',
        tags: ['test', 'integration'],
      });

      expect(result.rootEvent.payload).toEqual({
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
        title: 'Test Session',
      });
    });

    it('should get session by ID', async () => {
      const created = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      });

      const session = await eventStore.getSession(created.session.id);
      expect(session).not.toBeNull();
      expect(session?.id).toBe(created.session.id);
    });

    it('should list sessions by workspace', async () => {
      // Create sessions in different workspaces
      await eventStore.createSession({
        workspacePath: '/project-a',
        workingDirectory: '/project-a',
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      });

      await eventStore.createSession({
        workspacePath: '/project-b',
        workingDirectory: '/project-b',
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      });

      const workspace = await eventStore.getWorkspaceByPath('/project-a');
      expect(workspace).not.toBeNull();

      const allSessions = await eventStore.listSessions({});
      expect(allSessions.length).toBe(2);
    });

    it('should end a session', async () => {
      const created = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      });

      await eventStore.endSession(created.session.id);

      const session = await eventStore.getSession(created.session.id);
      expect(session?.status).toBe('ended');
    });
  });

  describe('event recording', () => {
    let sessionId: SessionId;
    let rootEventId: EventId;

    beforeEach(async () => {
      const result = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      });
      sessionId = result.session.id;
      rootEventId = result.rootEvent.id;
    });

    it('should append user message event', async () => {
      const event = await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: {
          content: 'Hello, world!',
        },
      });

      expect(event.type).toBe('message.user');
      expect(event.parentId).toBe(rootEventId);
      expect(event.sequence).toBe(1);
    });

    it('should append assistant message event with token usage', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello' },
      });

      const assistantEvent = await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: 'Hi there!',
          tokenUsage: { inputTokens: 100, outputTokens: 50 },
        },
      });

      expect(assistantEvent.type).toBe('message.assistant');
      expect(assistantEvent.sequence).toBe(2);
    });

    it('should append tool call and result events', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Read the README' },
      });

      const toolCallEvent = await eventStore.append({
        sessionId,
        type: 'tool.call',
        payload: {
          toolCallId: 'tc_123',
          toolName: 'read',
          arguments: { path: 'README.md' },
        },
      });

      const toolResultEvent = await eventStore.append({
        sessionId,
        type: 'tool.result',
        payload: {
          toolCallId: 'tc_123',
          toolName: 'read',
          result: '# README\n\nThis is a test.',
          isError: false,
        },
      });

      expect(toolCallEvent.type).toBe('tool.call');
      expect(toolResultEvent.type).toBe('tool.result');
      expect(toolResultEvent.parentId).toBe(toolCallEvent.id);
    });

    it('should track session counters', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello' },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: { content: 'Hi!', tokenUsage: { inputTokens: 50, outputTokens: 25 } },
      });

      const session = await eventStore.getSession(sessionId);
      expect(session?.eventCount).toBe(3); // root + 2 messages
      expect(session?.messageCount).toBe(2);
    });

    it('should update session head on append', async () => {
      const event1 = await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'First message' },
      });

      let session = await eventStore.getSession(sessionId);
      expect(session?.headEventId).toBe(event1.id);

      const event2 = await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: { content: 'Response' },
      });

      session = await eventStore.getSession(sessionId);
      expect(session?.headEventId).toBe(event2.id);
    });
  });

  describe('state reconstruction', () => {
    let sessionId: SessionId;

    beforeEach(async () => {
      const result = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      });
      sessionId = result.session.id;
    });

    it('should reconstruct messages from events', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello' },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: { content: 'Hi there!' },
      });

      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'How are you?' },
      });

      const messages = await eventStore.getMessagesAtHead(sessionId);
      expect(messages.length).toBe(3);
      expect(messages[0]).toEqual({ role: 'user', content: 'Hello' });
      expect(messages[1]).toEqual({ role: 'assistant', content: 'Hi there!' });
      expect(messages[2]).toEqual({ role: 'user', content: 'How are you?' });
    });

    it('should reconstruct state at head', async () => {
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello' },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: {
          content: 'Hi there!',
          tokenUsage: { inputTokens: 100, outputTokens: 50 },
        },
      });

      const state = await eventStore.getStateAtHead(sessionId);
      expect(state.messages.length).toBe(2);
      expect(state.tokenUsage.inputTokens).toBe(100);
      expect(state.tokenUsage.outputTokens).toBe(50);
      expect(state.model).toBe('claude-sonnet-4-20250514');
    });

    it('should reconstruct state at specific event', async () => {
      const event1 = await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'First' },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: { content: 'Response 1' },
      });

      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Second' },
      });

      // Get state at first event (before assistant response)
      const stateAtFirst = await eventStore.getStateAt(event1.id);
      expect(stateAtFirst.messages.length).toBe(1);
      expect(stateAtFirst.messages[0].content).toBe('First');
    });
  });

  describe('tree navigation', () => {
    let sessionId: SessionId;
    let eventIds: EventId[] = [];

    beforeEach(async () => {
      const result = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      });
      sessionId = result.session.id;
      eventIds = [result.rootEvent.id];

      // Create a chain of events
      for (let i = 0; i < 5; i++) {
        const event = await eventStore.append({
          sessionId,
          type: i % 2 === 0 ? 'message.user' : 'message.assistant',
          payload: { content: `Message ${i}` },
        });
        eventIds.push(event.id);
      }
    });

    it('should get ancestors of an event', async () => {
      const lastEventId = eventIds[eventIds.length - 1];
      const ancestors = await eventStore.getAncestors(lastEventId);

      expect(ancestors.length).toBe(6); // Including the event itself
      expect(ancestors[0].id).toBe(eventIds[0]); // First is root
    });

    it('should get children of an event', async () => {
      const rootEventId = eventIds[0];
      const children = await eventStore.getChildren(rootEventId);

      expect(children.length).toBe(1); // Only first message
      expect(children[0].id).toBe(eventIds[1]);
    });

    it('should identify branch points', async () => {
      const thirdEventId = eventIds[3];

      // Append from a different point (creating a branch)
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Branch message' },
        parentId: thirdEventId,
      });

      const children = await eventStore.getChildren(thirdEventId);
      expect(children.length).toBe(2); // Original continuation + branch
    });
  });

  describe('fork operation', () => {
    let sessionId: SessionId;
    let forkPointEventId: EventId;

    beforeEach(async () => {
      const result = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      });
      sessionId = result.session.id;

      // Create conversation
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Hello' },
      });

      const assistantEvent = await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: { content: 'Hi there!' },
      });
      forkPointEventId = assistantEvent.id;

      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Continue this way' },
      });
    });

    it('should create new session from fork point', async () => {
      const forkResult = await eventStore.fork(forkPointEventId, {
        name: 'Alternative approach',
      });

      expect(forkResult.session.id).not.toBe(sessionId);
      expect(forkResult.rootEvent.type).toBe('session.fork');
      expect(forkResult.rootEvent.parentId).toBe(forkPointEventId);
    });

    it('should preserve history in forked session', async () => {
      const forkResult = await eventStore.fork(forkPointEventId);

      // Get messages at head of forked session
      const messages = await eventStore.getMessagesAt(forkResult.rootEvent.id);
      expect(messages.length).toBe(2); // User + Assistant messages before fork
    });

    it('should allow divergent paths after fork', async () => {
      const forkResult = await eventStore.fork(forkPointEventId);

      // Verify fork created correctly
      expect(forkResult.session.id).not.toBe(sessionId);
      expect(forkResult.rootEvent.parentId).toBe(forkPointEventId);

      // Add to original session
      const originalAppend = await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Original path' },
      });

      // Add to forked session
      const forkedAppend = await eventStore.append({
        sessionId: forkResult.session.id,
        type: 'message.user',
        payload: { content: 'Forked path' },
      });

      // Verify session heads are updated correctly
      const originalSession = await eventStore.getSession(sessionId);
      const forkedSession = await eventStore.getSession(forkResult.session.id);
      expect(originalSession?.headEventId).toBe(originalAppend.id);
      expect(forkedSession?.headEventId).toBe(forkedAppend.id);

      // Get messages
      const originalMessages = await eventStore.getMessagesAtHead(sessionId);
      const forkedMessages = await eventStore.getMessagesAtHead(forkResult.session.id);

      // Original: Hello, Hi, Continue, Original = 4
      expect(originalMessages.length).toBe(4);
      expect(originalMessages.map(m => m.content)).toEqual([
        'Hello', 'Hi there!', 'Continue this way', 'Original path'
      ]);

      // Forked: Hello, Hi, Forked = 3 (skips Continue, which was after fork point)
      expect(forkedMessages.length).toBe(3);
      expect(forkedMessages.map(m => m.content)).toEqual([
        'Hello', 'Hi there!', 'Forked path'
      ]);
    });
  });

  describe('rewind operation', () => {
    let sessionId: SessionId;
    let eventIds: EventId[] = [];

    beforeEach(async () => {
      const result = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      });
      sessionId = result.session.id;
      eventIds = [result.rootEvent.id];

      // Create conversation
      for (const msg of ['Hello', 'Hi!', 'How are you?', 'Good, thanks!']) {
        const event = await eventStore.append({
          sessionId,
          type: eventIds.length % 2 === 1 ? 'message.user' : 'message.assistant',
          payload: { content: msg },
        });
        eventIds.push(event.id);
      }
    });

    it('should move head back to rewind point', async () => {
      const rewindToId = eventIds[2]; // After "Hi!"

      await eventStore.rewind(sessionId, rewindToId);

      const session = await eventStore.getSession(sessionId);
      expect(session?.headEventId).toBe(rewindToId);
    });

    it('should preserve rewound-over events', async () => {
      const rewindToId = eventIds[2];

      await eventStore.rewind(sessionId, rewindToId);

      // Events still exist
      const event = await eventStore.getEvent(eventIds[4]);
      expect(event).not.toBeNull();
    });

    it('should show fewer messages after rewind', async () => {
      const rewindToId = eventIds[2];

      await eventStore.rewind(sessionId, rewindToId);

      const messages = await eventStore.getMessagesAtHead(sessionId);
      expect(messages.length).toBe(2); // Just Hello and Hi!
    });

    it('should allow new events from rewound point', async () => {
      const rewindToId = eventIds[2];

      await eventStore.rewind(sessionId, rewindToId);

      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'New direction' },
      });

      const messages = await eventStore.getMessagesAtHead(sessionId);
      expect(messages.length).toBe(3);
      expect(messages[2].content).toBe('New direction');
    });
  });

  describe('search', () => {
    let sessionId: SessionId;

    beforeEach(async () => {
      const result = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      });
      sessionId = result.session.id;

      // Create searchable content
      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Help me with authentication' },
      });

      await eventStore.append({
        sessionId,
        type: 'message.assistant',
        payload: { content: 'I can help you implement OAuth2 authentication' },
      });

      await eventStore.append({
        sessionId,
        type: 'message.user',
        payload: { content: 'Show me database queries' },
      });
    });

    it('should find events by content', async () => {
      const results = await eventStore.search('authentication');
      expect(results.length).toBeGreaterThanOrEqual(1);
    });

    it('should filter by session', async () => {
      const results = await eventStore.search('authentication', { sessionId });
      expect(results.length).toBeGreaterThanOrEqual(1);
      expect(results.every(r => r.sessionId === sessionId)).toBe(true);
    });

    it('should filter by event type', async () => {
      const results = await eventStore.search('authentication', {
        types: ['message.user'],
      });
      expect(results.every(r => r.type === 'message.user')).toBe(true);
    });
  });

  describe('performance', () => {
    it('should handle many events efficiently', async () => {
      const result = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      });
      const sessionId = result.session.id;

      // Add 100 events
      const startTime = Date.now();
      for (let i = 0; i < 100; i++) {
        await eventStore.append({
          sessionId,
          type: i % 2 === 0 ? 'message.user' : 'message.assistant',
          payload: { content: `Message ${i}: Lorem ipsum dolor sit amet` },
        });
      }
      const appendTime = Date.now() - startTime;

      // Reconstruct state
      const stateStart = Date.now();
      const state = await eventStore.getStateAtHead(sessionId);
      const stateTime = Date.now() - stateStart;

      expect(state.messages.length).toBe(100);
      expect(appendTime).toBeLessThan(5000); // 5 seconds max
      expect(stateTime).toBeLessThan(1000); // 1 second max for state reconstruction
    });

    it('should handle deep ancestor chains', async () => {
      const result = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
      });
      const sessionId = result.session.id;

      // Create deep chain
      let lastEventId: EventId | null = null;
      for (let i = 0; i < 50; i++) {
        const event = await eventStore.append({
          sessionId,
          type: 'message.user',
          payload: { content: `Deep message ${i}` },
        });
        lastEventId = event.id;
      }

      // Get all ancestors
      const startTime = Date.now();
      const ancestors = await eventStore.getAncestors(lastEventId!);
      const ancestorTime = Date.now() - startTime;

      expect(ancestors.length).toBe(51); // 50 messages + root
      expect(ancestorTime).toBeLessThan(500); // 500ms max
    });
  });
});
