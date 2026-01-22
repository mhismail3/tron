/**
 * @fileoverview EventPersister Unit Tests
 *
 * Tests for the EventPersister module which handles linearized event persistence.
 * These tests define the contract for EventPersister:
 *
 * 1. Events are appended in order with correct parentId chaining
 * 2. Concurrent appends serialize correctly (no spurious branching)
 * 3. Errors stop the chain to prevent orphaned events
 * 4. flush() waits for all pending appends
 * 5. getPendingHeadEventId() returns current head
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { EventStore, type SessionId, type EventId } from '../../src/index.js';
import path from 'path';
import os from 'os';
import fs from 'fs';
import {
  EventPersister,
  createEventPersister,
  type EventPersisterConfig,
} from '../../src/orchestrator/event-persister.js';

describe('EventPersister', () => {
  let eventStore: EventStore;
  let testDir: string;
  let sessionId: SessionId;
  let initialHeadEventId: EventId;

  beforeEach(async () => {
    // Create temp directory and EventStore
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tron-event-persister-test-'));
    const dbPath = path.join(testDir, 'events.db');
    eventStore = new EventStore(dbPath);
    await eventStore.initialize();

    // Create a session to get initial head event ID
    const result = await eventStore.createSession({
      workspacePath: '/test/project',
      workingDirectory: '/test/project',
      model: 'claude-sonnet-4-20250514',
    });
    sessionId = result.session.id;
    initialHeadEventId = result.rootEvent.id;
  });

  afterEach(async () => {
    await eventStore.close();
    fs.rmSync(testDir, { recursive: true, force: true });
  });

  describe('Basic operations', () => {
    it('should create persister with initial head event ID', () => {
      const persister = createEventPersister({
        eventStore,
        sessionId,
        initialHeadEventId,
      });

      expect(persister.getPendingHeadEventId()).toBe(initialHeadEventId);
      expect(persister.hasError()).toBe(false);
    });

    it('should append event and update pending head', async () => {
      const persister = createEventPersister({
        eventStore,
        sessionId,
        initialHeadEventId,
      });

      // Append an event
      const event = await persister.appendAsync('message.user', {
        content: 'Hello world',
      });

      expect(event).not.toBeNull();
      expect(event!.type).toBe('message.user');
      expect(event!.parentId).toBe(initialHeadEventId);
      expect(persister.getPendingHeadEventId()).toBe(event!.id);
    });

    it('should chain multiple events correctly', async () => {
      const persister = createEventPersister({
        eventStore,
        sessionId,
        initialHeadEventId,
      });

      // Append first event
      const event1 = await persister.appendAsync('message.user', { content: 'First' });

      // Append second event
      const event2 = await persister.appendAsync('message.assistant', {
        content: [{ type: 'text', text: 'Second' }],
      });

      // Verify chain
      expect(event1!.parentId).toBe(initialHeadEventId);
      expect(event2!.parentId).toBe(event1!.id);
      expect(persister.getPendingHeadEventId()).toBe(event2!.id);
    });
  });

  describe('Fire-and-forget append', () => {
    it('should append without waiting', async () => {
      const persister = createEventPersister({
        eventStore,
        sessionId,
        initialHeadEventId,
      });

      // Fire and forget - returns void
      persister.append('message.user', { content: 'Fire and forget' });

      // Head should NOT be updated yet (async)
      // We need to flush to ensure it's written
      await persister.flush();

      // Now head should be updated
      expect(persister.getPendingHeadEventId()).not.toBe(initialHeadEventId);
    });

    it('should invoke onCreated callback when event is created', async () => {
      const persister = createEventPersister({
        eventStore,
        sessionId,
        initialHeadEventId,
      });

      let createdEvent: any = null;
      persister.append('message.user', { content: 'With callback' }, (event) => {
        createdEvent = event;
      });

      await persister.flush();

      expect(createdEvent).not.toBeNull();
      expect(createdEvent.type).toBe('message.user');
    });
  });

  describe('Linearization (concurrent append handling)', () => {
    it('should serialize concurrent appends correctly', async () => {
      const persister = createEventPersister({
        eventStore,
        sessionId,
        initialHeadEventId,
      });

      // Fire off multiple appends rapidly (simulating concurrent events)
      persister.append('stream.turn_start', { turn: 1 });
      persister.append('tool.call', { toolCallId: 'tc_1', name: 'Read', arguments: {} });
      persister.append('tool.result', { toolCallId: 'tc_1', content: 'result', isError: false });
      persister.append('message.assistant', { content: [{ type: 'text', text: 'Done' }] });
      persister.append('stream.turn_end', { turn: 1 });

      // Wait for all to complete
      await persister.flush();

      // Verify the chain by walking ancestors
      const headId = persister.getPendingHeadEventId();
      const ancestors = await eventStore.getAncestors(headId);

      // Should have 6 events: session.start + 5 we added
      expect(ancestors.length).toBe(6);

      // Verify linear chain (each event's parent is the previous one)
      for (let i = 1; i < ancestors.length; i++) {
        expect(ancestors[i].parentId).toBe(ancestors[i - 1].id);
      }

      // Verify order
      expect(ancestors[0].type).toBe('session.start');
      expect(ancestors[1].type).toBe('stream.turn_start');
      expect(ancestors[2].type).toBe('tool.call');
      expect(ancestors[3].type).toBe('tool.result');
      expect(ancestors[4].type).toBe('message.assistant');
      expect(ancestors[5].type).toBe('stream.turn_end');
    });

    it('should not create spurious branches with rapid appends', async () => {
      const persister = createEventPersister({
        eventStore,
        sessionId,
        initialHeadEventId,
      });

      // This is the key test - previously this would cause branching
      // because all appends would capture the same parentId
      const appendCount = 10;
      for (let i = 0; i < appendCount; i++) {
        persister.append('message.user', { content: `Message ${i}` });
      }

      await persister.flush();

      // Get the session and verify head
      const session = await eventStore.getSession(sessionId);

      // Walk from head to root - should be exactly appendCount + 1 events
      const ancestors = await eventStore.getAncestors(persister.getPendingHeadEventId());
      expect(ancestors.length).toBe(appendCount + 1); // +1 for session.start
    });
  });

  describe('Error handling', () => {
    it('should track errors and stop subsequent appends', async () => {
      const persister = createEventPersister({
        eventStore,
        sessionId,
        initialHeadEventId,
      });

      // First append should succeed
      const event1 = await persister.appendAsync('message.user', { content: 'First' });
      expect(event1).not.toBeNull();
      expect(persister.hasError()).toBe(false);

      // Now close the event store to cause errors
      await eventStore.close();

      // Next append should fail
      const event2 = await persister.appendAsync('message.assistant', {
        content: [{ type: 'text', text: 'Should fail' }],
      });
      expect(event2).toBeNull();
      expect(persister.hasError()).toBe(true);

      // Reopen for cleanup
      await eventStore.initialize();
    });

    it('should skip fire-and-forget appends after error', async () => {
      const persister = createEventPersister({
        eventStore,
        sessionId,
        initialHeadEventId,
      });

      // Close store to cause error
      await eventStore.close();

      // Try to append - should fail and set error
      await persister.appendAsync('message.user', { content: 'Will fail' });
      expect(persister.hasError()).toBe(true);

      // Reopen store
      await eventStore.initialize();

      // Fire and forget should be skipped due to prior error
      const headBefore = persister.getPendingHeadEventId();
      persister.append('message.user', { content: 'Should be skipped' });
      await persister.flush();

      // Head should not change
      expect(persister.getPendingHeadEventId()).toBe(headBefore);
    });

    it('should return error message via getError()', async () => {
      const persister = createEventPersister({
        eventStore,
        sessionId,
        initialHeadEventId,
      });

      // Initially no error
      expect(persister.getError()).toBeUndefined();

      // Close store to cause error
      await eventStore.close();

      // Try to append
      await persister.appendAsync('message.user', { content: 'Will fail' });

      // Error should be set
      const error = persister.getError();
      expect(error).toBeDefined();
      expect(error).toBeInstanceOf(Error);

      // Reopen for cleanup
      await eventStore.initialize();
    });
  });

  describe('flush()', () => {
    it('should wait for all pending appends', async () => {
      const persister = createEventPersister({
        eventStore,
        sessionId,
        initialHeadEventId,
      });

      const createdIds: string[] = [];

      // Fire off multiple appends
      persister.append('message.user', { content: 'One' }, (e) => createdIds.push(e.id));
      persister.append('message.assistant', { content: [{ type: 'text', text: 'Two' }] }, (e) => createdIds.push(e.id));
      persister.append('message.user', { content: 'Three' }, (e) => createdIds.push(e.id));

      // Before flush, callbacks may not have fired
      // After flush, all should be complete
      await persister.flush();

      expect(createdIds.length).toBe(3);
    });

    it('should be safe to call flush multiple times', async () => {
      const persister = createEventPersister({
        eventStore,
        sessionId,
        initialHeadEventId,
      });

      persister.append('message.user', { content: 'Test' });

      // Multiple flushes should all resolve
      await Promise.all([
        persister.flush(),
        persister.flush(),
        persister.flush(),
      ]);

      // Should not throw
      expect(true).toBe(true);
    });

    it('should resolve immediately if no pending appends', async () => {
      const persister = createEventPersister({
        eventStore,
        sessionId,
        initialHeadEventId,
      });

      // No appends, flush should resolve immediately
      const start = Date.now();
      await persister.flush();
      const elapsed = Date.now() - start;

      // Should be nearly instant
      expect(elapsed).toBeLessThan(100);
    });
  });

  describe('appendMultiple()', () => {
    it('should append multiple events atomically', async () => {
      const persister = createEventPersister({
        eventStore,
        sessionId,
        initialHeadEventId,
      });

      // Append multiple events at once
      const events = await persister.appendMultiple([
        { type: 'compact.boundary', payload: { reason: 'context_limit' } },
        { type: 'compact.summary', payload: { summary: 'Previous conversation...' } },
      ]);

      expect(events.length).toBe(2);
      expect(events[0]!.type).toBe('compact.boundary');
      expect(events[1]!.type).toBe('compact.summary');
      expect(events[1]!.parentId).toBe(events[0]!.id);
    });

    it('should chain multiple events correctly with existing events', async () => {
      const persister = createEventPersister({
        eventStore,
        sessionId,
        initialHeadEventId,
      });

      // First add a single event
      const firstEvent = await persister.appendAsync('message.user', { content: 'Hello' });

      // Then add multiple
      const events = await persister.appendMultiple([
        { type: 'message.assistant', payload: { content: [{ type: 'text', text: 'Hi' }] } },
        { type: 'message.user', payload: { content: 'Follow up' } },
      ]);

      // First of multiple should chain to the single event
      expect(events[0]!.parentId).toBe(firstEvent!.id);
    });
  });
});
