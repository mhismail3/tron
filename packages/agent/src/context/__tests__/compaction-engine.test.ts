/**
 * @fileoverview Tests for CompactionEngine
 *
 * CompactionEngine handles context compaction logic including:
 * - Determining when compaction is needed
 * - Generating compaction previews
 * - Executing compaction with summarization
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { CompactionEngine, createCompactionEngine, type CompactionDeps } from '../compaction-engine.js';
import type { Message } from '../../types/index.js';
import type { Summarizer } from '../summarizer.js';

describe('CompactionEngine', () => {
  let engine: CompactionEngine;
  let mockDeps: CompactionDeps;
  let messages: Message[];

  beforeEach(() => {
    messages = [
      { role: 'user', content: 'First message' },
      { role: 'assistant', content: [{ type: 'text', text: 'First response' }] },
      { role: 'user', content: 'Second message' },
      { role: 'assistant', content: [{ type: 'text', text: 'Second response' }] },
      { role: 'user', content: 'Third message' },
      { role: 'assistant', content: [{ type: 'text', text: 'Third response' }] },
    ];

    mockDeps = {
      getMessages: vi.fn(() => messages),
      setMessages: vi.fn((newMessages: Message[]) => {
        messages = newMessages;
      }),
      getCurrentTokens: vi.fn(() => 80000),
      getContextLimit: vi.fn(() => 100000),
      estimateSystemPromptTokens: vi.fn(() => 1000),
      estimateToolsTokens: vi.fn(() => 500),
      getMessageTokens: vi.fn(() => 100),
    };

    engine = createCompactionEngine(
      { threshold: 0.70, preserveRecentTurns: 1 },
      mockDeps
    );
  });

  describe('shouldCompact', () => {
    it('should return true when at or above threshold', () => {
      // 80000 / 100000 = 0.80, which is >= 0.70 threshold
      expect(engine.shouldCompact()).toBe(true);
    });

    it('should return false when below threshold', () => {
      (mockDeps.getCurrentTokens as ReturnType<typeof vi.fn>).mockReturnValue(60000);
      // 60000 / 100000 = 0.60, which is < 0.70 threshold
      expect(engine.shouldCompact()).toBe(false);
    });

    it('should return true at exactly threshold', () => {
      (mockDeps.getCurrentTokens as ReturnType<typeof vi.fn>).mockReturnValue(70000);
      // 70000 / 100000 = 0.70, which is >= 0.70 threshold
      expect(engine.shouldCompact()).toBe(true);
    });
  });

  describe('preview', () => {
    it('should generate preview with summary', async () => {
      const mockSummarizer: Summarizer = {
        summarize: vi.fn().mockResolvedValue({
          narrative: 'Test summary of the conversation',
          extractedData: { files: [], decisions: [] },
        }),
      };

      const preview = await engine.preview(mockSummarizer);

      expect(preview.summary).toBe('Test summary of the conversation');
      expect(preview.tokensBefore).toBe(80000);
      expect(mockSummarizer.summarize).toHaveBeenCalled();
    });

    it('should preserve recent turns', async () => {
      const mockSummarizer: Summarizer = {
        summarize: vi.fn().mockResolvedValue({
          narrative: 'Summary',
          extractedData: undefined,
        }),
      };

      const preview = await engine.preview(mockSummarizer);

      // With preserveRecentTurns=1, we should preserve 2 messages (1 turn = user + assistant)
      expect(preview.preservedTurns).toBe(1);
      // 6 messages - 2 preserved = 4 summarized = 2 turns
      expect(preview.summarizedTurns).toBe(2);
    });

    it('should include extracted data in preview', async () => {
      const extractedData = {
        files: [{ path: '/test.ts', status: 'modified' as const }],
        decisions: [{ decision: 'Use TypeScript', rationale: 'Type safety' }],
      };
      const mockSummarizer: Summarizer = {
        summarize: vi.fn().mockResolvedValue({
          narrative: 'Summary',
          extractedData,
        }),
      };

      const preview = await engine.preview(mockSummarizer);

      expect(preview.extractedData).toEqual(extractedData);
    });

    it('should handle empty messages', async () => {
      messages = [];
      const mockSummarizer: Summarizer = {
        summarize: vi.fn().mockResolvedValue({
          narrative: '',
          extractedData: undefined,
        }),
      };

      const preview = await engine.preview(mockSummarizer);

      expect(preview.preservedTurns).toBe(1);
      expect(preview.summarizedTurns).toBe(0);
    });
  });

  describe('execute', () => {
    it('should execute compaction and update messages', async () => {
      const mockSummarizer: Summarizer = {
        summarize: vi.fn().mockResolvedValue({
          narrative: 'Compacted summary',
          extractedData: undefined,
        }),
      };

      const result = await engine.execute({ summarizer: mockSummarizer });

      expect(result.success).toBe(true);
      expect(result.summary).toBe('Compacted summary');
      expect(mockDeps.setMessages).toHaveBeenCalled();
    });

    it('should use edited summary when provided', async () => {
      const mockSummarizer: Summarizer = {
        summarize: vi.fn().mockResolvedValue({
          narrative: 'Original summary',
          extractedData: undefined,
        }),
      };

      const result = await engine.execute({
        summarizer: mockSummarizer,
        editedSummary: 'User edited summary',
      });

      expect(result.summary).toBe('User edited summary');
      // Summarizer should not be called when edited summary provided
      expect(mockSummarizer.summarize).not.toHaveBeenCalled();
    });

    it('should preserve recent messages', async () => {
      const mockSummarizer: Summarizer = {
        summarize: vi.fn().mockResolvedValue({
          narrative: 'Summary',
          extractedData: undefined,
        }),
      };

      await engine.execute({ summarizer: mockSummarizer });

      // Check setMessages was called with correct structure:
      // - Context summary message
      // - Assistant acknowledgment
      // - Preserved messages (last 2 with preserveRecentTurns=1)
      const setMessagesMock = mockDeps.setMessages as ReturnType<typeof vi.fn>;
      const setMessagesCall = setMessagesMock.mock.calls[0];
      const newMessages = setMessagesCall?.[0];
      expect(newMessages).toBeDefined();
      // 2 new messages (summary + ack) + 2 preserved = 4
      expect(newMessages?.length).toBe(4);
    });

    it('should return compression ratio', async () => {
      const mockSummarizer: Summarizer = {
        summarize: vi.fn().mockResolvedValue({
          narrative: 'Short summary',
          extractedData: undefined,
        }),
      };

      const result = await engine.execute({ summarizer: mockSummarizer });

      expect(result.compressionRatio).toBeGreaterThan(0);
      expect(result.compressionRatio).toBeLessThanOrEqual(1);
    });
  });

  describe('onNeeded callback', () => {
    it('should trigger callback when compaction needed', () => {
      const callback = vi.fn();
      engine.onNeeded(callback);

      engine.triggerIfNeeded();

      expect(callback).toHaveBeenCalled();
    });

    it('should not trigger callback when compaction not needed', () => {
      (mockDeps.getCurrentTokens as ReturnType<typeof vi.fn>).mockReturnValue(50000);
      const callback = vi.fn();
      engine.onNeeded(callback);

      engine.triggerIfNeeded();

      expect(callback).not.toHaveBeenCalled();
    });

    it('should not trigger if no callback registered', () => {
      // Should not throw
      expect(() => engine.triggerIfNeeded()).not.toThrow();
    });
  });

  describe('preserveRecentTurns configuration', () => {
    it('should preserve multiple turns when configured', async () => {
      engine = createCompactionEngine(
        { threshold: 0.70, preserveRecentTurns: 2 },
        mockDeps
      );
      const mockSummarizer: Summarizer = {
        summarize: vi.fn().mockResolvedValue({
          narrative: 'Summary',
          extractedData: undefined,
        }),
      };

      const preview = await engine.preview(mockSummarizer);

      // With preserveRecentTurns=2, we should preserve 4 messages (2 turns)
      expect(preview.preservedTurns).toBe(2);
      // 6 messages - 4 preserved = 2 summarized = 1 turn
      expect(preview.summarizedTurns).toBe(1);
    });

    it('should handle preserveRecentTurns=0', async () => {
      engine = createCompactionEngine(
        { threshold: 0.70, preserveRecentTurns: 0 },
        mockDeps
      );
      const mockSummarizer: Summarizer = {
        summarize: vi.fn().mockResolvedValue({
          narrative: 'Summary',
          extractedData: undefined,
        }),
      };

      const preview = await engine.preview(mockSummarizer);

      expect(preview.preservedTurns).toBe(0);
      expect(preview.summarizedTurns).toBe(3);
    });
  });

  describe('factory function', () => {
    it('should create CompactionEngine instance', () => {
      const engine = createCompactionEngine(
        { threshold: 0.80, preserveRecentTurns: 2 },
        mockDeps
      );

      expect(engine).toBeInstanceOf(CompactionEngine);
    });
  });
});
