/**
 * @fileoverview Tests for event envelope factory
 *
 * TDD: Tests for centralized event envelope creation
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { createEventEnvelope, BroadcastEventType, type BroadcastEventTypeValue } from '../event-envelope.js';

describe('createEventEnvelope', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-02-01T12:00:00Z'));
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('creates envelope with explicit type and sessionId', () => {
    const envelope = createEventEnvelope('session.created', { foo: 'bar' }, 'sess_123');
    expect(envelope).toEqual({
      type: 'session.created',
      sessionId: 'sess_123',
      timestamp: '2026-02-01T12:00:00.000Z',
      data: { foo: 'bar' },
    });
  });

  it('extracts sessionId from data when not provided explicitly', () => {
    const envelope = createEventEnvelope('agent_turn', { sessionId: 'sess_456', turn: 1 });
    expect(envelope.sessionId).toBe('sess_456');
    expect(envelope.data).toEqual({ sessionId: 'sess_456', turn: 1 });
  });

  it('prefers explicit sessionId over sessionId in data', () => {
    const envelope = createEventEnvelope(
      'event',
      { sessionId: 'from_data' },
      'explicit_session'
    );
    expect(envelope.sessionId).toBe('explicit_session');
  });

  it('preserves timestamp from data when present', () => {
    const existingTs = '2026-01-15T10:00:00Z';
    const envelope = createEventEnvelope('event', { timestamp: existingTs });
    expect(envelope.timestamp).toBe(existingTs);
  });

  it('generates timestamp when not in data', () => {
    const envelope = createEventEnvelope('event', { noTimestamp: true });
    expect(envelope.timestamp).toBe('2026-02-01T12:00:00.000Z');
  });

  it('handles empty data object', () => {
    const envelope = createEventEnvelope('browser.closed', {}, 'sess_789');
    expect(envelope).toEqual({
      type: 'browser.closed',
      sessionId: 'sess_789',
      timestamp: '2026-02-01T12:00:00.000Z',
      data: {},
    });
  });

  it('returns undefined sessionId when not provided anywhere', () => {
    const envelope = createEventEnvelope('system.startup', { version: '1.0' });
    expect(envelope.sessionId).toBeUndefined();
  });
});

describe('BroadcastEventType', () => {
  it('contains all session event types', () => {
    expect(BroadcastEventType.SESSION_CREATED).toBe('session.created');
    expect(BroadcastEventType.SESSION_ENDED).toBe('session.ended');
    expect(BroadcastEventType.SESSION_FORKED).toBe('session.forked');
    expect(BroadcastEventType.SESSION_REWOUND).toBe('session.rewound');
  });

  it('contains all agent event types', () => {
    expect(BroadcastEventType.AGENT_TURN).toBe('agent.turn');
    expect(BroadcastEventType.AGENT_MESSAGE_DELETED).toBe('agent.message_deleted');
    expect(BroadcastEventType.AGENT_CONTEXT_CLEARED).toBe('agent.context_cleared');
    expect(BroadcastEventType.AGENT_COMPACTION).toBe('agent.compaction');
    expect(BroadcastEventType.AGENT_SKILL_REMOVED).toBe('agent.skill_removed');
    expect(BroadcastEventType.AGENT_TODOS_UPDATED).toBe('agent.todos_updated');
  });

  it('contains all browser event types', () => {
    expect(BroadcastEventType.BROWSER_FRAME).toBe('browser.frame');
    expect(BroadcastEventType.BROWSER_CLOSED).toBe('browser.closed');
  });

  it('contains event.new type', () => {
    expect(BroadcastEventType.EVENT_NEW).toBe('event.new');
  });

  it('allows type-safe usage with createEventEnvelope', () => {
    const envelope = createEventEnvelope(BroadcastEventType.SESSION_CREATED, { name: 'test' });
    expect(envelope.type).toBe('session.created');
  });

  it('provides compile-time type checking', () => {
    // This test verifies that BroadcastEventTypeValue is a union type
    // If this compiles, the type system is working
    const validType: BroadcastEventTypeValue = 'session.created';
    expect(validType).toBe('session.created');
  });
});
