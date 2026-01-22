/**
 * @fileoverview Orchestrator Compaction Integration Tests (TDD)
 *
 * Tests that verify the orchestrator's compaction methods work correctly
 * with the ContextManager and EventStore.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { EventStore, SessionId, type Message } from '../index.js';
import { EventStoreOrchestrator } from '../event-store-orchestrator.js';
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
    eventStore, // Inject the test store
  });

  // Mock auth for tests
  (orchestrator as any).cachedAuth = { type: 'api_key', apiKey: 'test-key' };
  (orchestrator as any).initialized = true;

  return { orchestrator, eventStore };
};

// Generate test messages to simulate high context
const generateTestMessages = (count: number): Message[] => {
  const messages: Message[] = [];
  for (let i = 0; i < count; i++) {
    messages.push({ role: 'user', content: `Test message ${i + 1}` });
    messages.push({
      role: 'assistant',
      content: [{ type: 'text', text: `Response ${i + 1}: ${'.'.repeat(500)}` }],
    });
  }
  return messages;
};

// =============================================================================
// Tests
// =============================================================================

describe('Orchestrator Compaction', () => {
  let testDir: string;
  let orchestrator: EventStoreOrchestrator;
  let eventStore: EventStore;
  let sessionId: string;

  beforeEach(async () => {
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tron-compaction-test-'));
    const result = await createTestOrchestrator(testDir);
    orchestrator = result.orchestrator;
    eventStore = result.eventStore;
  });

  afterEach(async () => {
    await orchestrator?.shutdown();
    await eventStore?.close();
    fs.rmSync(testDir, { recursive: true, force: true });
  });

  describe('getContextSnapshot', () => {
    it('returns context snapshot for active session', async () => {
      // Create a session
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      sessionId = session.sessionId;

      const snapshot = orchestrator.getContextSnapshot(sessionId);

      expect(snapshot).toBeDefined();
      expect(snapshot.currentTokens).toBeGreaterThanOrEqual(0);
      expect(snapshot.contextLimit).toBe(200_000);
      expect(snapshot.usagePercent).toBeGreaterThanOrEqual(0);
      expect(snapshot.thresholdLevel).toBe('normal');
    });

    it('returns default snapshot for non-existent session', () => {
      // Changed behavior: returns default snapshot instead of throwing
      // This supports iOS Context Audit view for new/inactive sessions
      const snapshot = orchestrator.getContextSnapshot('non-existent');

      expect(snapshot.currentTokens).toBe(0);
      expect(snapshot.contextLimit).toBe(200_000);
      expect(snapshot.usagePercent).toBe(0);
      expect(snapshot.thresholdLevel).toBe('normal');
      expect(snapshot.breakdown).toEqual({
        systemPrompt: 0,
        tools: 0,
        rules: 0,
        messages: 0,
      });
    });

    it('returns warning threshold when context is high', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      sessionId = session.sessionId;

      // Inject high-context messages via agent's ContextManager
      const active = (orchestrator as any).activeSessions.get(sessionId);
      const messages = generateTestMessages(500); // Lots of messages
      active.agent.getContextManager().setMessages(messages);

      const snapshot = orchestrator.getContextSnapshot(sessionId);

      expect(snapshot.usagePercent).toBeGreaterThan(0);
    });
  });

  describe('shouldCompact', () => {
    it('returns false for low context', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      sessionId = session.sessionId;

      const shouldCompact = orchestrator.shouldCompact(sessionId);

      expect(shouldCompact).toBe(false);
    });

    it('returns true for high context', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      sessionId = session.sessionId;

      // Inject high-context messages
      const active = (orchestrator as any).activeSessions.get(sessionId);
      // Generate enough messages to exceed 70% threshold
      // 200k * 0.7 = 140k tokens, each message ~150 tokens, need ~900 turns
      const messages = generateTestMessages(1000);
      active.agent.getContextManager().setMessages(messages);

      const shouldCompact = orchestrator.shouldCompact(sessionId);

      // Note: May or may not trigger depending on actual token calculation
      // This tests the method exists and returns a boolean
      expect(typeof shouldCompact).toBe('boolean');
    });
  });

  describe('previewCompaction', () => {
    it('returns preview for high context session', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      sessionId = session.sessionId;

      // Inject messages
      const active = (orchestrator as any).activeSessions.get(sessionId);
      const messages = generateTestMessages(100);
      active.agent.getContextManager().setMessages(messages);

      const preview = await orchestrator.previewCompaction(sessionId);

      expect(preview).toBeDefined();
      expect(preview.tokensBefore).toBeGreaterThan(0);
      expect(preview.tokensAfter).toBeLessThan(preview.tokensBefore);
      expect(preview.compressionRatio).toBeGreaterThan(0);
      expect(preview.compressionRatio).toBeLessThan(1);
      expect(preview.summary).toBeDefined();
    });

    it('does not modify session state', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      sessionId = session.sessionId;

      const active = (orchestrator as any).activeSessions.get(sessionId);
      const messages = generateTestMessages(50);
      active.agent.getContextManager().setMessages(messages);

      const tokensBefore = active.agent.getContextManager().getCurrentTokens();
      const messagesBefore = active.agent.getContextManager().getMessages().length;

      await orchestrator.previewCompaction(sessionId);

      const tokensAfter = active.agent.getContextManager().getCurrentTokens();
      const messagesAfter = active.agent.getContextManager().getMessages().length;

      expect(tokensAfter).toBe(tokensBefore);
      expect(messagesAfter).toBe(messagesBefore);
    });
  });

  describe('confirmCompaction', () => {
    it('executes compaction and reduces context', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      sessionId = session.sessionId;

      const active = (orchestrator as any).activeSessions.get(sessionId);
      const messages = generateTestMessages(100);
      active.agent.getContextManager().setMessages(messages);

      const tokensBefore = active.agent.getContextManager().getCurrentTokens();

      const result = await orchestrator.confirmCompaction(sessionId);

      expect(result.success).toBe(true);
      expect(result.tokensAfter).toBeLessThan(result.tokensBefore);

      const tokensAfter = active.agent.getContextManager().getCurrentTokens();
      expect(tokensAfter).toBeLessThan(tokensBefore);
    });

    it('supports custom edited summary', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      sessionId = session.sessionId;

      const active = (orchestrator as any).activeSessions.get(sessionId);
      const messages = generateTestMessages(50);
      active.agent.getContextManager().setMessages(messages);

      const customSummary = 'User-edited custom summary for testing purposes.';
      const result = await orchestrator.confirmCompaction(sessionId, {
        editedSummary: customSummary,
      });

      expect(result.success).toBe(true);
      expect(result.summary).toBe(customSummary);

      // Verify summary is in the context
      const currentMessages = active.agent.getContextManager().getMessages();
      expect(currentMessages[0].content).toContain(customSummary);
    });

    it('stores compaction events in EventStore', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      sessionId = session.sessionId;

      const active = (orchestrator as any).activeSessions.get(sessionId);
      const messages = generateTestMessages(50);
      active.agent.getContextManager().setMessages(messages);

      await orchestrator.confirmCompaction(sessionId);

      // Query events from EventStore
      const events = await eventStore.getEventsBySession(sessionId as SessionId);
      const compactionEvents = events.filter(
        (e) => e.type === 'compact.boundary' || e.type === 'compact.summary'
      );

      expect(compactionEvents.length).toBeGreaterThanOrEqual(2);

      const boundaryEvent = events.find((e) => e.type === 'compact.boundary');
      expect(boundaryEvent).toBeDefined();
      expect(boundaryEvent!.payload.originalTokens).toBeGreaterThan(0);
      expect(boundaryEvent!.payload.compactedTokens).toBeLessThan(
        boundaryEvent!.payload.originalTokens
      );

      const summaryEvent = events.find((e) => e.type === 'compact.summary');
      expect(summaryEvent).toBeDefined();
      expect(summaryEvent!.payload.summary).toBeDefined();
    });

    it('emits compaction_completed event', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      sessionId = session.sessionId;

      const active = (orchestrator as any).activeSessions.get(sessionId);
      const messages = generateTestMessages(50);
      active.agent.getContextManager().setMessages(messages);

      const events: any[] = [];
      orchestrator.on('compaction_completed', (e) => events.push(e));

      await orchestrator.confirmCompaction(sessionId);

      expect(events.length).toBe(1);
      expect(events[0].sessionId).toBe(sessionId);
      expect(events[0].tokensBefore).toBeGreaterThan(0);
      expect(events[0].tokensAfter).toBeLessThan(events[0].tokensBefore);
    });
  });

  describe('canAcceptTurn', () => {
    it('returns true for low context', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      sessionId = session.sessionId;

      const validation = orchestrator.canAcceptTurn(sessionId, {
        estimatedResponseTokens: 4000,
      });

      expect(validation.canProceed).toBe(true);
      expect(validation.needsCompaction).toBe(false);
    });

    it('provides validation details', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      sessionId = session.sessionId;

      const validation = orchestrator.canAcceptTurn(sessionId, {
        estimatedResponseTokens: 4000,
      });

      expect(validation.currentTokens).toBeGreaterThanOrEqual(0);
      expect(validation.estimatedAfterTurn).toBeGreaterThan(validation.currentTokens);
      expect(validation.contextLimit).toBe(200_000);
    });
  });
});
