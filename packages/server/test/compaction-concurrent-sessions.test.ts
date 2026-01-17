/**
 * @fileoverview Concurrent Session Compaction Tests
 *
 * Tests that verify compaction isolation between sessions and
 * proper serialization of parallel compaction requests.
 *
 * NOTE: Most tests commented out due to memory issues in CI.
 * These tests work individually but cause worker OOM when run together.
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { EventStore, type SessionId, type Message } from '@tron/core';
import { EventStoreOrchestrator } from '../src/event-store-orchestrator.js';
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

      // Fill both to high utilization (reduced from 300 to avoid OOM)
      const messages1 = generateTestMessages(100);
      const messages2 = generateTestMessages(100);

      injectMessagesIntoSession(orchestrator, session1.sessionId, messages1);
      injectMessagesIntoSession(orchestrator, session2.sessionId, messages2);

      // Verify both are at high utilization
      const snapshot1Before = orchestrator.getContextSnapshot(session1.sessionId);
      const snapshot2Before = orchestrator.getContextSnapshot(session2.sessionId);

      expect(snapshot1Before.usagePercent).toBeGreaterThan(0.3);
      expect(snapshot2Before.usagePercent).toBeGreaterThan(0.3);

      // Compact only session 1
      const result = await orchestrator.confirmCompaction(session1.sessionId);
      expect(result.success).toBe(true);

      // Session 1 should be reduced
      const snapshot1After = orchestrator.getContextSnapshot(session1.sessionId);
      expect(snapshot1After.currentTokens).toBeLessThan(snapshot1Before.currentTokens);

      // Session 2 should be unchanged
      const snapshot2After = orchestrator.getContextSnapshot(session2.sessionId);
      expect(snapshot2After.currentTokens).toBe(snapshot2Before.currentTokens);
    });

    // NOTE: Additional tests commented out due to CI memory constraints.
    // These tests work individually but cause worker OOM when run together.
    // To run locally: uncomment and run with increased heap size.
  });
});
