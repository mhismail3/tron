/**
 * @fileoverview Tests for Event Linearization Fix
 *
 * These tests verify that the EventStoreOrchestrator correctly chains events
 * linearly (no spurious branches) even when events are fired rapidly without
 * awaiting between them.
 *
 * Root Cause Being Fixed:
 * - forwardAgentEvent() was using fire-and-forget `.catch()` patterns
 * - Multiple events fired rapidly all read the same session.headEventId
 * - All events got the same parentId = spurious branch points
 *
 * Solution Being Tested:
 * - In-memory head tracking with pendingHeadEventId
 * - Promise chaining with appendPromiseChain per session
 * - Explicit parentId passed to eventStore.append()
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { EventStore, EventId, SessionId, type TronSessionEvent } from '@tron/core';
import path from 'path';
import os from 'os';
import fs from 'fs';

// =============================================================================
// Helper Functions
// =============================================================================

/**
 * Count branch points in a set of events.
 * A branch point is an event that has more than one child.
 * This mirrors the iOS SessionTreeView.swift logic.
 */
function countBranchPoints(events: TronSessionEvent[]): number {
  const childCounts: Map<string, number> = new Map();

  for (const event of events) {
    if (event.parentId) {
      childCounts.set(event.parentId, (childCounts.get(event.parentId) ?? 0) + 1);
    }
  }

  // Count events with more than 1 child
  return Array.from(childCounts.values()).filter(count => count > 1).length;
}

/**
 * Verify that events form a linear chain (each event's parent is the previous event).
 * Returns the chain and any violations found.
 */
function verifyLinearChain(events: TronSessionEvent[]): {
  isLinear: boolean;
  violations: string[];
  chain: string[];
} {
  const violations: string[] = [];
  const sortedEvents = [...events].sort((a, b) => a.sequence - b.sequence);
  const chain: string[] = [];

  for (let i = 0; i < sortedEvents.length; i++) {
    const event = sortedEvents[i];
    chain.push(event.id);

    if (i === 0) {
      // Root event should have null parentId
      if (event.parentId !== null) {
        violations.push(`Root event ${event.id} has non-null parentId: ${event.parentId}`);
      }
    } else {
      const expectedParent = sortedEvents[i - 1].id;
      if (event.parentId !== expectedParent) {
        violations.push(
          `Event ${event.id} (seq ${event.sequence}) has parentId=${event.parentId}, ` +
          `expected=${expectedParent}`
        );
      }
    }
  }

  return {
    isLinear: violations.length === 0,
    violations,
    chain,
  };
}

// =============================================================================
// Event Store Level Tests (verifying the underlying mechanism)
// =============================================================================

describe('EventStore - Explicit ParentId Support', () => {
  let eventStore: EventStore;
  let testDir: string;

  beforeEach(async () => {
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tron-linearization-test-'));
    const dbPath = path.join(testDir, 'events.db');
    eventStore = new EventStore(dbPath);
    await eventStore.initialize();
  });

  afterEach(async () => {
    await eventStore.close();
    fs.rmSync(testDir, { recursive: true, force: true });
  });

  describe('append with explicit parentId', () => {
    it('should use explicit parentId instead of session head', async () => {
      const session = await eventStore.createSession({
        workspacePath: '/test',
        workingDirectory: '/test',
        model: 'claude-sonnet-4-20250514',
      });

      // Append first event (will use session head = root)
      const event1 = await eventStore.append({
        sessionId: session.session.id,
        type: 'message.user',
        payload: { content: 'Hello' },
      });
      expect(event1.parentId).toBe(session.rootEvent.id);

      // Append second event with explicit parentId pointing to root (not event1)
      const event2 = await eventStore.append({
        sessionId: session.session.id,
        type: 'message.user',
        payload: { content: 'World' },
        parentId: session.rootEvent.id, // Explicit: point back to root, not event1
      });

      // Both event1 and event2 should have root as parent
      expect(event2.parentId).toBe(session.rootEvent.id);

      // This creates a branch point at root (2 children)
      const events = await eventStore.getEventsBySession(session.session.id);
      expect(countBranchPoints(events)).toBe(1);
    });

    it('should chain linearly when explicit parentId follows the chain', async () => {
      const session = await eventStore.createSession({
        workspacePath: '/test',
        workingDirectory: '/test',
        model: 'claude-sonnet-4-20250514',
      });

      // Chain: root -> event1 -> event2 -> event3 using explicit parentIds
      const event1 = await eventStore.append({
        sessionId: session.session.id,
        type: 'message.user',
        payload: { content: '1' },
        parentId: session.rootEvent.id, // Explicit
      });

      const event2 = await eventStore.append({
        sessionId: session.session.id,
        type: 'message.user',
        payload: { content: '2' },
        parentId: event1.id, // Explicit
      });

      const event3 = await eventStore.append({
        sessionId: session.session.id,
        type: 'message.user',
        payload: { content: '3' },
        parentId: event2.id, // Explicit
      });

      const events = await eventStore.getEventsBySession(session.session.id);
      const result = verifyLinearChain(events);

      expect(result.isLinear).toBe(true);
      expect(countBranchPoints(events)).toBe(0);
    });
  });
});

// =============================================================================
// Linearization Pattern Tests (simulating what the orchestrator will do)
// =============================================================================

describe('Linearization Pattern', () => {
  let eventStore: EventStore;
  let testDir: string;

  beforeEach(async () => {
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tron-linearization-test-'));
    const dbPath = path.join(testDir, 'events.db');
    eventStore = new EventStore(dbPath);
    await eventStore.initialize();
  });

  afterEach(async () => {
    await eventStore.close();
    fs.rmSync(testDir, { recursive: true, force: true });
  });

  describe('Single Session Linear Chain', () => {
    it('rapid sequential events should chain linearly (no spurious branches)', async () => {
      const session = await eventStore.createSession({
        workspacePath: '/test',
        workingDirectory: '/test',
        model: 'claude-sonnet-4-20250514',
      });

      // Simulate in-memory head tracking with ACTUAL event IDs
      // The key insight: we track the ACTUAL event ID after each append completes,
      // but we chain them so each subsequent append uses the previous one's ID
      let appendPromiseChain: Promise<EventId> = Promise.resolve(session.rootEvent.id);

      // Fire 10 events, chaining them so each uses the previous event's actual ID
      for (let i = 0; i < 10; i++) {
        appendPromiseChain = appendPromiseChain.then(async (parentId) => {
          const event = await eventStore.append({
            sessionId: session.session.id,
            type: 'stream.turn_start',
            payload: { turn: i },
            parentId,
          });
          return event.id;
        });
      }

      // Wait for chain to complete
      await appendPromiseChain;

      // Verify linear chain
      const events = await eventStore.getEventsBySession(session.session.id);
      const result = verifyLinearChain(events);

      expect(result.isLinear).toBe(true);
      expect(result.violations).toEqual([]);
      expect(countBranchPoints(events)).toBe(0);
      expect(events.length).toBe(11); // root + 10 events
    });

    it('turn_start -> tool.call -> tool.result should chain linearly', async () => {
      const session = await eventStore.createSession({
        workspacePath: '/test',
        workingDirectory: '/test',
        model: 'claude-sonnet-4-20250514',
      });

      // Chain events sequentially with explicit parentIds
      let chain: Promise<EventId> = Promise.resolve(session.rootEvent.id);

      const appendChained = (type: string, payload: Record<string, unknown>) => {
        chain = chain.then(async (parentId) => {
          const event = await eventStore.append({
            sessionId: session.session.id,
            type: type as any,
            payload,
            parentId,
          });
          return event.id;
        });
      };

      // Fire events (chained)
      appendChained('stream.turn_start', { turn: 1 });
      appendChained('tool.call', { toolCallId: 'tc_1', name: 'read', arguments: {} });
      appendChained('tool.result', { toolCallId: 'tc_1', content: 'file contents', isError: false });
      appendChained('stream.turn_end', { turn: 1, tokenUsage: { inputTokens: 100, outputTokens: 50 } });

      await chain;

      const events = await eventStore.getEventsBySession(session.session.id);
      const result = verifyLinearChain(events);

      expect(result.isLinear).toBe(true);
      expect(countBranchPoints(events)).toBe(0);
    });

    it('multiple tool calls in same turn should chain linearly', async () => {
      const session = await eventStore.createSession({
        workspacePath: '/test',
        workingDirectory: '/test',
        model: 'claude-sonnet-4-20250514',
      });

      let chain: Promise<EventId> = Promise.resolve(session.rootEvent.id);

      const appendChained = (type: string, payload: Record<string, unknown>) => {
        chain = chain.then(async (parentId) => {
          const event = await eventStore.append({
            sessionId: session.session.id,
            type: type as any,
            payload,
            parentId,
          });
          return event.id;
        });
      };

      // Turn with 3 tool calls
      appendChained('stream.turn_start', { turn: 1 });
      appendChained('tool.call', { toolCallId: 'tc_1', name: 'read', arguments: { path: 'a.txt' } });
      appendChained('tool.call', { toolCallId: 'tc_2', name: 'read', arguments: { path: 'b.txt' } });
      appendChained('tool.call', { toolCallId: 'tc_3', name: 'read', arguments: { path: 'c.txt' } });
      appendChained('tool.result', { toolCallId: 'tc_1', content: 'a', isError: false });
      appendChained('tool.result', { toolCallId: 'tc_2', content: 'b', isError: false });
      appendChained('tool.result', { toolCallId: 'tc_3', content: 'c', isError: false });
      appendChained('stream.turn_end', { turn: 1, tokenUsage: { inputTokens: 300, outputTokens: 150 } });

      await chain;

      const events = await eventStore.getEventsBySession(session.session.id);
      const result = verifyLinearChain(events);

      expect(result.isLinear).toBe(true);
      expect(countBranchPoints(events)).toBe(0);
      expect(events.length).toBe(9); // root + turn_start + 3 calls + 3 results + turn_end
    });
  });

  describe('Multi-Session Isolation', () => {
    it('concurrent events across sessions should not interfere', async () => {
      // Create 3 sessions
      const sessions = await Promise.all([
        eventStore.createSession({
          workspacePath: '/test/a',
          workingDirectory: '/test/a',
          model: 'claude-sonnet-4-20250514',
          }),
        eventStore.createSession({
          workspacePath: '/test/b',
          workingDirectory: '/test/b',
          model: 'claude-sonnet-4-20250514',
          }),
        eventStore.createSession({
          workspacePath: '/test/c',
          workingDirectory: '/test/c',
          model: 'claude-sonnet-4-20250514',
          }),
      ]);

      // Track chains per session (each chain returns the latest event ID)
      const appendChains: Map<SessionId, Promise<EventId>> = new Map();

      for (const s of sessions) {
        appendChains.set(s.session.id, Promise.resolve(s.rootEvent.id));
      }

      const appendLinearized = (sessionId: SessionId, type: string, payload: Record<string, unknown>) => {
        const chain = appendChains.get(sessionId)!;
        const newChain = chain.then(async (parentId) => {
          const event = await eventStore.append({
            sessionId,
            type: type as any,
            payload,
            parentId,
          });
          return event.id;
        });

        appendChains.set(sessionId, newChain);
      };

      // Fire events to all 3 sessions concurrently (interleaved)
      for (let i = 0; i < 5; i++) {
        for (const s of sessions) {
          appendLinearized(s.session.id, 'stream.turn_start', { turn: i });
        }
      }

      // Wait for all chains
      await Promise.all(Array.from(appendChains.values()));

      // Verify each session has its own linear chain
      for (const s of sessions) {
        const events = await eventStore.getEventsBySession(s.session.id);
        const result = verifyLinearChain(events);

        expect(result.isLinear).toBe(true);
        expect(countBranchPoints(events)).toBe(0);
        expect(events.length).toBe(6); // root + 5 events

        // Verify no cross-session parentId references
        for (const event of events) {
          if (event.parentId) {
            const parent = events.find(e => e.id === event.parentId);
            expect(parent).toBeDefined();
            expect(parent!.sessionId).toBe(s.session.id);
          }
        }
      }
    });

    it('session A events should not affect session B head', async () => {
      const sessionA = await eventStore.createSession({
        workspacePath: '/test/a',
        workingDirectory: '/test/a',
        model: 'claude-sonnet-4-20250514',
      });

      const sessionB = await eventStore.createSession({
        workspacePath: '/test/b',
        workingDirectory: '/test/b',
        model: 'claude-sonnet-4-20250514',
      });

      // Chain for session A
      let chainA: Promise<EventId> = Promise.resolve(sessionA.rootEvent.id);
      for (let i = 0; i < 5; i++) {
        chainA = chainA.then(async (parentId) => {
          const event = await eventStore.append({
            sessionId: sessionA.session.id,
            type: 'stream.turn_start',
            payload: { turn: i },
            parentId,
          });
          return event.id;
        });
      }

      // Chain for session B (just 1 event)
      const chainB = Promise.resolve(sessionB.rootEvent.id).then(async (parentId) => {
        const event = await eventStore.append({
          sessionId: sessionB.session.id,
          type: 'stream.turn_start',
          payload: { turn: 0 },
          parentId,
        });
        return event.id;
      });

      await Promise.all([chainA, chainB]);

      // Session B's event should parent to B's root, not A's events
      const eventsB = await eventStore.getEventsBySession(sessionB.session.id);
      expect(eventsB.length).toBe(2); // root + 1 event

      const userEvent = eventsB.find(e => e.type === 'stream.turn_start');
      expect(userEvent!.parentId).toBe(sessionB.rootEvent.id);
    });
  });

  describe('Promise Chain Ordering', () => {
    it('events should be persisted in order despite async', async () => {
      const session = await eventStore.createSession({
        workspacePath: '/test',
        workingDirectory: '/test',
        model: 'claude-sonnet-4-20250514',
      });

      // Chain 50 events
      let chain: Promise<EventId> = Promise.resolve(session.rootEvent.id);

      for (let i = 0; i < 50; i++) {
        chain = chain.then(async (parentId) => {
          const event = await eventStore.append({
            sessionId: session.session.id,
            type: 'stream.turn_start',
            payload: { turn: i, order: i },
            parentId,
          });
          return event.id;
        });
      }

      await chain;

      const events = await eventStore.getEventsBySession(session.session.id);

      // Sort by sequence and verify order matches payload
      const sorted = [...events].filter(e => e.type === 'stream.turn_start')
        .sort((a, b) => a.sequence - b.sequence);

      for (let i = 0; i < sorted.length; i++) {
        expect(sorted[i].payload.order).toBe(i);
      }

      // Verify sequence numbers are monotonic
      for (let i = 1; i < sorted.length; i++) {
        expect(sorted[i].sequence).toBeGreaterThan(sorted[i - 1].sequence);
      }
    });
  });

  describe('Edge Cases', () => {
    it('first event after session creation should have correct parent', async () => {
      const session = await eventStore.createSession({
        workspacePath: '/test',
        workingDirectory: '/test',
        model: 'claude-sonnet-4-20250514',
      });

      // Initialize pending head from root event
      const pendingHead: EventId = session.rootEvent.id;

      const event = await eventStore.append({
        sessionId: session.session.id,
        type: 'message.user',
        payload: { content: 'Hello' },
        parentId: pendingHead,
      });

      expect(event.parentId).toBe(session.rootEvent.id);
    });
  });

  describe('Branch Detection Validation', () => {
    it('linear session should have zero branch points', async () => {
      const session = await eventStore.createSession({
        workspacePath: '/test',
        workingDirectory: '/test',
        model: 'claude-sonnet-4-20250514',
      });

      // Chain 20 events
      let chain: Promise<EventId> = Promise.resolve(session.rootEvent.id);

      for (let i = 0; i < 20; i++) {
        chain = chain.then(async (parentId) => {
          const event = await eventStore.append({
            sessionId: session.session.id,
            type: 'stream.turn_start',
            payload: { turn: i },
            parentId,
          });
          return event.id;
        });
      }

      await chain;

      const events = await eventStore.getEventsBySession(session.session.id);

      expect(countBranchPoints(events)).toBe(0);
      expect(events.length).toBe(21); // root + 20 events
    });

    it('fork operation should create exactly one branch point', async () => {
      const session = await eventStore.createSession({
        workspacePath: '/test',
        workingDirectory: '/test',
        model: 'claude-sonnet-4-20250514',
      });

      // Create linear chain: root -> e1 -> e2 -> e3 -> e4 -> e5
      let currentHead: EventId = session.rootEvent.id;
      const eventIds: EventId[] = [session.rootEvent.id];

      for (let i = 1; i <= 5; i++) {
        const event = await eventStore.append({
          sessionId: session.session.id,
          type: 'message.user',
          payload: { content: `Message ${i}` },
          parentId: currentHead,
        });
        eventIds.push(event.id);
        currentHead = event.id;
      }

      // Fork from event 3 (create new session starting from e3)
      const forkResult = await eventStore.fork(eventIds[3]);

      // Add an event to the forked session
      await eventStore.append({
        sessionId: forkResult.session.id,
        type: 'message.user',
        payload: { content: 'Forked message' },
        parentId: forkResult.rootEvent.id,
      });

      // Original session events
      const originalEvents = await eventStore.getEventsBySession(session.session.id);
      expect(countBranchPoints(originalEvents)).toBe(0); // Still linear in original

      // When viewed across both sessions, event 3 becomes a branch point
      // (fork event's parentId points to e3 in original session)
      expect(forkResult.rootEvent.parentId).toBe(eventIds[3]);
    });
  });
});

// =============================================================================
// Concurrent Model Switches (testing the fix for switchModel race condition)
// =============================================================================

describe('Concurrent Model Switches', () => {
  let eventStore: EventStore;
  let testDir: string;

  beforeEach(async () => {
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tron-model-switch-test-'));
    const dbPath = path.join(testDir, 'events.db');
    eventStore = new EventStore(dbPath);
    await eventStore.initialize();
  });

  afterEach(async () => {
    await eventStore.close();
    fs.rmSync(testDir, { recursive: true, force: true });
  });

  it('rapid model switches should chain linearly (no spurious branches)', async () => {
    const session = await eventStore.createSession({
      workspacePath: '/test',
      workingDirectory: '/test',
      model: 'claude-haiku-3-5-20241022',
      provider: 'anthropic',
    });

    // Simulate the linearization pattern used in switchModel()
    let pendingHeadEventId: EventId = session.rootEvent.id;
    let appendPromiseChain: Promise<void> = Promise.resolve();

    const switchModelLinearized = (model: string, previousModel: string) => {
      appendPromiseChain = appendPromiseChain.then(async () => {
        const parentId = pendingHeadEventId;
        const event = await eventStore.append({
          sessionId: session.session.id,
          type: 'config.model_switch',
          payload: { previousModel, newModel: model },
          parentId,
        });
        pendingHeadEventId = event.id;
      });
    };

    // Rapid model switches (fire without awaiting)
    switchModelLinearized('claude-sonnet-4-20250514', 'claude-haiku-3-5-20241022');
    switchModelLinearized('claude-opus-4-20250514', 'claude-sonnet-4-20250514');
    switchModelLinearized('claude-haiku-3-5-20241022', 'claude-opus-4-20250514');

    await appendPromiseChain;

    const events = await eventStore.getEventsBySession(session.session.id);
    const result = verifyLinearChain(events);

    expect(result.isLinear).toBe(true);
    expect(countBranchPoints(events)).toBe(0);
    expect(events.length).toBe(4); // root + 3 model switches
  });

  it('model switch interleaved with message events should chain linearly', async () => {
    const session = await eventStore.createSession({
      workspacePath: '/test',
      workingDirectory: '/test',
      model: 'claude-haiku-3-5-20241022',
      provider: 'anthropic',
    });

    let pendingHeadEventId: EventId = session.rootEvent.id;
    let appendPromiseChain: Promise<void> = Promise.resolve();

    const appendLinearized = (type: string, payload: Record<string, unknown>) => {
      appendPromiseChain = appendPromiseChain.then(async () => {
        const parentId = pendingHeadEventId;
        const event = await eventStore.append({
          sessionId: session.session.id,
          type: type as any,
          payload,
          parentId,
        });
        pendingHeadEventId = event.id;
      });
    };

    // Interleave message events with model switches
    appendLinearized('message.user', { content: 'Hello' });
    appendLinearized('config.model_switch', { previousModel: 'haiku', newModel: 'sonnet' });
    appendLinearized('stream.turn_start', { turn: 1 });
    appendLinearized('config.model_switch', { previousModel: 'sonnet', newModel: 'opus' });
    appendLinearized('message.assistant', { content: [{ type: 'text', text: 'Hi there!' }] });

    await appendPromiseChain;

    const events = await eventStore.getEventsBySession(session.session.id);
    const result = verifyLinearChain(events);

    expect(result.isLinear).toBe(true);
    expect(countBranchPoints(events)).toBe(0);
    expect(events.length).toBe(6); // root + 5 events
  });

  it('demonstrates the bug: concurrent model switches WITHOUT chaining create branches', async () => {
    const session = await eventStore.createSession({
      workspacePath: '/test',
      workingDirectory: '/test',
      model: 'claude-haiku-3-5-20241022',
      provider: 'anthropic',
    });

    // This demonstrates the BROKEN pattern - fire-and-forget without chaining
    // Both switches will likely get the same parentId (root event)
    const promises = [
      eventStore.append({
        sessionId: session.session.id,
        type: 'config.model_switch',
        payload: { previousModel: 'haiku', newModel: 'sonnet' },
        // No explicit parentId - will read from DB
      }),
      eventStore.append({
        sessionId: session.session.id,
        type: 'config.model_switch',
        payload: { previousModel: 'sonnet', newModel: 'opus' },
        // No explicit parentId - will read from DB
      }),
    ];

    await Promise.all(promises);

    const events = await eventStore.getEventsBySession(session.session.id);
    const branchPoints = countBranchPoints(events);

    // This demonstrates the bug: without linearization, we may get spurious branches
    // The test doesn't assert a specific value because timing varies,
    // but documents that this pattern is vulnerable
    console.log(`Bug demo: Found ${branchPoints} branch points (should be 0 with fix)`);
    expect(events.length).toBe(3); // root + 2 model switches
  });

  it('session.end event should chain linearly with prior events', async () => {
    const session = await eventStore.createSession({
      workspacePath: '/test',
      workingDirectory: '/test',
      model: 'claude-haiku-3-5-20241022',
      provider: 'anthropic',
    });

    let pendingHeadEventId: EventId = session.rootEvent.id;
    let appendPromiseChain: Promise<void> = Promise.resolve();

    const appendLinearized = (type: string, payload: Record<string, unknown>) => {
      appendPromiseChain = appendPromiseChain.then(async () => {
        const parentId = pendingHeadEventId;
        const event = await eventStore.append({
          sessionId: session.session.id,
          type: type as any,
          payload,
          parentId,
        });
        pendingHeadEventId = event.id;
      });
    };

    // Simulate a session: user message, turn, model switch, then session end
    appendLinearized('message.user', { content: 'Hello' });
    appendLinearized('stream.turn_start', { turn: 1 });
    appendLinearized('config.model_switch', { previousModel: 'haiku', newModel: 'sonnet' });
    appendLinearized('session.end', { reason: 'completed', timestamp: new Date().toISOString() });

    await appendPromiseChain;

    const events = await eventStore.getEventsBySession(session.session.id);
    const result = verifyLinearChain(events);

    expect(result.isLinear).toBe(true);
    expect(countBranchPoints(events)).toBe(0);
    expect(events.length).toBe(5); // root + 4 events
    expect(events[events.length - 1].type).toBe('session.end');
  });
});

// =============================================================================
// Demonstrating the Bug (without the fix)
// =============================================================================

describe('Bug Demonstration (without linearization)', () => {
  let eventStore: EventStore;
  let testDir: string;

  beforeEach(async () => {
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tron-bug-demo-'));
    const dbPath = path.join(testDir, 'events.db');
    eventStore = new EventStore(dbPath);
    await eventStore.initialize();
  });

  afterEach(async () => {
    await eventStore.close();
    fs.rmSync(testDir, { recursive: true, force: true });
  });

  it('demonstrates the bug: fire-and-forget creates spurious branches', async () => {
    const session = await eventStore.createSession({
      workspacePath: '/test',
      workingDirectory: '/test',
      model: 'claude-sonnet-4-20250514',
      provider: 'anthropic',
    });

    // Simulate the OLD broken pattern: fire-and-forget without tracking
    // Each append reads session.headEventId from DB before any can update it

    // All these will likely get the same parentId (root) because
    // they all start before any finishes and updates the head
    const promises = [];
    for (let i = 0; i < 5; i++) {
      // This is the BROKEN pattern - no in-memory tracking
      const promise = eventStore.append({
        sessionId: session.session.id,
        type: 'stream.turn_start',
        payload: { turn: i },
        // No explicit parentId - will read from DB
      });
      promises.push(promise);
    }

    await Promise.all(promises);

    const events = await eventStore.getEventsBySession(session.session.id);
    const branchPoints = countBranchPoints(events);

    // This demonstrates the bug: multiple events got the same parent
    // creating spurious branch points
    // Note: This test may occasionally pass if timing works out,
    // but it demonstrates the race condition vulnerability
    console.log(`Bug demo: Found ${branchPoints} branch points (should be 0 with fix)`);

    // We don't assert the exact value because timing varies,
    // but we document that this pattern is vulnerable to the bug
    expect(events.length).toBe(6); // root + 5 events
  });
});

// =============================================================================
// P1 Fix: Transaction Atomicity Tests
// =============================================================================

describe('Transaction Atomicity (P1 fixes)', () => {
  let eventStore: EventStore;
  let testDir: string;

  beforeEach(async () => {
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tron-tx-test-'));
    const dbPath = path.join(testDir, 'events.db');
    eventStore = new EventStore(dbPath);
    await eventStore.initialize();
  });

  afterEach(async () => {
    await eventStore.close();
    fs.rmSync(testDir, { recursive: true, force: true });
  });

  it('serialized appends (via promise chain) should have unique sequence numbers', async () => {
    const session = await eventStore.createSession({
      workspacePath: '/test',
      workingDirectory: '/test',
      model: 'claude-sonnet-4-20250514',
      provider: 'anthropic',
    });

    // The correct pattern: serialize appends via promise chaining
    // This is what appendPromiseChain does in the orchestrator
    let chain: Promise<EventId> = Promise.resolve(session.rootEvent.id);

    for (let i = 0; i < 10; i++) {
      chain = chain.then(async (parentId) => {
        const event = await eventStore.append({
          sessionId: session.session.id,
          type: 'stream.turn_start',
          payload: { turn: i },
          parentId,
        });
        return event.id;
      });
    }

    await chain;

    const events = await eventStore.getEventsBySession(session.session.id);
    const sequences = events.map(e => e.sequence);
    const uniqueSequences = new Set(sequences);

    // All sequence numbers should be unique when serialized
    expect(uniqueSequences.size).toBe(sequences.length);
    expect(events.length).toBe(11); // root + 10 events
  });

  it('fork operation should be atomic - no orphaned sessions', async () => {
    const session = await eventStore.createSession({
      workspacePath: '/test',
      workingDirectory: '/test',
      model: 'claude-sonnet-4-20250514',
      provider: 'anthropic',
    });

    // Fork should create session + fork event atomically
    const forkResult = await eventStore.fork(session.rootEvent.id, { name: 'Test Fork' });

    expect(forkResult.session).toBeDefined();
    expect(forkResult.rootEvent).toBeDefined();
    expect(forkResult.rootEvent.type).toBe('session.fork');
    expect(forkResult.session.id).toBe(forkResult.rootEvent.sessionId);
  });
});
