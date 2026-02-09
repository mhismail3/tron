/**
 * @fileoverview Tests for EventContext
 *
 * EventContext provides a scoped context for event dispatch that:
 * - Resolves active session once at creation
 * - Captures timestamp once for consistency
 * - Provides typed emit/persist methods with automatic metadata
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  EventContext,
  EventContextImpl,
  createEventContext,
  createTestEventContext,
  type EventContextDeps,
} from '../event-context.js';
import type { SessionId } from '@infrastructure/events/types.js';
import type { ActiveSession } from '../../types.js';

// =============================================================================
// Test Helpers
// =============================================================================

function createMockActiveSession(overrides: Partial<ActiveSession> = {}): ActiveSession {
  return {
    sessionId: 'test-session' as SessionId,
    model: 'claude-sonnet-4-20250514',
    agent: {} as ActiveSession['agent'],
    sessionContext: {} as ActiveSession['sessionContext'],
    ...overrides,
  } as ActiveSession;
}

function createMockDeps(activeSession?: ActiveSession): EventContextDeps {
  return {
    sessionStore: { get: vi.fn().mockReturnValue(activeSession) } as any,
    appendEventLinearized: vi.fn(),
    emit: vi.fn(),
  };
}

// =============================================================================
// Tests
// =============================================================================

describe('EventContext', () => {
  describe('creation', () => {
    it('should capture sessionId at creation', () => {
      const sessionId = 'test-session-123' as SessionId;
      const deps = createMockDeps();

      const ctx = createEventContext(sessionId, deps);

      expect(ctx.sessionId).toBe(sessionId);
    });

    it('should capture timestamp at creation', () => {
      const sessionId = 'test-session' as SessionId;
      const deps = createMockDeps();
      const before = new Date().toISOString();

      const ctx = createEventContext(sessionId, deps);

      const after = new Date().toISOString();
      expect(ctx.timestamp).toBeDefined();
      expect(ctx.timestamp >= before).toBe(true);
      expect(ctx.timestamp <= after).toBe(true);
    });

    it('should resolve active session once at creation', () => {
      const sessionId = 'test-session' as SessionId;
      const mockActive = createMockActiveSession({ currentRunId: 'run-123' });
      const deps = createMockDeps(mockActive);

      const ctx = createEventContext(sessionId, deps);

      expect(deps.sessionStore.get).toHaveBeenCalledTimes(1);
      expect(deps.sessionStore.get).toHaveBeenCalledWith(sessionId);
      expect(ctx.active).toBe(mockActive);
    });

    it('should extract runId from active session', () => {
      const sessionId = 'test-session' as SessionId;
      const mockActive = createMockActiveSession({ currentRunId: 'run-456' });
      const deps = createMockDeps(mockActive);

      const ctx = createEventContext(sessionId, deps);

      expect(ctx.runId).toBe('run-456');
    });

    it('should handle undefined active session', () => {
      const sessionId = 'test-session' as SessionId;
      const deps = createMockDeps(undefined);

      const ctx = createEventContext(sessionId, deps);

      expect(ctx.active).toBeUndefined();
      expect(ctx.runId).toBeUndefined();
    });

    it('should handle active session without runId', () => {
      const sessionId = 'test-session' as SessionId;
      const mockActive = createMockActiveSession({ currentRunId: undefined });
      const deps = createMockDeps(mockActive);

      const ctx = createEventContext(sessionId, deps);

      expect(ctx.active).toBe(mockActive);
      expect(ctx.runId).toBeUndefined();
    });
  });

  describe('emit', () => {
    it('should emit event with sessionId, timestamp, and runId', () => {
      const sessionId = 'test-session' as SessionId;
      const mockActive = createMockActiveSession({ currentRunId: 'run-789' });
      const deps = createMockDeps(mockActive);
      const ctx = createEventContext(sessionId, deps);

      ctx.emit('agent.turn_start', { turn: 1 });

      expect(deps.emit).toHaveBeenCalledWith('agent_event', {
        type: 'agent.turn_start',
        sessionId,
        timestamp: ctx.timestamp,
        runId: 'run-789',
        data: { turn: 1 },
      });
    });

    it('should emit event without data when not provided', () => {
      const sessionId = 'test-session' as SessionId;
      const deps = createMockDeps();
      const ctx = createEventContext(sessionId, deps);

      ctx.emit('agent.thinking_start');

      expect(deps.emit).toHaveBeenCalledWith('agent_event', {
        type: 'agent.thinking_start',
        sessionId,
        timestamp: ctx.timestamp,
        runId: undefined,
        data: undefined,
      });
    });

    it('should emit with undefined runId when no active session', () => {
      const sessionId = 'test-session' as SessionId;
      const deps = createMockDeps(undefined);
      const ctx = createEventContext(sessionId, deps);

      ctx.emit('agent.text_delta', { delta: 'hello' });

      expect(deps.emit).toHaveBeenCalledWith('agent_event', {
        type: 'agent.text_delta',
        sessionId,
        timestamp: ctx.timestamp,
        runId: undefined,
        data: { delta: 'hello' },
      });
    });

    it('should use consistent timestamp across multiple emits', () => {
      const sessionId = 'test-session' as SessionId;
      const deps = createMockDeps();
      const ctx = createEventContext(sessionId, deps);

      ctx.emit('agent.turn_start', { turn: 1 });
      ctx.emit('agent.text_delta', { delta: 'hello' });
      ctx.emit('agent.turn_end', { turn: 1 });

      const calls = (deps.emit as ReturnType<typeof vi.fn>).mock.calls;
      const timestamps = calls.map((call) => call[1].timestamp);
      expect(timestamps[0]).toBe(timestamps[1]);
      expect(timestamps[1]).toBe(timestamps[2]);
    });
  });

  describe('persist', () => {
    it('should persist event with runId included in payload', () => {
      const sessionId = 'test-session' as SessionId;
      const mockActive = createMockActiveSession({ currentRunId: 'run-abc' });
      const deps = createMockDeps(mockActive);
      const ctx = createEventContext(sessionId, deps);

      ctx.persist('stream.turn_start', { turn: 1 });

      expect(deps.appendEventLinearized).toHaveBeenCalledWith(
        sessionId,
        'stream.turn_start',
        { turn: 1, runId: 'run-abc' },
        undefined
      );
    });

    it('should persist with undefined runId when no active session', () => {
      const sessionId = 'test-session' as SessionId;
      const deps = createMockDeps(undefined);
      const ctx = createEventContext(sessionId, deps);

      ctx.persist('tool.call', { toolCallId: 'call-1', name: 'Read' });

      expect(deps.appendEventLinearized).toHaveBeenCalledWith(
        sessionId,
        'tool.call',
        { toolCallId: 'call-1', name: 'Read', runId: undefined },
        undefined
      );
    });

    it('should pass onCreated callback', () => {
      const sessionId = 'test-session' as SessionId;
      const deps = createMockDeps();
      const ctx = createEventContext(sessionId, deps);
      const onCreated = vi.fn();

      ctx.persist('message.assistant', { content: [] }, onCreated);

      expect(deps.appendEventLinearized).toHaveBeenCalledWith(
        sessionId,
        'message.assistant',
        { content: [], runId: undefined },
        onCreated
      );
    });

    it('should not overwrite existing runId in payload', () => {
      const sessionId = 'test-session' as SessionId;
      const mockActive = createMockActiveSession({ currentRunId: 'run-new' });
      const deps = createMockDeps(mockActive);
      const ctx = createEventContext(sessionId, deps);

      // If payload already has runId, context should still use its own
      // This ensures consistency
      ctx.persist('stream.turn_end', { turn: 1, runId: 'run-old' });

      expect(deps.appendEventLinearized).toHaveBeenCalledWith(
        sessionId,
        'stream.turn_end',
        { turn: 1, runId: 'run-new' }, // Context's runId takes precedence
        undefined
      );
    });
  });

  describe('createTestEventContext', () => {
    it('should create context with specified values', () => {
      const ctx = createTestEventContext({
        sessionId: 'test-123' as SessionId,
        runId: 'run-test',
        timestamp: '2024-01-01T00:00:00.000Z',
      });

      expect(ctx.sessionId).toBe('test-123');
      expect(ctx.runId).toBe('run-test');
      expect(ctx.timestamp).toBe('2024-01-01T00:00:00.000Z');
    });

    it('should provide mock emit function', () => {
      const ctx = createTestEventContext({
        sessionId: 'test-123' as SessionId,
      });

      ctx.emit('agent.turn_start', { turn: 1 });

      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0]).toEqual({
        type: 'agent.turn_start',
        data: { turn: 1 },
      });
    });

    it('should provide mock persist function', () => {
      const ctx = createTestEventContext({
        sessionId: 'test-123' as SessionId,
      });

      ctx.persist('tool.call', { toolCallId: 'call-1' });

      expect(ctx.persistCalls).toHaveLength(1);
      expect(ctx.persistCalls[0]).toEqual({
        type: 'tool.call',
        payload: { toolCallId: 'call-1', runId: undefined },
      });
    });

    it('should default runId to undefined', () => {
      const ctx = createTestEventContext({
        sessionId: 'test-123' as SessionId,
      });

      expect(ctx.runId).toBeUndefined();
    });

    it('should generate timestamp if not provided', () => {
      const before = new Date().toISOString();
      const ctx = createTestEventContext({
        sessionId: 'test-123' as SessionId,
      });
      const after = new Date().toISOString();

      expect(ctx.timestamp >= before).toBe(true);
      expect(ctx.timestamp <= after).toBe(true);
    });

    it('should allow providing active session', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-from-active' });
      const ctx = createTestEventContext({
        sessionId: 'test-123' as SessionId,
        active: mockActive,
      });

      expect(ctx.active).toBe(mockActive);
      // runId should come from active if not explicitly provided
      expect(ctx.runId).toBe('run-from-active');
    });

    it('should prefer explicit runId over active session runId', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-from-active' });
      const ctx = createTestEventContext({
        sessionId: 'test-123' as SessionId,
        active: mockActive,
        runId: 'run-explicit',
      });

      expect(ctx.runId).toBe('run-explicit');
    });
  });

  describe('EventContextImpl', () => {
    it('should be instanceof EventContextImpl', () => {
      const sessionId = 'test-session' as SessionId;
      const deps = createMockDeps();
      const ctx = createEventContext(sessionId, deps);

      expect(ctx).toBeInstanceOf(EventContextImpl);
    });
  });
});
