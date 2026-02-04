/**
 * @fileoverview Tests for SubAgentTracker
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { SubAgentTracker, createSubAgentTracker } from '../subagent-tracker.js';
import type { SessionId, SubagentSpawnType, TokenUsage } from '@infrastructure/events/types.js';

describe('SubAgentTracker', () => {
  let tracker: SubAgentTracker;

  beforeEach(() => {
    tracker = createSubAgentTracker();
  });

  describe('spawn and complete', () => {
    it('should track spawned subagents', () => {
      tracker.spawn(
        'sess-1' as SessionId,
        'in-process' as SubagentSpawnType,
        'Test task',
        'claude-3',
        '/tmp',
        'event-1'
      );

      expect(tracker.has('sess-1' as SessionId)).toBe(true);
      expect(tracker.count).toBe(1);
    });

    it('should mark subagents as completed', () => {
      tracker.spawn(
        'sess-1' as SessionId,
        'in-process' as SubagentSpawnType,
        'Test task',
        'claude-3',
        '/tmp',
        'event-1'
      );

      const tokenUsage: TokenUsage = { inputTokens: 100, outputTokens: 50 };
      tracker.complete('sess-1' as SessionId, 'Summary', 3, tokenUsage, 5000);

      const subagent = tracker.get('sess-1' as SessionId);
      expect(subagent?.status).toBe('completed');
      expect(subagent?.resultSummary).toBe('Summary');
    });
  });

  describe('callback error handling', () => {
    it('should catch and log errors in completion callbacks without breaking flow', () => {
      const loggerSpy = vi.fn();

      // Spy on the logger - we'll verify this works after implementing
      tracker.spawn(
        'sess-1' as SessionId,
        'in-process' as SubagentSpawnType,
        'Test task',
        'claude-3',
        '/tmp',
        'event-1'
      );

      // Register a callback that throws
      const errorCallback = vi.fn(() => {
        throw new Error('Callback error');
      });
      tracker.onComplete('sess-1' as SessionId, errorCallback);

      // Also register a second callback that should still be called
      const secondCallback = vi.fn();
      tracker.onComplete('sess-1' as SessionId, secondCallback);

      // Complete should not throw even though callback throws
      const tokenUsage: TokenUsage = { inputTokens: 100, outputTokens: 50 };
      expect(() => {
        tracker.complete('sess-1' as SessionId, 'Summary', 3, tokenUsage, 5000);
      }).not.toThrow();

      // Both callbacks should have been invoked
      expect(errorCallback).toHaveBeenCalled();
      expect(secondCallback).toHaveBeenCalled();
    });

    it('should catch and log errors in global completion callbacks', () => {
      tracker.spawn(
        'sess-1' as SessionId,
        'in-process' as SubagentSpawnType,
        'Test task',
        'claude-3',
        '/tmp',
        'event-1'
      );

      // Register a global callback that throws
      const errorCallback = vi.fn(() => {
        throw new Error('Global callback error');
      });
      tracker.onAnyComplete(errorCallback);

      // Register another global callback
      const secondCallback = vi.fn();
      tracker.onAnyComplete(secondCallback);

      // Complete should not throw
      const tokenUsage: TokenUsage = { inputTokens: 100, outputTokens: 50 };
      expect(() => {
        tracker.complete('sess-1' as SessionId, 'Summary', 3, tokenUsage, 5000);
      }).not.toThrow();

      // Both callbacks should have been invoked
      expect(errorCallback).toHaveBeenCalled();
      expect(secondCallback).toHaveBeenCalled();
    });
  });

  describe('pending results', () => {
    it('should queue completed results', () => {
      tracker.spawn(
        'sess-1' as SessionId,
        'in-process' as SubagentSpawnType,
        'Test task',
        'claude-3',
        '/tmp',
        'event-1'
      );

      const tokenUsage: TokenUsage = { inputTokens: 100, outputTokens: 50 };
      tracker.complete('sess-1' as SessionId, 'Summary', 3, tokenUsage, 5000);

      expect(tracker.hasPendingResults()).toBe(true);
      expect(tracker.pendingCount).toBe(1);

      const results = tracker.consumePendingResults();
      expect(results).toHaveLength(1);
      expect(results[0].summary).toBe('Summary');
      expect(tracker.hasPendingResults()).toBe(false);
    });
  });

  describe('completion metadata', () => {
    it('should include stopReason in completed result', () => {
      tracker.spawn(
        'sess-1' as SessionId,
        'in-process' as SubagentSpawnType,
        'Test task',
        'claude-3',
        '/tmp',
        'event-1'
      );

      const tokenUsage: TokenUsage = { inputTokens: 100, outputTokens: 50 };
      tracker.complete('sess-1' as SessionId, 'Summary', 3, tokenUsage, 5000, 'Full output', {
        stopReason: 'end_turn',
        completionType: 'success',
      });

      const results = tracker.consumePendingResults();
      expect(results[0].stopReason).toBe('end_turn');
      expect(results[0].completionType).toBe('success');
      expect(results[0].truncated).toBeUndefined();
    });

    it('should mark truncated when stopReason is max_tokens', () => {
      tracker.spawn(
        'sess-1' as SessionId,
        'in-process' as SubagentSpawnType,
        'Test task',
        'claude-3',
        '/tmp',
        'event-1'
      );

      const tokenUsage: TokenUsage = { inputTokens: 100, outputTokens: 50 };
      tracker.complete('sess-1' as SessionId, 'Summary', 3, tokenUsage, 5000, 'Partial output', {
        stopReason: 'max_tokens',
        truncated: true,
        completionType: 'max_tokens',
      });

      const results = tracker.consumePendingResults();
      expect(results[0].stopReason).toBe('max_tokens');
      expect(results[0].truncated).toBe(true);
      expect(results[0].completionType).toBe('max_tokens');
    });

    it('should include completionType in failed result', () => {
      tracker.spawn(
        'sess-1' as SessionId,
        'in-process' as SubagentSpawnType,
        'Test task',
        'claude-3',
        '/tmp',
        'event-1'
      );

      tracker.fail('sess-1' as SessionId, 'Guardrail timeout exceeded', {
        completionType: 'timeout',
        duration: 3600000,
      });

      const results = tracker.consumePendingResults();
      expect(results[0].success).toBe(false);
      expect(results[0].completionType).toBe('timeout');
      expect(results[0].error).toBe('Guardrail timeout exceeded');
    });
  });

  describe('isTerminated', () => {
    it('should return false for spawning/running subagents', () => {
      tracker.spawn(
        'sess-1' as SessionId,
        'in-process' as SubagentSpawnType,
        'Test task',
        'claude-3',
        '/tmp',
        'event-1'
      );

      expect(tracker.isTerminated('sess-1' as SessionId)).toBe(false);

      tracker.updateStatus('sess-1' as SessionId, 'running');
      expect(tracker.isTerminated('sess-1' as SessionId)).toBe(false);
    });

    it('should return true for completed subagents', () => {
      tracker.spawn(
        'sess-1' as SessionId,
        'in-process' as SubagentSpawnType,
        'Test task',
        'claude-3',
        '/tmp',
        'event-1'
      );

      const tokenUsage: TokenUsage = { inputTokens: 100, outputTokens: 50 };
      tracker.complete('sess-1' as SessionId, 'Summary', 3, tokenUsage, 5000);

      expect(tracker.isTerminated('sess-1' as SessionId)).toBe(true);
    });

    it('should return true for failed subagents', () => {
      tracker.spawn(
        'sess-1' as SessionId,
        'in-process' as SubagentSpawnType,
        'Test task',
        'claude-3',
        '/tmp',
        'event-1'
      );

      tracker.fail('sess-1' as SessionId, 'Error');

      expect(tracker.isTerminated('sess-1' as SessionId)).toBe(true);
    });

    it('should return true for non-existent subagents', () => {
      // Non-existent subagents are considered terminated (no result possible)
      expect(tracker.isTerminated('non-existent' as SessionId)).toBe(true);
    });
  });

  describe('waitFor with already terminated', () => {
    it('should resolve immediately for completed subagents', async () => {
      tracker.spawn(
        'sess-1' as SessionId,
        'in-process' as SubagentSpawnType,
        'Test task',
        'claude-3',
        '/tmp',
        'event-1'
      );

      const tokenUsage: TokenUsage = { inputTokens: 100, outputTokens: 50 };
      tracker.complete('sess-1' as SessionId, 'Summary', 3, tokenUsage, 5000, 'Full output', {
        stopReason: 'end_turn',
        completionType: 'success',
      });

      // waitFor should resolve immediately with result including metadata
      const result = await tracker.waitFor('sess-1' as SessionId);
      expect(result.success).toBe(true);
      expect(result.stopReason).toBe('end_turn');
      expect(result.completionType).toBe('success');
    });

    it('should resolve immediately for failed subagents', async () => {
      tracker.spawn(
        'sess-1' as SessionId,
        'in-process' as SubagentSpawnType,
        'Test task',
        'claude-3',
        '/tmp',
        'event-1'
      );

      tracker.fail('sess-1' as SessionId, 'Timeout error', {
        completionType: 'timeout',
      });

      const result = await tracker.waitFor('sess-1' as SessionId);
      expect(result.success).toBe(false);
      expect(result.completionType).toBe('timeout');
      expect(result.error).toBe('Timeout error');
    });
  });
});
