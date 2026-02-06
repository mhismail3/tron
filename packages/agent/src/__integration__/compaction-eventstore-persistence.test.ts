/**
 * @fileoverview Compaction EventStore Persistence Tests
 *
 * Tests that verify compaction events are correctly persisted to the EventStore
 * and that session reconstruction handles compaction boundaries properly.
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { EventStore, type SessionId, type Message } from '../index.js';
import { EventStoreOrchestrator } from '@runtime/orchestrator/persistence/event-store-orchestrator.js';
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
    defaultProvider: 'anthropic',
    eventStoreDbPath: path.join(testDir, 'events.db'),
    eventStore,
  });

  (orchestrator as any).authProvider.setCachedAuth({ type: 'api_key', apiKey: 'test-key' });
  (orchestrator as any).initialized = true;

  return { orchestrator, eventStore };
};

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
 * Estimate tokens for test messages (~600 tokens per turn).
 */
const estimateMessageTokens = (count: number): number => {
  return count * 600;
};

// Base overhead for system prompt + tools (typical value)
const BASE_CONTEXT_OVERHEAD = 15000;

/**
 * Inject messages directly into a session's ContextManager.
 * Also sets the API tokens to simulate what happens after a turn completes.
 */
const injectMessagesIntoSession = (
  orchestrator: EventStoreOrchestrator,
  sessionId: string,
  messages: Message[],
  tokenCount?: number
) => {
  const active = (orchestrator as any).activeSessions.get(sessionId);
  if (active) {
    const cm = active.agent.getContextManager();
    cm.setMessages(messages);
    // Set API tokens to simulate what happens after a turn completes
    // Real API reports total context including system prompt + tools + messages
    const tokens = tokenCount ?? (BASE_CONTEXT_OVERHEAD + estimateMessageTokens(messages.length / 2));
    cm.setApiContextTokens(tokens);
  }
};

// =============================================================================
// Tests
// =============================================================================

describe('Compaction EventStore Persistence', () => {
  let testDir: string;
  let orchestrator: EventStoreOrchestrator;
  let eventStore: EventStore;

  beforeEach(async () => {
    testDir = fs.mkdtempSync(
      path.join(os.tmpdir(), 'tron-compaction-eventstore-test-')
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

  describe('compact.boundary event', () => {
    it('contains correct token counts', async () => {
      const session = await orchestrator.sessions.createSession({
        workingDirectory: testDir,
      });

      const messages = generateTestMessages(150);
      injectMessagesIntoSession(orchestrator, session.sessionId, messages);

      // Get tokens before
      const snapshotBefore = orchestrator.context.getContextSnapshot(session.sessionId);
      const tokensBefore = snapshotBefore.currentTokens;

      // Compact
      await orchestrator.context.confirmCompaction(session.sessionId);

      // Get boundary event
      const events = await eventStore.getEventsBySession(
        session.sessionId as SessionId
      );
      const boundary = events.find(e => e.type === 'compact.boundary');

      expect(boundary).toBeDefined();
      expect(boundary!.payload.originalTokens).toBe(tokensBefore);
      expect(boundary!.payload.compactedTokens).toBeLessThan(
        boundary!.payload.originalTokens
      );
    });

    it('contains accurate compression ratio', async () => {
      const session = await orchestrator.sessions.createSession({
        workingDirectory: testDir,
      });

      injectMessagesIntoSession(
        orchestrator,
        session.sessionId,
        generateTestMessages(200)
      );

      await orchestrator.context.confirmCompaction(session.sessionId);

      const events = await eventStore.getEventsBySession(
        session.sessionId as SessionId
      );
      const boundary = events.find(e => e.type === 'compact.boundary');

      expect(boundary).toBeDefined();

      // Verify compression ratio calculation
      const actualRatio =
        boundary!.payload.compactedTokens / boundary!.payload.originalTokens;
      expect(actualRatio).toBeGreaterThan(0);
      expect(actualRatio).toBeLessThan(1);
    });

    it('has correct sessionId and timestamp', async () => {
      const session = await orchestrator.sessions.createSession({
        workingDirectory: testDir,
      });

      injectMessagesIntoSession(
        orchestrator,
        session.sessionId,
        generateTestMessages(100)
      );

      const beforeCompact = Date.now();
      await orchestrator.context.confirmCompaction(session.sessionId);
      const afterCompact = Date.now();

      const events = await eventStore.getEventsBySession(
        session.sessionId as SessionId
      );
      const boundary = events.find(e => e.type === 'compact.boundary');

      expect(boundary).toBeDefined();
      expect(boundary!.sessionId).toBe(session.sessionId);

      // Timestamp should be within the compaction window
      const eventTime = new Date(boundary!.timestamp).getTime();
      expect(eventTime).toBeGreaterThanOrEqual(beforeCompact);
      expect(eventTime).toBeLessThanOrEqual(afterCompact);
    });
  });

  describe('compact.summary event', () => {
    it('contains summary content', async () => {
      const session = await orchestrator.sessions.createSession({
        workingDirectory: testDir,
      });

      injectMessagesIntoSession(
        orchestrator,
        session.sessionId,
        generateTestMessages(100)
      );

      await orchestrator.context.confirmCompaction(session.sessionId);

      const events = await eventStore.getEventsBySession(
        session.sessionId as SessionId
      );
      const summary = events.find(e => e.type === 'compact.summary');

      expect(summary).toBeDefined();
      expect(summary!.payload.summary).toBeDefined();
      expect(typeof summary!.payload.summary).toBe('string');
      expect(summary!.payload.summary.length).toBeGreaterThan(0);
    });

    it('stores custom edited summary when provided', async () => {
      const session = await orchestrator.sessions.createSession({
        workingDirectory: testDir,
      });

      injectMessagesIntoSession(
        orchestrator,
        session.sessionId,
        generateTestMessages(100)
      );

      const customSummary = 'Custom user-edited summary for EventStore test';
      await orchestrator.context.confirmCompaction(session.sessionId, {
        editedSummary: customSummary,
      });

      const events = await eventStore.getEventsBySession(
        session.sessionId as SessionId
      );
      const summary = events.find(e => e.type === 'compact.summary');

      expect(summary).toBeDefined();
      expect(summary!.payload.summary).toBe(customSummary);
    });

    it('chains from compact.boundary event', async () => {
      const session = await orchestrator.sessions.createSession({
        workingDirectory: testDir,
      });

      injectMessagesIntoSession(
        orchestrator,
        session.sessionId,
        generateTestMessages(100)
      );

      await orchestrator.context.confirmCompaction(session.sessionId);

      const events = await eventStore.getEventsBySession(
        session.sessionId as SessionId
      );
      const boundary = events.find(e => e.type === 'compact.boundary');
      const summary = events.find(e => e.type === 'compact.summary');

      expect(boundary).toBeDefined();
      expect(summary).toBeDefined();

      // Summary should come after boundary in event order
      const boundaryIndex = events.indexOf(boundary!);
      const summaryIndex = events.indexOf(summary!);
      expect(summaryIndex).toBeGreaterThan(boundaryIndex);

      // Summary should have boundary as parent (or be close in chain)
      // Note: actual parentId chain depends on implementation
    });
  });

  describe('event ordering', () => {
    it('compaction events come after message events', async () => {
      const session = await orchestrator.sessions.createSession({
        workingDirectory: testDir,
      });

      injectMessagesIntoSession(
        orchestrator,
        session.sessionId,
        generateTestMessages(50)
      );

      await orchestrator.context.confirmCompaction(session.sessionId);

      const events = await eventStore.getEventsBySession(
        session.sessionId as SessionId
      );

      // Find all event types
      const sessionStartIndex = events.findIndex(e => e.type === 'session.start');
      const boundaryIndex = events.findIndex(e => e.type === 'compact.boundary');
      const summaryIndex = events.findIndex(e => e.type === 'compact.summary');

      // Session start should be first
      expect(sessionStartIndex).toBe(0);

      // Compaction events should be after session start
      expect(boundaryIndex).toBeGreaterThan(sessionStartIndex);
      expect(summaryIndex).toBeGreaterThan(sessionStartIndex);
    });

    it('multiple compactions create multiple event pairs', async () => {
      const session = await orchestrator.sessions.createSession({
        workingDirectory: testDir,
      });

      // First compaction
      injectMessagesIntoSession(
        orchestrator,
        session.sessionId,
        generateTestMessages(150)
      );
      await orchestrator.context.confirmCompaction(session.sessionId);

      // Grow back and compact again
      const active = (orchestrator as any).activeSessions.get(session.sessionId);
      const currentMessages = active.agent.getContextManager().getMessages();
      const additionalMessages = generateTestMessages(150);
      const combinedMessages = [...currentMessages, ...additionalMessages];
      active.agent.getContextManager().setMessages(combinedMessages);
      // Set API tokens to simulate what happens after a turn completes
      active.agent.getContextManager().setApiContextTokens(
        BASE_CONTEXT_OVERHEAD + estimateMessageTokens(combinedMessages.length / 2)
      );
      await orchestrator.context.confirmCompaction(session.sessionId);

      // Check events
      const events = await eventStore.getEventsBySession(
        session.sessionId as SessionId
      );

      const boundaryEvents = events.filter(e => e.type === 'compact.boundary');
      const summaryEvents = events.filter(e => e.type === 'compact.summary');

      // Should have 2 of each
      expect(boundaryEvents.length).toBe(2);
      expect(summaryEvents.length).toBe(2);
    });
  });

  describe('event data integrity', () => {
    it('events have valid UUIDs', async () => {
      const session = await orchestrator.sessions.createSession({
        workingDirectory: testDir,
      });

      injectMessagesIntoSession(
        orchestrator,
        session.sessionId,
        generateTestMessages(100)
      );

      await orchestrator.context.confirmCompaction(session.sessionId);

      const events = await eventStore.getEventsBySession(
        session.sessionId as SessionId
      );
      const compactionEvents = events.filter(
        e => e.type === 'compact.boundary' || e.type === 'compact.summary'
      );

      for (const event of compactionEvents) {
        // Event ID format: evt_<hex>
        expect(event.id).toMatch(/^evt_[0-9a-f]+$/i);
      }
    });

    it('events survive orchestrator restart', async () => {
      const session = await orchestrator.sessions.createSession({
        workingDirectory: testDir,
      });

      injectMessagesIntoSession(
        orchestrator,
        session.sessionId,
        generateTestMessages(100)
      );

      await orchestrator.context.confirmCompaction(session.sessionId);

      // Get events before shutdown
      const eventsBefore = await eventStore.getEventsBySession(
        session.sessionId as SessionId
      );
      const compactionCountBefore = eventsBefore.filter(
        e => e.type === 'compact.boundary' || e.type === 'compact.summary'
      ).length;

      // Shutdown and recreate
      await orchestrator.shutdown();
      await eventStore.close();

      // Reopen
      const newEventStore = new EventStore(path.join(testDir, 'events.db'));
      await newEventStore.initialize();

      // Verify events are still there
      const eventsAfter = await newEventStore.getEventsBySession(
        session.sessionId as SessionId
      );
      const compactionCountAfter = eventsAfter.filter(
        e => e.type === 'compact.boundary' || e.type === 'compact.summary'
      ).length;

      expect(compactionCountAfter).toBe(compactionCountBefore);

      await newEventStore.close();
    });
  });

  describe('compaction_completed event emission', () => {
    it('emits compaction_completed event on success', async () => {
      const session = await orchestrator.sessions.createSession({
        workingDirectory: testDir,
      });

      injectMessagesIntoSession(
        orchestrator,
        session.sessionId,
        generateTestMessages(100)
      );

      const emittedEvents: any[] = [];
      orchestrator.on('compaction_completed', e => emittedEvents.push(e));

      await orchestrator.context.confirmCompaction(session.sessionId);

      expect(emittedEvents.length).toBe(1);
      expect(emittedEvents[0].sessionId).toBe(session.sessionId);
      expect(emittedEvents[0].tokensBefore).toBeGreaterThan(0);
      expect(emittedEvents[0].tokensAfter).toBeLessThan(emittedEvents[0].tokensBefore);
    });

    it('includes token reduction in emitted event', async () => {
      const session = await orchestrator.sessions.createSession({
        workingDirectory: testDir,
      });

      injectMessagesIntoSession(
        orchestrator,
        session.sessionId,
        generateTestMessages(150)
      );

      const emittedEvents: any[] = [];
      orchestrator.on('compaction_completed', e => emittedEvents.push(e));

      await orchestrator.context.confirmCompaction(session.sessionId);

      expect(emittedEvents[0].tokensBefore).toBeDefined();
      expect(emittedEvents[0].tokensAfter).toBeDefined();
      expect(emittedEvents[0].tokensAfter).toBeLessThan(emittedEvents[0].tokensBefore);
    });
  });

  describe('queryable metadata', () => {
    it('compaction events can be queried by type', async () => {
      const session = await orchestrator.sessions.createSession({
        workingDirectory: testDir,
      });

      injectMessagesIntoSession(
        orchestrator,
        session.sessionId,
        generateTestMessages(100)
      );

      await orchestrator.context.confirmCompaction(session.sessionId);

      // Query all events and filter by type
      const events = await eventStore.getEventsBySession(
        session.sessionId as SessionId
      );

      const boundaries = events.filter(e => e.type === 'compact.boundary');
      const summaries = events.filter(e => e.type === 'compact.summary');

      expect(boundaries.length).toBe(1);
      expect(summaries.length).toBe(1);
    });

    it('compaction stats can be aggregated from events', async () => {
      const session = await orchestrator.sessions.createSession({
        workingDirectory: testDir,
      });

      // Multiple compaction cycles
      for (let i = 0; i < 3; i++) {
        const active = (orchestrator as any).activeSessions.get(session.sessionId);
        const messages = generateTestMessages(150);
        const cm = active.agent.getContextManager();
        cm.setMessages(messages);
        // Set API tokens to simulate what happens after a turn completes
        cm.setApiContextTokens(BASE_CONTEXT_OVERHEAD + estimateMessageTokens(messages.length / 2));
        await orchestrator.context.confirmCompaction(session.sessionId);
      }

      // Query and aggregate
      const events = await eventStore.getEventsBySession(
        session.sessionId as SessionId
      );
      const boundaries = events.filter(e => e.type === 'compact.boundary');

      // Calculate total tokens saved
      const totalSaved = boundaries.reduce((sum, b) => {
        return sum + (b.payload.originalTokens - b.payload.compactedTokens);
      }, 0);

      expect(totalSaved).toBeGreaterThan(0);

      // Calculate average compression ratio from token counts
      const avgRatio =
        boundaries.reduce((sum, b) => sum + (b.payload.compactedTokens / b.payload.originalTokens), 0) /
        boundaries.length;

      expect(avgRatio).toBeGreaterThan(0);
      expect(avgRatio).toBeLessThan(1);
    });
  });
});
