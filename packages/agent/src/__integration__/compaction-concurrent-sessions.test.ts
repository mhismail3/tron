/**
 * @fileoverview Concurrent Session Compaction Tests
 *
 * Tests that verify compaction isolation between sessions and
 * proper serialization of parallel compaction requests.
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { EventStore, type SessionId, type Message } from '../index.js';
import { EventStoreOrchestrator } from '../orchestrator/event-store-orchestrator.js';
import path from 'path';
import os from 'os';
import fs from 'fs';

// =============================================================================
// Test Fixtures
// =============================================================================

const createTestOrchestrator = async (testDir: string) => {
  const eventStore = new EventStore(path.join(testDir, 'events.db'));
  await eventStore.initialize();

  const orchestrator = new EventStoreOrchestrator({
    defaultModel: 'claude-sonnet-4-20250514',
    eventStoreDbPath: path.join(testDir, 'events.db'),
    eventStore,
  });

  // Mock auth for tests
  (orchestrator as any).cachedAuth = { type: 'api_key', apiKey: 'test-key' };
  (orchestrator as any).initialized = true;

  return { orchestrator, eventStore };
};

/**
 * Generate test messages to simulate high context.
 * Each pair is roughly 600 tokens (user ~100 + assistant ~500).
 */
const generateTestMessages = (count: number): Message[] => {
  const messages: Message[] = [];
  for (let i = 0; i < count; i++) {
    messages.push({
      role: 'user',
      content: `Test message ${i + 1}: ${'x'.repeat(400)}`,
    });
    messages.push({
      role: 'assistant',
      content: [{ type: 'text', text: `Response ${i + 1}: ${'y'.repeat(2000)}` }],
    });
  }
  return messages;
};

/**
 * Inject messages directly into a session's ContextManager.
 */
const injectMessagesIntoSession = (
  orchestrator: EventStoreOrchestrator,
  sessionId: string,
  messages: Message[]
) => {
  const active = (orchestrator as any).activeSessions.get(sessionId);
  if (active) {
    active.agent.getContextManager().setMessages(messages);
  }
};

// =============================================================================
// Tests
// =============================================================================

describe('Concurrent Session Compaction', () => {
  let testDir: string;
  let orchestrator: EventStoreOrchestrator;
  let eventStore: EventStore;

  beforeEach(async () => {
    testDir = fs.mkdtempSync(
      path.join(os.tmpdir(), 'tron-concurrent-compaction-test-')
    );
    const result = await createTestOrchestrator(testDir);
    orchestrator = result.orchestrator;
    eventStore = result.eventStore;
  });

  afterEach(async () => {
    await orchestrator?.shutdown();
    await eventStore?.close();
    fs.rmSync(testDir, { recursive: true, force: true });
  });

  describe('session isolation', () => {
    it('compacting one session does not affect another', async () => {
      // Create two sessions
      const session1 = await orchestrator.createSession({
        workingDirectory: path.join(testDir, 'session1'),
      });
      const session2 = await orchestrator.createSession({
        workingDirectory: path.join(testDir, 'session2'),
      });

      // Fill both to high utilization (~85%)
      const messages1 = generateTestMessages(300);
      const messages2 = generateTestMessages(300);

      injectMessagesIntoSession(orchestrator, session1.sessionId, messages1);
      injectMessagesIntoSession(orchestrator, session2.sessionId, messages2);

      // Verify both are at high utilization
      const snapshot1Before = orchestrator.getContextSnapshot(session1.sessionId);
      const snapshot2Before = orchestrator.getContextSnapshot(session2.sessionId);

      expect(snapshot1Before.usagePercent).toBeGreaterThan(0.5);
      expect(snapshot2Before.usagePercent).toBeGreaterThan(0.5);

      // Compact only session 1
      const result = await orchestrator.confirmCompaction(session1.sessionId);
      expect(result.success).toBe(true);

      // Session 1 should be reduced
      const snapshot1After = orchestrator.getContextSnapshot(session1.sessionId);
      expect(snapshot1After.usagePercent).toBeLessThan(0.3);
      expect(snapshot1After.currentTokens).toBeLessThan(snapshot1Before.currentTokens);

      // Session 2 should be unchanged
      const snapshot2After = orchestrator.getContextSnapshot(session2.sessionId);
      expect(snapshot2After.currentTokens).toBe(snapshot2Before.currentTokens);
      expect(snapshot2After.usagePercent).toBe(snapshot2Before.usagePercent);
    });

    it('compacting both sessions independently works correctly', async () => {
      // Create two sessions
      const session1 = await orchestrator.createSession({
        workingDirectory: path.join(testDir, 'session1'),
      });
      const session2 = await orchestrator.createSession({
        workingDirectory: path.join(testDir, 'session2'),
      });

      // Fill both
      injectMessagesIntoSession(
        orchestrator,
        session1.sessionId,
        generateTestMessages(200)
      );
      injectMessagesIntoSession(
        orchestrator,
        session2.sessionId,
        generateTestMessages(200)
      );

      // Compact both
      const [result1, result2] = await Promise.all([
        orchestrator.confirmCompaction(session1.sessionId),
        orchestrator.confirmCompaction(session2.sessionId),
      ]);

      expect(result1.success).toBe(true);
      expect(result2.success).toBe(true);

      // Both should be reduced
      const snapshot1 = orchestrator.getContextSnapshot(session1.sessionId);
      const snapshot2 = orchestrator.getContextSnapshot(session2.sessionId);

      expect(snapshot1.usagePercent).toBeLessThan(0.3);
      expect(snapshot2.usagePercent).toBeLessThan(0.3);
    });

    it('getContextSnapshot returns correct session data', async () => {
      // Create two sessions with different context sizes
      const session1 = await orchestrator.createSession({
        workingDirectory: path.join(testDir, 'session1'),
      });
      const session2 = await orchestrator.createSession({
        workingDirectory: path.join(testDir, 'session2'),
      });

      // Different sizes
      injectMessagesIntoSession(
        orchestrator,
        session1.sessionId,
        generateTestMessages(100) // ~60k tokens
      );
      injectMessagesIntoSession(
        orchestrator,
        session2.sessionId,
        generateTestMessages(300) // ~180k tokens
      );

      const snapshot1 = orchestrator.getContextSnapshot(session1.sessionId);
      const snapshot2 = orchestrator.getContextSnapshot(session2.sessionId);

      // Session 2 should have more tokens
      expect(snapshot2.currentTokens).toBeGreaterThan(snapshot1.currentTokens);
      expect(snapshot2.usagePercent).toBeGreaterThan(snapshot1.usagePercent);
    });

    it('shouldCompact returns correct value per session', async () => {
      const session1 = await orchestrator.createSession({
        workingDirectory: path.join(testDir, 'session1'),
      });
      const session2 = await orchestrator.createSession({
        workingDirectory: path.join(testDir, 'session2'),
      });

      // Session 1: low utilization (won't need compaction)
      injectMessagesIntoSession(
        orchestrator,
        session1.sessionId,
        generateTestMessages(50) // ~30k tokens
      );

      // Session 2: high utilization (needs compaction)
      injectMessagesIntoSession(
        orchestrator,
        session2.sessionId,
        generateTestMessages(300) // ~180k tokens
      );

      expect(orchestrator.shouldCompact(session1.sessionId)).toBe(false);
      expect(orchestrator.shouldCompact(session2.sessionId)).toBe(true);
    });
  });

  describe('parallel compaction requests', () => {
    it('multiple preview requests on same session return consistent results', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });

      injectMessagesIntoSession(
        orchestrator,
        session.sessionId,
        generateTestMessages(200)
      );

      // Request multiple previews in parallel
      const [preview1, preview2, preview3] = await Promise.all([
        orchestrator.previewCompaction(session.sessionId),
        orchestrator.previewCompaction(session.sessionId),
        orchestrator.previewCompaction(session.sessionId),
      ]);

      // All should return same values
      expect(preview1.tokensBefore).toBe(preview2.tokensBefore);
      expect(preview2.tokensBefore).toBe(preview3.tokensBefore);
      expect(preview1.compressionRatio).toBe(preview2.compressionRatio);
    });

    it('parallel compaction requests on same session serialize correctly', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });

      injectMessagesIntoSession(
        orchestrator,
        session.sessionId,
        generateTestMessages(200)
      );

      // Fire two compaction requests in parallel
      // One should succeed immediately, the other should see already-compacted state
      const [result1, result2] = await Promise.all([
        orchestrator.confirmCompaction(session.sessionId),
        orchestrator.confirmCompaction(session.sessionId),
      ]);

      // Both should succeed
      expect(result1.success).toBe(true);
      expect(result2.success).toBe(true);

      // The second one should see much lower tokensBefore (already compacted)
      // OR they should both see the same high value if properly serialized
      // Either way, final state should be compacted
      const finalSnapshot = orchestrator.getContextSnapshot(session.sessionId);
      expect(finalSnapshot.usagePercent).toBeLessThan(0.3);
    });

    it('preview then confirm maintains consistency', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });

      injectMessagesIntoSession(
        orchestrator,
        session.sessionId,
        generateTestMessages(200)
      );

      // Preview first
      const preview = await orchestrator.previewCompaction(session.sessionId);

      // Then confirm
      const result = await orchestrator.confirmCompaction(session.sessionId);

      expect(result.success).toBe(true);
      expect(result.tokensBefore).toBe(preview.tokensBefore);

      // Tokens after should be close to preview (within tolerance)
      const tolerance = preview.tokensAfter * 0.3; // 30% tolerance
      expect(result.tokensAfter).toBeGreaterThan(preview.tokensAfter - tolerance);
      expect(result.tokensAfter).toBeLessThan(preview.tokensAfter + tolerance);
    });
  });

  describe('session event isolation', () => {
    it('compaction events are stored in correct session', async () => {
      const session1 = await orchestrator.createSession({
        workingDirectory: path.join(testDir, 'session1'),
      });
      const session2 = await orchestrator.createSession({
        workingDirectory: path.join(testDir, 'session2'),
      });

      // Fill and compact session 1 only
      injectMessagesIntoSession(
        orchestrator,
        session1.sessionId,
        generateTestMessages(150)
      );
      await orchestrator.confirmCompaction(session1.sessionId);

      // Check events for session 1
      const events1 = await eventStore.getEventsBySession(
        session1.sessionId as SessionId
      );
      const compactEvents1 = events1.filter(
        e => e.type === 'compact.boundary' || e.type === 'compact.summary'
      );
      expect(compactEvents1.length).toBeGreaterThanOrEqual(2);

      // Check events for session 2 - should have no compaction events
      const events2 = await eventStore.getEventsBySession(
        session2.sessionId as SessionId
      );
      const compactEvents2 = events2.filter(
        e => e.type === 'compact.boundary' || e.type === 'compact.summary'
      );
      expect(compactEvents2.length).toBe(0);
    });

    it('canAcceptTurn is independent per session', async () => {
      const session1 = await orchestrator.createSession({
        workingDirectory: path.join(testDir, 'session1'),
      });
      const session2 = await orchestrator.createSession({
        workingDirectory: path.join(testDir, 'session2'),
      });

      // Session 1: critical level (should block turns)
      injectMessagesIntoSession(
        orchestrator,
        session1.sessionId,
        generateTestMessages(350) // ~210k tokens = exceeded
      );

      // Session 2: normal level (should allow turns)
      injectMessagesIntoSession(
        orchestrator,
        session2.sessionId,
        generateTestMessages(50) // ~30k tokens
      );

      const validation1 = orchestrator.canAcceptTurn(session1.sessionId, {
        estimatedResponseTokens: 4000,
      });
      const validation2 = orchestrator.canAcceptTurn(session2.sessionId, {
        estimatedResponseTokens: 4000,
      });

      // Session 1 at critical/exceeded should block or need compaction
      expect(validation1.needsCompaction).toBe(true);

      // Session 2 at normal should proceed freely
      expect(validation2.canProceed).toBe(true);
      expect(validation2.needsCompaction).toBe(false);
    });
  });

  describe('error handling', () => {
    it('compaction on non-existent session throws', async () => {
      await expect(
        orchestrator.confirmCompaction('non-existent-session')
      ).rejects.toThrow('Session not active');
    });

    it('preview on non-existent session throws', async () => {
      await expect(
        orchestrator.previewCompaction('non-existent-session')
      ).rejects.toThrow();
    });

    it('compaction failure on one session does not affect others', async () => {
      const session1 = await orchestrator.createSession({
        workingDirectory: path.join(testDir, 'session1'),
      });
      const session2 = await orchestrator.createSession({
        workingDirectory: path.join(testDir, 'session2'),
      });

      // Fill both
      injectMessagesIntoSession(
        orchestrator,
        session1.sessionId,
        generateTestMessages(200)
      );
      injectMessagesIntoSession(
        orchestrator,
        session2.sessionId,
        generateTestMessages(200)
      );

      // Compact session 1 successfully
      const result1 = await orchestrator.confirmCompaction(session1.sessionId);
      expect(result1.success).toBe(true);

      // Try to compact a non-existent session - should throw
      await expect(
        orchestrator.confirmCompaction('bad-session')
      ).rejects.toThrow('Session not active');

      // Session 2 should still be compactable
      const result2 = await orchestrator.confirmCompaction(session2.sessionId);
      expect(result2.success).toBe(true);
    });
  });

  describe('detailed context snapshot isolation', () => {
    it('getDetailedContextSnapshot returns correct per-session data', async () => {
      const session1 = await orchestrator.createSession({
        workingDirectory: path.join(testDir, 'session1'),
      });
      const session2 = await orchestrator.createSession({
        workingDirectory: path.join(testDir, 'session2'),
      });

      // Different message counts
      injectMessagesIntoSession(
        orchestrator,
        session1.sessionId,
        generateTestMessages(10)
      );
      injectMessagesIntoSession(
        orchestrator,
        session2.sessionId,
        generateTestMessages(50)
      );

      const detailed1 = orchestrator.getDetailedContextSnapshot(session1.sessionId);
      const detailed2 = orchestrator.getDetailedContextSnapshot(session2.sessionId);

      // Message counts should differ
      expect(detailed1.messages.length).toBe(20); // 10 pairs
      expect(detailed2.messages.length).toBe(100); // 50 pairs

      // Token counts should reflect message counts
      expect(detailed2.currentTokens).toBeGreaterThan(detailed1.currentTokens);
    });
  });
});
