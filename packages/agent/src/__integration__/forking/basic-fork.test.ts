/**
 * @fileoverview Fork Integration Tests - Basic Operations
 *
 * Tests the fundamental fork operations:
 * - Fork from any event in the chain
 * - History preservation in forked session
 * - Independent mutation after fork
 * - Parent chain integrity
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { EventStore, SessionId, EventId } from '../../index.js';
import path from 'path';
import os from 'os';
import fs from 'fs';

describe('Fork Integration - Basic Operations', () => {
  let eventStore: EventStore;
  let testDir: string;

  beforeEach(async () => {
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tron-fork-test-'));
    const dbPath = path.join(testDir, 'events.db');
    eventStore = new EventStore(dbPath);
    await eventStore.initialize();
  });

  afterEach(async () => {
    await eventStore.close();
    fs.rmSync(testDir, { recursive: true, force: true });
  });

  describe('fork creation', () => {
    it('should create fork from head event', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      // Add some events
      const msg1 = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'Hello' },
        parentId: rootEvent.id,
      });

      const msg2 = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Hi there!' }],
          usage: { inputTokens: 5, outputTokens: 3 },
        },
        parentId: msg1.id,
      });

      // Fork from head (msg2)
      const forkResult = await eventStore.fork(msg2.id, { name: 'Fork Test' });

      expect(forkResult.session).toBeDefined();
      expect(forkResult.session.id).toMatch(/^sess_/);
      expect(forkResult.session.id).not.toBe(session.id);
      expect(forkResult.rootEvent).toBeDefined();
      expect(forkResult.rootEvent.parentId).toBe(msg2.id);
    });

    it('should create fork from mid-conversation event', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const msg1 = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'First message' },
        parentId: rootEvent.id,
      });

      const msg2 = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'First response' }],
          usage: { inputTokens: 10, outputTokens: 8 },
        },
        parentId: msg1.id,
      });

      const msg3 = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'Second message' },
        parentId: msg2.id,
      });

      const msg4 = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Second response' }],
          usage: { inputTokens: 15, outputTokens: 10 },
        },
        parentId: msg3.id,
      });

      // Fork from middle (msg2) - should have history up to msg2, not msg3/msg4
      const forkResult = await eventStore.fork(msg2.id, { name: 'Mid Fork' });

      // The fork root should point to msg2
      expect(forkResult.rootEvent.parentId).toBe(msg2.id);

      // Verify fork has access to ancestors
      const ancestors = await eventStore.getAncestors(forkResult.rootEvent.id);
      const messageEvents = ancestors.filter(e =>
        e.type === 'message.user' || e.type === 'message.assistant'
      );

      // Should only see msg1 and msg2, not msg3/msg4
      expect(messageEvents.length).toBe(2);
      expect(messageEvents.find(e => e.payload.content === 'First message')).toBeDefined();
    });

    it('should create fork from session.start event', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      // Add some events
      await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'Hello' },
        parentId: rootEvent.id,
      });

      // Fork from root (fresh start)
      const forkResult = await eventStore.fork(rootEvent.id, { name: 'Fresh Fork' });

      expect(forkResult.session).toBeDefined();
      expect(forkResult.rootEvent.parentId).toBe(rootEvent.id);

      // Ancestors should only have session.start
      const ancestors = await eventStore.getAncestors(forkResult.rootEvent.id);
      const msgEvents = ancestors.filter(e =>
        e.type === 'message.user' || e.type === 'message.assistant'
      );
      expect(msgEvents.length).toBe(0);
    });
  });

  describe('history preservation', () => {
    it('should preserve full history in forked session', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      // Build a conversation
      const events: any[] = [rootEvent];
      for (let i = 0; i < 5; i++) {
        const userMsg = await eventStore.append({
          sessionId: session.id,
          type: 'message.user',
          payload: { content: `User message ${i}` },
          parentId: events[events.length - 1].id,
        });
        events.push(userMsg);

        const assistantMsg = await eventStore.append({
          sessionId: session.id,
          type: 'message.assistant',
          payload: {
            content: [{ type: 'text', text: `Response ${i}` }],
            usage: { inputTokens: 10, outputTokens: 8 },
          },
          parentId: userMsg.id,
        });
        events.push(assistantMsg);
      }

      // Fork from last event
      const lastEvent = events[events.length - 1];
      const forkResult = await eventStore.fork(lastEvent.id, { name: 'Full History Fork' });

      // Get ancestors of fork root
      const ancestors = await eventStore.getAncestors(forkResult.rootEvent.id);

      // Should have all 10 messages + session.start
      const messageEvents = ancestors.filter(e =>
        e.type === 'message.user' || e.type === 'message.assistant'
      );
      expect(messageEvents.length).toBe(10);
    });

    it('should preserve tool call/result pairs in fork', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const toolCallId = 'toolu_01FORK123';

      const userMsg = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'Read file' },
        parentId: rootEvent.id,
      });

      const assistantMsg = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [
            { type: 'tool_use', id: toolCallId, name: 'Read', arguments: { file_path: '/x.ts' } },
          ],
          usage: { inputTokens: 15, outputTokens: 12 },
        },
        parentId: userMsg.id,
      });

      const toolResult = await eventStore.append({
        sessionId: session.id,
        type: 'tool.result',
        payload: { toolCallId, content: 'file contents', isError: false },
        parentId: assistantMsg.id,
      });

      // Fork after tool result
      const forkResult = await eventStore.fork(toolResult.id, { name: 'Tool Fork' });

      // Verify tool pair in ancestors
      const ancestors = await eventStore.getAncestors(forkResult.rootEvent.id);

      const toolCalls = ancestors.filter(e => e.type === 'message.assistant');
      expect(toolCalls.length).toBe(1);

      const toolResults = ancestors.filter(e => e.type === 'tool.result');
      expect(toolResults.length).toBe(1);
      expect(toolResults[0].payload.toolCallId).toBe(toolCallId);
    });
  });

  describe('independent mutation', () => {
    it('should allow independent events in forked session', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const msg1 = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'Branch point' },
        parentId: rootEvent.id,
      });

      // Fork
      const forkResult = await eventStore.fork(msg1.id, { name: 'Branch Fork' });

      // Add to original session
      const originalMsg = await eventStore.append({
        sessionId: session.id,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Original path' }],
          usage: { inputTokens: 10, outputTokens: 8 },
        },
        parentId: msg1.id,
      });

      // Add to forked session
      const forkMsg = await eventStore.append({
        sessionId: forkResult.session.id,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Forked path' }],
          usage: { inputTokens: 10, outputTokens: 8 },
        },
        parentId: forkResult.rootEvent.id,
      });

      // Verify they're in different sessions
      expect(originalMsg.sessionId).toBe(session.id);
      expect(forkMsg.sessionId).toBe(forkResult.session.id);

      // Verify different content
      const originalEvents = await eventStore.getEventsBySession(session.id);
      const forkEvents = await eventStore.getEventsBySession(forkResult.session.id);

      const originalAssistant = originalEvents.find(
        e => e.type === 'message.assistant' && (e.payload as { content: Array<{ type: string; text?: string }> }).content[0]?.text === 'Original path'
      );
      const forkAssistant = forkEvents.find(
        e => e.type === 'message.assistant' && (e.payload as { content: Array<{ type: string; text?: string }> }).content[0]?.text === 'Forked path'
      );

      expect(originalAssistant).toBeDefined();
      expect(forkAssistant).toBeDefined();
    });

    it('should not affect original session when modifying fork', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const msg1 = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'Initial message' },
        parentId: rootEvent.id,
      });

      // Get original event count
      const originalEventsBefore = await eventStore.getEventsBySession(session.id);
      const originalCount = originalEventsBefore.length;

      // Fork
      const forkResult = await eventStore.fork(msg1.id, { name: 'Isolated Fork' });

      // Add many events to fork
      let lastEventId = forkResult.rootEvent.id;
      for (let i = 0; i < 10; i++) {
        const evt = await eventStore.append({
          sessionId: forkResult.session.id,
          type: 'message.user',
          payload: { content: `Fork message ${i}` },
          parentId: lastEventId,
        });
        lastEventId = evt.id;
      }

      // Original session should be unchanged
      const originalEventsAfter = await eventStore.getEventsBySession(session.id);
      expect(originalEventsAfter.length).toBe(originalCount);
    });
  });

  describe('parent chain integrity', () => {
    it('should maintain correct parentId chain across fork boundary', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const msg1 = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'Pre-fork' },
        parentId: rootEvent.id,
      });

      const forkResult = await eventStore.fork(msg1.id, { name: 'Chain Fork' });

      const forkMsg = await eventStore.append({
        sessionId: forkResult.session.id,
        type: 'message.assistant',
        payload: {
          content: [{ type: 'text', text: 'Post-fork' }],
          usage: { inputTokens: 5, outputTokens: 3 },
        },
        parentId: forkResult.rootEvent.id,
      });

      // Walk the chain from forkMsg back to original session.start
      const chain: EventId[] = [];
      let currentId: EventId | null = forkMsg.id;

      while (currentId) {
        chain.push(currentId);
        const event = await eventStore.getEvent(currentId);
        currentId = event?.parentId ?? null;
      }

      // Chain should go: forkMsg -> fork.root -> msg1 -> session.start
      expect(chain.length).toBe(4);
      expect(chain[0]).toBe(forkMsg.id);
      expect(chain[1]).toBe(forkResult.rootEvent.id);
      expect(chain[2]).toBe(msg1.id);
      expect(chain[3]).toBe(rootEvent.id);
    });
  });

  describe('session metadata', () => {
    it('should create fork with new session ID', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const forkResult = await eventStore.fork(rootEvent.id, { name: 'Metadata Fork' });

      expect(forkResult.session.id).not.toBe(session.id);
      expect(forkResult.session.id).toMatch(/^sess_/);
    });

    it('should preserve working directory in fork', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/my/special/project',
        workingDirectory: '/my/special/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const forkResult = await eventStore.fork(rootEvent.id, { name: 'Workspace Fork' });

      const forkedSession = await eventStore.getSession(forkResult.session.id);
      expect(forkedSession?.workingDirectory).toBe('/my/special/project');
    });

    it('should inherit model from fork point', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-opus-4-5-20251101',
      });

      const forkResult = await eventStore.fork(rootEvent.id, { name: 'Model Fork' });

      const forkedSession = await eventStore.getSession(forkResult.session.id);
      expect(forkedSession?.model).toBe('claude-opus-4-5-20251101');
    });
  });
});
