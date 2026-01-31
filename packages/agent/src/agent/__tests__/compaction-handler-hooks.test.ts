/**
 * @fileoverview Tests for PreCompact Hook in CompactionHandler
 *
 * TDD: Tests for PreCompact hook execution before summarization.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { AgentCompactionHandler, createCompactionHandler } from '../compaction-handler.js';
import { HookEngine } from '../../hooks/engine.js';
import { createEventEmitter } from '../event-emitter.js';
import type { ContextManager } from '../../context/context-manager.js';
import type { Summarizer } from '../../context/summarizer.js';
import type { TronEvent } from '../../types/index.js';

// =============================================================================
// Test Helpers
// =============================================================================

function createMockContextManager(): Partial<ContextManager> {
  return {
    getCurrentTokens: vi.fn().mockReturnValue(50000),
    getContextLimit: vi.fn().mockReturnValue(100000),
    canAcceptTurn: vi.fn().mockReturnValue({
      canProceed: true,
      needsCompaction: false,
    }),
    getSnapshot: vi.fn().mockReturnValue({
      currentTokens: 50000,
      contextLimit: 100000,
      thresholdLevel: 'none',
    }),
    executeCompaction: vi.fn().mockResolvedValue({
      success: true,
      tokensBefore: 50000,
      tokensAfter: 20000,
      compressionRatio: 0.4,
      summary: 'Summary of conversation',
    }),
  };
}

function createMockSummarizer(): Summarizer {
  return {
    summarize: vi.fn().mockResolvedValue({
      narrative: 'Test summary',
      extractedData: undefined,
    }),
  };
}

// =============================================================================
// Tests
// =============================================================================

describe('AgentCompactionHandler PreCompact Hook', () => {
  let compactionHandler: AgentCompactionHandler;
  let hookEngine: HookEngine;
  let eventEmitter: ReturnType<typeof createEventEmitter>;
  let mockContextManager: Partial<ContextManager>;
  let mockSummarizer: Summarizer;

  beforeEach(() => {
    vi.clearAllMocks();
    hookEngine = new HookEngine();
    eventEmitter = createEventEmitter();
    mockContextManager = createMockContextManager();
    mockSummarizer = createMockSummarizer();

    compactionHandler = createCompactionHandler({
      contextManager: mockContextManager as ContextManager,
      eventEmitter,
      sessionId: 'test-session',
      hookEngine,
    });

    compactionHandler.setSummarizer(mockSummarizer);
  });

  describe('PreCompact hook execution', () => {
    it('should execute PreCompact hook before compaction', async () => {
      const hookHandler = vi.fn().mockResolvedValue({ action: 'continue' });
      hookEngine.register({
        name: 'test-precompact',
        type: 'PreCompact',
        handler: hookHandler,
      });

      await compactionHandler.attemptCompaction('threshold_exceeded');

      expect(hookHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          hookType: 'PreCompact',
          sessionId: 'test-session',
        })
      );
    });

    it('should include token counts in PreCompact context', async () => {
      const hookHandler = vi.fn().mockResolvedValue({ action: 'continue' });
      hookEngine.register({
        name: 'test-precompact',
        type: 'PreCompact',
        handler: hookHandler,
      });

      await compactionHandler.attemptCompaction('threshold_exceeded');

      expect(hookHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          currentTokens: 50000,
          targetTokens: expect.any(Number),
        })
      );
    });

    it('should emit hook events when PreCompact hooks exist', async () => {
      const events: TronEvent[] = [];
      eventEmitter.addListener((e) => events.push(e));

      hookEngine.register({
        name: 'test-precompact',
        type: 'PreCompact',
        handler: async () => ({ action: 'continue' }),
      });

      await compactionHandler.attemptCompaction('threshold_exceeded');

      const triggeredEvents = events.filter((e) => e.type === 'hook_triggered');
      const completedEvents = events.filter((e) => e.type === 'hook_completed');

      expect(triggeredEvents.some((e) => 'hookEvent' in e && e.hookEvent === 'PreCompact')).toBe(true);
      expect(completedEvents.some((e) => 'hookEvent' in e && e.hookEvent === 'PreCompact')).toBe(true);
    });

    it('should proceed with compaction when no hooks registered', async () => {
      await compactionHandler.attemptCompaction('threshold_exceeded');

      expect(mockContextManager.executeCompaction).toHaveBeenCalled();
    });

    it('should proceed with compaction when hook returns continue', async () => {
      hookEngine.register({
        name: 'allow-compaction',
        type: 'PreCompact',
        handler: async () => ({ action: 'continue' }),
      });

      await compactionHandler.attemptCompaction('threshold_exceeded');

      expect(mockContextManager.executeCompaction).toHaveBeenCalled();
    });

    it('should continue on hook error (fail-open)', async () => {
      hookEngine.register({
        name: 'error-hook',
        type: 'PreCompact',
        handler: async () => {
          throw new Error('Hook failed');
        },
      });

      const result = await compactionHandler.attemptCompaction('threshold_exceeded');

      // Should still attempt compaction (fail-open)
      expect(mockContextManager.executeCompaction).toHaveBeenCalled();
      expect(result.success).toBe(true);
    });
  });

  describe('hook execution order', () => {
    it('should execute PreCompact hook before compaction_start event', async () => {
      const callOrder: string[] = [];

      hookEngine.register({
        name: 'precompact-hook',
        type: 'PreCompact',
        handler: async () => {
          callOrder.push('hook');
          return { action: 'continue' };
        },
      });

      eventEmitter.addListener((e) => {
        if (e.type === 'compaction_start') {
          callOrder.push('compaction_start');
        }
      });

      await compactionHandler.attemptCompaction('threshold_exceeded');

      // Hook should execute before compaction_start
      expect(callOrder[0]).toBe('hook');
    });
  });
});
