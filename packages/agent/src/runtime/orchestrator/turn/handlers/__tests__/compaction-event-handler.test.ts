/**
 * @fileoverview Tests for CompactionEventHandler
 *
 * CompactionEventHandler uses EventContext for automatic metadata injection.
 * It emits compaction events and persists boundary events for session resume.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  CompactionEventHandler,
  createCompactionEventHandler,
  type CompactionEventHandlerDeps,
} from '../compaction-event-handler.js';
import { createTestEventContext, type TestEventContext } from '../../event-context.js';
import type { SessionId } from '../../../../events/types.js';
import type { CompactionStartEvent, CompactionCompleteEvent } from '../../../../types/events.js';
import type { ActiveSession } from '../../../types.js';

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

function createMockDeps(): CompactionEventHandlerDeps {
  return {};
}

function createTestContext(options: {
  sessionId?: SessionId;
  runId?: string;
  active?: ActiveSession;
} = {}): TestEventContext {
  return createTestEventContext({
    sessionId: options.sessionId ?? ('test-session' as SessionId),
    runId: options.runId,
    active: options.active,
  });
}

// =============================================================================
// Tests
// =============================================================================

describe('CompactionEventHandler', () => {
  let deps: CompactionEventHandlerDeps;
  let handler: CompactionEventHandler;

  beforeEach(() => {
    deps = createMockDeps();
    handler = createCompactionEventHandler(deps);
  });

  describe('handleCompactionStarted', () => {
    it('should emit agent.compaction_started event', () => {
      const ctx = createTestContext();
      const event: CompactionStartEvent = {
        type: 'compaction_start',
        sessionId: ctx.sessionId,
        timestamp: ctx.timestamp,
        reason: 'threshold_exceeded',
        tokensBefore: 150000,
      };

      handler.handleCompactionStarted(ctx, event);

      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0]).toEqual({
        type: 'agent.compaction_started',
        data: {
          reason: 'threshold_exceeded',
          tokensBefore: 150000,
        },
      });
    });

    it('should default reason to auto', () => {
      const ctx = createTestContext();
      const event = {
        type: 'compaction_start' as const,
        sessionId: ctx.sessionId,
        timestamp: ctx.timestamp,
      };

      handler.handleCompactionStarted(ctx, event as any);

      expect(ctx.emitCalls[0].data).toMatchObject({
        reason: 'auto',
      });
    });

    it('should not persist anything (compaction_start is transient)', () => {
      const ctx = createTestContext();
      const event: CompactionStartEvent = {
        type: 'compaction_start',
        sessionId: ctx.sessionId,
        timestamp: ctx.timestamp,
        reason: 'manual',
        tokensBefore: 100000,
      };

      handler.handleCompactionStarted(ctx, event);

      expect(ctx.persistCalls).toHaveLength(0);
    });
  });

  describe('handleCompactionComplete', () => {
    it('should emit agent.compaction event via context', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-123' });
      const ctx = createTestContext({ active: mockActive });
      const event: CompactionCompleteEvent = {
        type: 'compaction_complete',
        sessionId: ctx.sessionId,
        timestamp: ctx.timestamp,
        tokensBefore: 100000,
        tokensAfter: 50000,
        compressionRatio: 0.5,
        reason: 'manual',
        success: true,
        summary: 'Compacted context',
      };

      handler.handleCompactionComplete(ctx, event);

      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0]).toEqual({
        type: 'agent.compaction',
        data: {
          tokensBefore: 100000,
          tokensAfter: 50000,
          compressionRatio: 0.5,
          reason: 'manual',
          summary: 'Compacted context',
        },
      });
    });

    it('should persist compact.boundary event on success', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-456' });
      const ctx = createTestContext({ active: mockActive });
      const event: CompactionCompleteEvent = {
        type: 'compaction_complete',
        sessionId: ctx.sessionId,
        timestamp: ctx.timestamp,
        tokensBefore: 100000,
        tokensAfter: 50000,
        compressionRatio: 0.5,
        reason: 'manual',
        success: true,
        summary: 'User-requested compaction',
      };

      handler.handleCompactionComplete(ctx, event);

      expect(ctx.persistCalls).toHaveLength(1);
      expect(ctx.persistCalls[0]).toEqual({
        type: 'compact.boundary',
        payload: {
          originalTokens: 100000,
          compactedTokens: 50000,
          compressionRatio: 0.5,
          reason: 'manual',
          summary: 'User-requested compaction',
          runId: 'run-456',
        },
      });
    });

    it('should not persist event on failure', () => {
      const ctx = createTestContext();
      const event: CompactionCompleteEvent = {
        type: 'compaction_complete',
        sessionId: ctx.sessionId,
        timestamp: ctx.timestamp,
        tokensBefore: 100000,
        tokensAfter: 100000,
        compressionRatio: 1.0,
        success: false,
      };

      handler.handleCompactionComplete(ctx, event);

      // Should still emit streaming event
      expect(ctx.emitCalls).toHaveLength(1);
      // But should not persist
      expect(ctx.persistCalls).toHaveLength(0);
    });

    it('should default reason to auto', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-789' });
      const ctx = createTestContext({ active: mockActive });
      const event: CompactionCompleteEvent = {
        type: 'compaction_complete',
        sessionId: ctx.sessionId,
        timestamp: ctx.timestamp,
        tokensBefore: 100000,
        tokensAfter: 50000,
        compressionRatio: 0.5,
        success: true,
      };

      handler.handleCompactionComplete(ctx, event);

      expect(ctx.emitCalls[0].data).toMatchObject({
        reason: 'auto',
      });
      expect(ctx.persistCalls[0].payload).toMatchObject({
        reason: 'auto',
      });
    });

    it('should persist when success is true', () => {
      const mockActive = createMockActiveSession({ currentRunId: 'run-000' });
      const ctx = createTestContext({ active: mockActive });
      const event: CompactionCompleteEvent = {
        type: 'compaction_complete',
        sessionId: ctx.sessionId,
        timestamp: ctx.timestamp,
        tokensBefore: 100000,
        tokensAfter: 50000,
        compressionRatio: 0.5,
        success: true,
      };

      handler.handleCompactionComplete(ctx, event);

      // Should persist (success !== false)
      expect(ctx.persistCalls).toHaveLength(1);
    });

    it('should handle undefined active session (no runId)', () => {
      const ctx = createTestContext(); // No active session
      const event: CompactionCompleteEvent = {
        type: 'compaction_complete',
        sessionId: ctx.sessionId,
        timestamp: ctx.timestamp,
        tokensBefore: 100000,
        tokensAfter: 50000,
        compressionRatio: 0.5,
        success: true,
      };

      handler.handleCompactionComplete(ctx, event);

      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.persistCalls).toHaveLength(1);
      // runId should be undefined
      expect(ctx.persistCalls[0].payload.runId).toBeUndefined();
    });
  });

  describe('factory function', () => {
    it('should create CompactionEventHandler instance', () => {
      const handler = createCompactionEventHandler(deps);
      expect(handler).toBeInstanceOf(CompactionEventHandler);
    });
  });
});
