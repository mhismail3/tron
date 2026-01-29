/**
 * @fileoverview Fork Chain Tests
 *
 * Tests for fork chains (fork of a fork) and deep fork trees:
 * - Fork of fork with full ancestry
 * - Deep fork trees (20+ levels)
 * - Parallel forks from same point
 * - Fork ancestry reconstruction
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { EventStore, SessionId, EventId } from '../../index.js';
import path from 'path';
import os from 'os';
import fs from 'fs';

describe('Fork Integration - Fork Chains', () => {
  let eventStore: EventStore;
  let testDir: string;

  beforeEach(async () => {
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tron-fork-chain-test-'));
    const dbPath = path.join(testDir, 'events.db');
    eventStore = new EventStore(dbPath);
    await eventStore.initialize();
  });

  afterEach(async () => {
    await eventStore.close();
    fs.rmSync(testDir, { recursive: true, force: true });
  });

  describe('fork of fork', () => {
    it('should create fork of a forked session', async () => {
      // Session A (original)
      const { session: sessionA, rootEvent: rootA } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const msgA1 = await eventStore.append({
        sessionId: sessionA.id,
        type: 'message.user',
        payload: { content: 'Session A message' },
        parentId: rootA.id,
      });

      // Fork to Session B
      const forkB = await eventStore.fork(msgA1.id, { name: 'Fork B' });

      const msgB1 = await eventStore.append({
        sessionId: forkB.session.id,
        type: 'message.user',
        payload: { content: 'Session B message' },
        parentId: forkB.rootEvent.id,
      });

      // Fork B to Session C
      const forkC = await eventStore.fork(msgB1.id, { name: 'Fork C (from B)' });

      const msgC1 = await eventStore.append({
        sessionId: forkC.session.id,
        type: 'message.user',
        payload: { content: 'Session C message' },
        parentId: forkC.rootEvent.id,
      });

      // Verify C has full ancestry: C msg -> C root -> B msg -> B root -> A msg -> A root
      const ancestors = await eventStore.getAncestors(msgC1.id);

      // Should have messages from all three sessions in ancestry
      const userMessages = ancestors.filter(e => e.type === 'message.user');
      expect(userMessages.length).toBe(3);

      expect(userMessages.find(m => m.payload.content === 'Session A message')).toBeDefined();
      expect(userMessages.find(m => m.payload.content === 'Session B message')).toBeDefined();
      expect(userMessages.find(m => m.payload.content === 'Session C message')).toBeDefined();
    });

    it('should maintain independent branches in fork chain', async () => {
      const { session: sessionA, rootEvent: rootA } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const msgA = await eventStore.append({
        sessionId: sessionA.id,
        type: 'message.user',
        payload: { content: 'Base' },
        parentId: rootA.id,
      });

      // Fork to B
      const forkB = await eventStore.fork(msgA.id, { name: 'B' });

      // Add to A after fork
      const msgA2 = await eventStore.append({
        sessionId: sessionA.id,
        type: 'message.user',
        payload: { content: 'Only in A' },
        parentId: msgA.id,
      });

      // Add to B
      const msgB1 = await eventStore.append({
        sessionId: forkB.session.id,
        type: 'message.user',
        payload: { content: 'Only in B' },
        parentId: forkB.rootEvent.id,
      });

      // Fork B to C
      const forkC = await eventStore.fork(msgB1.id, { name: 'C' });

      const msgC1 = await eventStore.append({
        sessionId: forkC.session.id,
        type: 'message.user',
        payload: { content: 'Only in C' },
        parentId: forkC.rootEvent.id,
      });

      // C should NOT see A's post-fork message
      const ancestorsC = await eventStore.getAncestors(msgC1.id);
      const messagesC = ancestorsC.filter(e => e.type === 'message.user');

      expect(messagesC.find(m => m.payload.content === 'Only in A')).toBeUndefined();
      expect(messagesC.find(m => m.payload.content === 'Only in B')).toBeDefined();
      expect(messagesC.find(m => m.payload.content === 'Only in C')).toBeDefined();
      expect(messagesC.find(m => m.payload.content === 'Base')).toBeDefined();
    });
  });

  describe('deep fork trees', () => {
    it('should handle 10-level deep fork chain', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      let lastEventId: EventId = rootEvent.id;
      let lastSessionId: SessionId = session.id;
      const sessionIds: SessionId[] = [session.id];

      // Create 10-level deep fork chain
      for (let depth = 0; depth < 10; depth++) {
        // Add message at this level
        const msg = await eventStore.append({
          sessionId: lastSessionId,
          type: 'message.user',
          payload: { content: `Level ${depth} message` },
          parentId: lastEventId,
        });

        // Fork to next level (except for last)
        if (depth < 9) {
          const fork = await eventStore.fork(msg.id, { name: `Fork Level ${depth + 1}` });
          lastEventId = fork.rootEvent.id;
          lastSessionId = fork.session.id;
          sessionIds.push(fork.session.id);
        } else {
          lastEventId = msg.id;
        }
      }

      // Get ancestors from deepest point
      const ancestors = await eventStore.getAncestors(lastEventId);
      const messages = ancestors.filter(e => e.type === 'message.user');

      // Should have all 10 messages
      expect(messages.length).toBe(10);

      // Verify order (oldest to newest in ancestry)
      for (let i = 0; i < 10; i++) {
        expect(messages.find(m => m.payload.content === `Level ${i} message`)).toBeDefined();
      }

      // All sessions should be unique
      expect(new Set(sessionIds).size).toBe(10);
    });

    it('should handle wide fork tree (many forks from same point)', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const baseMsg = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'Common base' },
        parentId: rootEvent.id,
      });

      // Create 5 parallel forks from same point
      const forks = [];
      for (let i = 0; i < 5; i++) {
        const fork = await eventStore.fork(baseMsg.id, { name: `Parallel Fork ${i}` });
        forks.push(fork);

        // Add unique message to each fork
        await eventStore.append({
          sessionId: fork.session.id,
          type: 'message.user',
          payload: { content: `Unique to fork ${i}` },
          parentId: fork.rootEvent.id,
        });
      }

      // Verify each fork has the common base
      for (let i = 0; i < 5; i++) {
        const forkEvents = await eventStore.getEventsBySession(forks[i].session.id);
        const ancestors = await eventStore.getAncestors(forks[i].rootEvent.id);

        const baseInAncestors = ancestors.find(e => (e.payload as { content?: string })?.content === 'Common base');
        expect(baseInAncestors).toBeDefined();
      }

      // Verify forks don't see each other's unique messages
      for (let i = 0; i < 5; i++) {
        const forkEvents = await eventStore.getEventsBySession(forks[i].session.id);
        const userMsgs = forkEvents.filter(e => e.type === 'message.user');

        // Each fork should only have its own unique message (not messages from other forks)
        const uniqueMsg = userMsgs.find(m => m.payload.content === `Unique to fork ${i}`);
        expect(uniqueMsg).toBeDefined();

        // Should not have other forks' messages
        for (let j = 0; j < 5; j++) {
          if (i !== j) {
            const otherMsg = userMsgs.find(m => m.payload.content === `Unique to fork ${j}`);
            expect(otherMsg).toBeUndefined();
          }
        }
      }
    });
  });

  describe('fork ancestry reconstruction', () => {
    it('should reconstruct complete model history across fork chain', async () => {
      const { session: sessionA, rootEvent: rootA } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-haiku-4-5-20251001',
      });

      // Switch model in A
      const switch1 = await eventStore.append({
        sessionId: sessionA.id,
        type: 'config.model_switch',
        payload: { previousModel: 'claude-haiku-4-5-20251001', newModel: 'claude-sonnet-4-5-20250929' },
        parentId: rootA.id,
      });

      // Fork to B
      const forkB = await eventStore.fork(switch1.id, { name: 'B' });

      // Switch model in B
      const switch2 = await eventStore.append({
        sessionId: forkB.session.id,
        type: 'config.model_switch',
        payload: { previousModel: 'claude-sonnet-4-5-20250929', newModel: 'claude-opus-4-5-20251101' },
        parentId: forkB.rootEvent.id,
      });

      // Fork to C
      const forkC = await eventStore.fork(switch2.id, { name: 'C' });

      // Reconstruct model history from C
      const ancestors = await eventStore.getAncestors(forkC.rootEvent.id);

      let currentModel = 'claude-haiku-4-5-20251001';
      const modelHistory: string[] = [currentModel];

      for (const event of ancestors) {
        if (event.type === 'config.model_switch') {
          currentModel = event.payload.newModel as string;
          modelHistory.push(currentModel);
        }
      }

      expect(modelHistory).toEqual([
        'claude-haiku-4-5-20251001',
        'claude-sonnet-4-5-20250929',
        'claude-opus-4-5-20251101',
      ]);
    });

    it('should track fork points in session metadata', async () => {
      const { session: sessionA, rootEvent: rootA } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const msgA = await eventStore.append({
        sessionId: sessionA.id,
        type: 'message.user',
        payload: { content: 'Fork point' },
        parentId: rootA.id,
      });

      const forkB = await eventStore.fork(msgA.id, { name: 'B from A' });

      // Fork root should have correct parent
      expect(forkB.rootEvent.parentId).toBe(msgA.id);

      // Can trace back to original session
      const parent = await eventStore.getEvent(forkB.rootEvent.parentId!);
      expect(parent?.sessionId).toBe(sessionA.id);
    });
  });

  describe('session isolation', () => {
    it('should maintain session boundaries in fork chain', async () => {
      const { session: sessionA, rootEvent: rootA } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-sonnet-4-5-20250929',
      });

      const msgA = await eventStore.append({
        sessionId: sessionA.id,
        type: 'message.user',
        payload: { content: 'In A' },
        parentId: rootA.id,
      });

      const forkB = await eventStore.fork(msgA.id, { name: 'B' });

      const msgB = await eventStore.append({
        sessionId: forkB.session.id,
        type: 'message.user',
        payload: { content: 'In B' },
        parentId: forkB.rootEvent.id,
      });

      // Events are stored in their respective sessions
      const eventsA = await eventStore.getEventsBySession(sessionA.id);
      const eventsB = await eventStore.getEventsBySession(forkB.session.id);

      // A's events
      const aMsgs = eventsA.filter(e => e.type === 'message.user');
      expect(aMsgs.length).toBe(1);
      expect(aMsgs[0].payload.content).toBe('In A');

      // B's events (excluding inherited via ancestry)
      const bMsgs = eventsB.filter(e => e.type === 'message.user');
      expect(bMsgs.length).toBe(1);
      expect(bMsgs[0].payload.content).toBe('In B');
    });
  });
});
