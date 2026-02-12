/**
 * @fileoverview Tests for EventChainBuilder
 *
 * Uses a real in-memory EventStore to verify that sequential appends
 * chain parentId correctly and the head tracks the latest event.
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { EventStore } from '../event-store.js';
import { EventChainBuilder } from '../event-chain-builder.js';
import type { EventType } from '../types.js';

describe('EventChainBuilder', () => {
  let store: EventStore;

  beforeEach(async () => {
    store = new EventStore(':memory:');
    await store.initialize();
  });

  afterEach(async () => {
    await store.close();
  });

  async function createSession() {
    return store.createSession({
      workspacePath: '/test',
      workingDirectory: '/test',
      model: 'claude-sonnet-4-20250514',
    });
  }

  it('should start with the provided initial head', async () => {
    const { session, rootEvent } = await createSession();
    const chain = new EventChainBuilder(store, session.id, rootEvent.id);

    expect(chain.headEventId).toBe(rootEvent.id);
  });

  it('should chain a single append from the initial head', async () => {
    const { session, rootEvent } = await createSession();
    const chain = new EventChainBuilder(store, session.id, rootEvent.id);

    const event = await chain.append('rules.loaded' as EventType, { totalFiles: 3 });

    expect(event.parentId).toBe(rootEvent.id);
    expect(chain.headEventId).toBe(event.id);
  });

  it('should chain multiple appends correctly', async () => {
    const { session, rootEvent } = await createSession();
    const chain = new EventChainBuilder(store, session.id, rootEvent.id);

    const e1 = await chain.append('rules.loaded' as EventType, { totalFiles: 2 });
    const e2 = await chain.append('rules.indexed' as EventType, { totalRules: 5 });
    const e3 = await chain.append('memory.loaded' as EventType, { count: 3 });

    // Each event chains from the previous
    expect(e1.parentId).toBe(rootEvent.id);
    expect(e2.parentId).toBe(e1.id);
    expect(e3.parentId).toBe(e2.id);

    // Head tracks the latest
    expect(chain.headEventId).toBe(e3.id);
  });

  it('should produce events retrievable via getAncestors', async () => {
    const { session, rootEvent } = await createSession();
    const chain = new EventChainBuilder(store, session.id, rootEvent.id);

    await chain.append('rules.loaded' as EventType, { totalFiles: 1 });
    await chain.append('rules.indexed' as EventType, { totalRules: 2 });

    const ancestors = await store.getAncestors(chain.headEventId);

    // Should include root + 2 appended events = 3 total
    expect(ancestors).toHaveLength(3);
    // Ancestors are ordered root → newest
    expect(ancestors[0].type).toBe('session.start');
    expect(ancestors[1].type).toBe('rules.loaded');
    expect(ancestors[2].type).toBe('rules.indexed');
  });

  it('should preserve payload in appended events', async () => {
    const { session, rootEvent } = await createSession();
    const chain = new EventChainBuilder(store, session.id, rootEvent.id);

    const payload = { totalFiles: 5, mergedTokens: 1200 };
    const event = await chain.append('rules.loaded' as EventType, payload);

    expect(event.payload).toMatchObject(payload);
  });

  it('should handle empty chain (no appends)', async () => {
    const { session, rootEvent } = await createSession();
    const chain = new EventChainBuilder(store, session.id, rootEvent.id);

    // Head should still be the initial value
    expect(chain.headEventId).toBe(rootEvent.id);
  });
});
