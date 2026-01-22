/**
 * @fileoverview Tests for AgentCompactionHandler
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { AgentCompactionHandler, createCompactionHandler } from './compaction-handler.js';
import { createEventEmitter } from './event-emitter.js';
import type { ContextManager, CompactionResult } from '../context/context-manager.js';
import type { Summarizer } from '../context/summarizer.js';

describe('AgentCompactionHandler', () => {
  let handler: AgentCompactionHandler;
  let eventEmitter: ReturnType<typeof createEventEmitter>;
  let mockContextManager: Partial<ContextManager>;
  let mockSummarizer: Summarizer;

  beforeEach(() => {
    eventEmitter = createEventEmitter();

    mockContextManager = {
      getCurrentTokens: vi.fn().mockReturnValue(50000),
      getContextLimit: vi.fn().mockReturnValue(100000),
      canAcceptTurn: vi.fn().mockReturnValue({
        canProceed: true,
        needsCompaction: false,
        wouldExceedLimit: false,
        currentTokens: 50000,
        estimatedAfterTurn: 54000,
        contextLimit: 100000,
      }),
      getSnapshot: vi.fn().mockReturnValue({
        currentTokens: 50000,
        contextLimit: 100000,
        usagePercent: 50,
        thresholdLevel: 'normal',
      }),
      executeCompaction: vi.fn().mockResolvedValue({
        success: true,
        tokensBefore: 50000,
        tokensAfter: 20000,
        compressionRatio: 0.4,
        summary: 'Test summary',
      } as CompactionResult),
    };

    mockSummarizer = {
      summarize: vi.fn(),
      getConfig: vi.fn(),
    } as unknown as Summarizer;

    handler = createCompactionHandler({
      contextManager: mockContextManager as ContextManager,
      eventEmitter,
      sessionId: 'sess_test',
    });
  });

  describe('setSummarizer', () => {
    it('should set the summarizer', () => {
      expect(handler.getSummarizer()).toBeNull();
      handler.setSummarizer(mockSummarizer);
      expect(handler.getSummarizer()).toBe(mockSummarizer);
    });
  });

  describe('canAutoCompact', () => {
    it('should return false when no summarizer is set', () => {
      expect(handler.canAutoCompact()).toBe(false);
    });

    it('should return true when summarizer is set and enabled', () => {
      handler.setSummarizer(mockSummarizer);
      expect(handler.canAutoCompact()).toBe(true);
    });

    it('should return false when summarizer is set but disabled', () => {
      handler.setSummarizer(mockSummarizer);
      handler.setAutoCompaction(false);
      expect(handler.canAutoCompact()).toBe(false);
    });
  });

  describe('setAutoCompaction', () => {
    it('should enable/disable auto-compaction', () => {
      handler.setSummarizer(mockSummarizer);
      expect(handler.canAutoCompact()).toBe(true);

      handler.setAutoCompaction(false);
      expect(handler.canAutoCompact()).toBe(false);

      handler.setAutoCompaction(true);
      expect(handler.canAutoCompact()).toBe(true);
    });
  });

  describe('attemptCompaction', () => {
    it('should return error when no summarizer', async () => {
      const result = await handler.attemptCompaction('pre_turn_guardrail');

      expect(result.success).toBe(false);
      expect(result.error).toContain('not available');
    });

    it('should return error when disabled', async () => {
      handler.setSummarizer(mockSummarizer);
      handler.setAutoCompaction(false);

      const result = await handler.attemptCompaction('pre_turn_guardrail');

      expect(result.success).toBe(false);
      expect(result.error).toContain('not available');
    });

    it('should execute compaction successfully', async () => {
      handler.setSummarizer(mockSummarizer);

      const result = await handler.attemptCompaction('pre_turn_guardrail');

      expect(result.success).toBe(true);
      expect(result.tokensBefore).toBe(50000);
      expect(result.tokensAfter).toBe(20000);
      expect(result.compressionRatio).toBe(0.4);
    });

    it('should emit compaction_start event', async () => {
      const listener = vi.fn();
      eventEmitter.addListener(listener);
      handler.setSummarizer(mockSummarizer);

      await handler.attemptCompaction('pre_turn_guardrail');

      expect(listener).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'compaction_start',
          reason: 'pre_turn_guardrail',
          tokensBefore: 50000,
        })
      );
    });

    it('should emit compaction_complete event on success', async () => {
      const listener = vi.fn();
      eventEmitter.addListener(listener);
      handler.setSummarizer(mockSummarizer);

      await handler.attemptCompaction('threshold_exceeded');

      expect(listener).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'compaction_complete',
          success: true,
          reason: 'threshold_exceeded',
          tokensBefore: 50000,
          tokensAfter: 20000,
          compressionRatio: 0.4,
        })
      );
    });

    it('should emit compaction_complete event on failure', async () => {
      const listener = vi.fn();
      eventEmitter.addListener(listener);
      handler.setSummarizer(mockSummarizer);

      mockContextManager.executeCompaction = vi.fn().mockRejectedValue(
        new Error('Compaction failed')
      );

      const result = await handler.attemptCompaction('manual');

      expect(result.success).toBe(false);
      expect(result.error).toContain('Compaction failed');

      expect(listener).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'compaction_complete',
          success: false,
        })
      );
    });

    it('should handle unsuccessful compaction result', async () => {
      handler.setSummarizer(mockSummarizer);

      mockContextManager.executeCompaction = vi.fn().mockResolvedValue({
        success: false,
        tokensBefore: 50000,
        tokensAfter: 45000,
        compressionRatio: 0.9,
        summary: '',
      } as CompactionResult);

      const result = await handler.attemptCompaction('pre_turn_guardrail');

      expect(result.success).toBe(false);
    });

    it('should pass different reasons', async () => {
      const listener = vi.fn();
      eventEmitter.addListener(listener);
      handler.setSummarizer(mockSummarizer);

      await handler.attemptCompaction('pre_turn_guardrail');
      await handler.attemptCompaction('threshold_exceeded');
      await handler.attemptCompaction('manual');

      const calls = listener.mock.calls.filter(
        ([event]) => event.type === 'compaction_start'
      );

      expect(calls[0][0].reason).toBe('pre_turn_guardrail');
      expect(calls[1][0].reason).toBe('threshold_exceeded');
      expect(calls[2][0].reason).toBe('manual');
    });
  });

  describe('validatePreTurn', () => {
    it('should return canProceed: true when context is fine', () => {
      const result = handler.validatePreTurn(4000);

      expect(result.canProceed).toBe(true);
      expect(result.needsCompaction).toBe(false);
    });

    it('should return needsCompaction: true when context limit approached', () => {
      mockContextManager.canAcceptTurn = vi.fn().mockReturnValue({
        canProceed: true,
        needsCompaction: true,
        wouldExceedLimit: false,
        currentTokens: 85000,
        estimatedAfterTurn: 89000,
        contextLimit: 100000,
      });

      handler.setSummarizer(mockSummarizer);
      const result = handler.validatePreTurn(4000);

      expect(result.canProceed).toBe(true);
      expect(result.needsCompaction).toBe(true);
    });

    it('should return canProceed: false when limit exceeded without summarizer', () => {
      mockContextManager.canAcceptTurn = vi.fn().mockReturnValue({
        canProceed: false,
        needsCompaction: true,
        wouldExceedLimit: true,
        currentTokens: 98000,
        estimatedAfterTurn: 102000,
        contextLimit: 100000,
      });

      const result = handler.validatePreTurn(4000);

      expect(result.canProceed).toBe(false);
      expect(result.needsCompaction).toBe(false);
      expect(result.error).toContain('Context limit exceeded');
    });

    it('should return needsCompaction: true when limit exceeded with summarizer', () => {
      mockContextManager.canAcceptTurn = vi.fn().mockReturnValue({
        canProceed: false,
        needsCompaction: true,
        wouldExceedLimit: true,
        currentTokens: 98000,
        estimatedAfterTurn: 102000,
        contextLimit: 100000,
      });

      handler.setSummarizer(mockSummarizer);
      const result = handler.validatePreTurn(4000);

      expect(result.canProceed).toBe(false);
      expect(result.needsCompaction).toBe(true);
    });

    it('should use default estimatedResponseTokens', () => {
      handler.validatePreTurn();

      expect(mockContextManager.canAcceptTurn).toHaveBeenCalledWith({
        estimatedResponseTokens: 4000,
      });
    });
  });
});

describe('createCompactionHandler', () => {
  it('should create a new instance', () => {
    const handler = createCompactionHandler({
      contextManager: {
        getCurrentTokens: () => 0,
        getContextLimit: () => 100000,
        canAcceptTurn: () => ({ canProceed: true, needsCompaction: false }),
        getSnapshot: () => ({ thresholdLevel: 'normal' }),
      } as unknown as ContextManager,
      eventEmitter: createEventEmitter(),
      sessionId: 'sess_test',
    });

    expect(handler).toBeInstanceOf(AgentCompactionHandler);
  });
});
