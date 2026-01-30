/**
 * @fileoverview Tests for Haiku Summarizer Service
 *
 * TDD: Tests for the lightweight Haiku summarizer used by WebFetch.
 */

import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest';
import { createSummarizer, type SummarizerConfig } from '../summarizer.js';

describe('Haiku Summarizer', () => {
  // Mock the Anthropic SDK
  const mockCreate = vi.fn(async () => ({
    content: [{ type: 'text', text: 'This is the summarized answer.' }],
    usage: {
      input_tokens: 500,
      output_tokens: 100,
    },
    id: 'msg_123',
    model: 'claude-haiku-4-5-20251001',
    stop_reason: 'end_turn',
  }));

  const mockAnthropicClient = {
    messages: {
      create: mockCreate,
    },
  };

  let config: SummarizerConfig;

  beforeEach(() => {
    mockCreate.mockClear();
    config = {
      apiKey: 'test-api-key',
    };
  });

  describe('createSummarizer', () => {
    it('should create a summarizer function', () => {
      const summarize = createSummarizer(config);
      expect(typeof summarize).toBe('function');
    });

    it('should throw if no API key provided', () => {
      expect(() => createSummarizer({ apiKey: '' })).toThrow();
    });
  });

  describe('summarize function', () => {
    it('should call Haiku API with correct parameters', async () => {
      const summarize = createSummarizer(config, mockAnthropicClient as any);

      await summarize({
        task: 'What is the main topic?',
        model: 'claude-haiku-4-5-20251001',
        timeout: 30000,
        maxTurns: 1,
      });

      expect(mockCreate).toHaveBeenCalledTimes(1);
      const callArgs = mockCreate.mock.calls[0][0];
      expect(callArgs.model).toBe('claude-haiku-4-5-20251001');
      expect(callArgs.messages[0].content).toContain('What is the main topic?');
    });

    it('should return formatted result on success', async () => {
      const summarize = createSummarizer(config, mockAnthropicClient as any);

      const result = await summarize({
        task: 'Summarize this content',
        model: 'claude-haiku-4-5-20251001',
        timeout: 30000,
        maxTurns: 1,
      });

      expect(result.success).toBe(true);
      expect(result.output).toBe('This is the summarized answer.');
      expect(result.sessionId).toMatch(/^summarizer-/);
    });

    it('should include token usage in result', async () => {
      const summarize = createSummarizer(config, mockAnthropicClient as any);

      const result = await summarize({
        task: 'Count the words',
        model: 'claude-haiku-4-5-20251001',
        timeout: 30000,
        maxTurns: 1,
      });

      expect(result.tokenUsage).toEqual({
        inputTokens: 500,
        outputTokens: 100,
      });
    });

    it('should handle API errors gracefully', async () => {
      const errorMock = vi.fn(async () => {
        throw new Error('API rate limit exceeded');
      });
      const errorClient = { messages: { create: errorMock } };

      const summarize = createSummarizer(config, errorClient as any);

      const result = await summarize({
        task: 'Test error handling',
        model: 'claude-haiku-4-5-20251001',
        timeout: 30000,
        maxTurns: 1,
      });

      expect(result.success).toBe(false);
      expect(result.error).toContain('rate limit');
    });

    it('should handle empty response', async () => {
      const emptyMock = vi.fn(async () => ({
        content: [],
        usage: { input_tokens: 10, output_tokens: 0 },
        id: 'msg_empty',
        model: 'claude-haiku-4-5-20251001',
        stop_reason: 'end_turn',
      }));
      const emptyClient = { messages: { create: emptyMock } };

      const summarize = createSummarizer(config, emptyClient as any);

      const result = await summarize({
        task: 'Test empty response',
        model: 'claude-haiku-4-5-20251001',
        timeout: 30000,
        maxTurns: 1,
      });

      expect(result.success).toBe(true);
      expect(result.output).toBe('');
    });

    it('should use max_tokens from config', async () => {
      const configWithTokens: SummarizerConfig = {
        apiKey: 'test-key',
        maxTokens: 2048,
      };
      const summarize = createSummarizer(configWithTokens, mockAnthropicClient as any);

      await summarize({
        task: 'Test max tokens',
        model: 'claude-haiku-4-5-20251001',
        timeout: 30000,
        maxTurns: 1,
      });

      const callArgs = mockCreate.mock.calls[0][0];
      expect(callArgs.max_tokens).toBe(2048);
    });

    it('should use default max_tokens if not specified', async () => {
      const summarize = createSummarizer(config, mockAnthropicClient as any);

      await summarize({
        task: 'Test default tokens',
        model: 'claude-haiku-4-5-20251001',
        timeout: 30000,
        maxTurns: 1,
      });

      const callArgs = mockCreate.mock.calls[0][0];
      expect(callArgs.max_tokens).toBe(1024); // Default
    });

    it('should generate unique session IDs', async () => {
      const summarize = createSummarizer(config, mockAnthropicClient as any);

      const result1 = await summarize({
        task: 'First call',
        model: 'claude-haiku-4-5-20251001',
        timeout: 30000,
        maxTurns: 1,
      });

      const result2 = await summarize({
        task: 'Second call',
        model: 'claude-haiku-4-5-20251001',
        timeout: 30000,
        maxTurns: 1,
      });

      expect(result1.sessionId).not.toBe(result2.sessionId);
    });
  });
});
