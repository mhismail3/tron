/**
 * @fileoverview Token Normalizer Tests
 *
 * Tests for token usage normalization across different providers.
 */

import { describe, it, expect } from 'vitest';
import { normalizeTokenUsage, detectProviderType } from '../token-normalizer.js';

describe('normalizeTokenUsage', () => {
  describe('Anthropic provider (inputTokens is cumulative non-cached)', () => {
    it('calculates contextWindowTokens including cache on first turn', () => {
      // Turn 1: inputTokens=500 (conversation), cacheCreate=8000 (system prompt)
      const result = normalizeTokenUsage(
        { inputTokens: 500, outputTokens: 100, cacheCreationTokens: 8000 },
        'anthropic',
        0
      );

      expect(result.newInputTokens).toBe(8500); // First turn: all context is "new"
      expect(result.contextWindowTokens).toBe(8500); // 500 + 8000
      expect(result.rawInputTokens).toBe(500);
    });

    it('calculates delta from previous context on subsequent turns', () => {
      // Turn 2: inputTokens=604 (grew by 104), cacheRead=8000 (system prompt)
      // Previous contextWindowTokens was 8500
      const result = normalizeTokenUsage(
        { inputTokens: 604, outputTokens: 100, cacheReadTokens: 8000 },
        'anthropic',
        8500 // Previous context size
      );

      expect(result.newInputTokens).toBe(104); // 8604 - 8500
      expect(result.contextWindowTokens).toBe(8604); // 604 + 8000
      expect(result.cacheReadTokens).toBe(8000);
    });

    it('calculates contextWindowTokens including both cache read and creation', () => {
      const result = normalizeTokenUsage(
        { inputTokens: 500, outputTokens: 100, cacheReadTokens: 4000, cacheCreationTokens: 200 },
        'anthropic',
        0
      );

      expect(result.contextWindowTokens).toBe(500 + 4000 + 200); // 4700
      expect(result.cacheReadTokens).toBe(4000);
      expect(result.cacheCreationTokens).toBe(200);
    });

    it('uses previousContextSize for delta calculation', () => {
      // Previous context was 10000, now it's 4500
      // Context shrank (maybe cache eviction)
      const result = normalizeTokenUsage(
        { inputTokens: 500, outputTokens: 100, cacheReadTokens: 4000 },
        'anthropic',
        10000
      );

      expect(result.newInputTokens).toBe(0); // Context shrank, report 0
      expect(result.contextWindowTokens).toBe(4500);
    });
  });

  describe('OpenAI provider (inputTokens is full context)', () => {
    it('calculates delta for normal turn', () => {
      const result = normalizeTokenUsage(
        { inputTokens: 5000, outputTokens: 100 },
        'openai',
        4000 // Previous context was 4000
      );

      expect(result.newInputTokens).toBe(1000); // 5000 - 4000
      expect(result.rawInputTokens).toBe(5000);
      expect(result.contextWindowTokens).toBe(5000);
    });

    it('uses full context as new on first turn (previousContextSize = 0)', () => {
      const result = normalizeTokenUsage(
        { inputTokens: 5000, outputTokens: 100 },
        'openai',
        0
      );

      expect(result.newInputTokens).toBe(5000); // All new on first turn
      expect(result.contextWindowTokens).toBe(5000);
    });

    it('includes cache tokens in result', () => {
      const result = normalizeTokenUsage(
        { inputTokens: 5000, outputTokens: 100, cacheReadTokens: 1000 },
        'openai',
        4000
      );

      expect(result.cacheReadTokens).toBe(1000);
    });
  });

  describe('OpenAI Codex provider (inputTokens is full context)', () => {
    it('handles context shrink gracefully (returns 0)', () => {
      const result = normalizeTokenUsage(
        { inputTokens: 7803, outputTokens: 100 },
        'openai-codex',
        11920 // Previous was larger
      );

      expect(result.newInputTokens).toBe(0); // Clamped to 0
      expect(result.contextWindowTokens).toBe(7803);
      expect(result.rawInputTokens).toBe(7803);
    });

    it('calculates delta for normal turn', () => {
      const result = normalizeTokenUsage(
        { inputTokens: 12000, outputTokens: 200 },
        'openai-codex',
        11000
      );

      expect(result.newInputTokens).toBe(1000); // 12000 - 11000
      expect(result.contextWindowTokens).toBe(12000);
    });
  });

  describe('Google provider (inputTokens is full context)', () => {
    it('calculates delta like OpenAI', () => {
      const result = normalizeTokenUsage(
        { inputTokens: 8000, outputTokens: 150 },
        'google',
        6000
      );

      expect(result.newInputTokens).toBe(2000); // 8000 - 6000
      expect(result.contextWindowTokens).toBe(8000);
    });

    it('handles first turn with full context', () => {
      const result = normalizeTokenUsage(
        { inputTokens: 8000, outputTokens: 150 },
        'google',
        0
      );

      expect(result.newInputTokens).toBe(8000); // All new on first turn
    });
  });

  describe('edge cases', () => {
    it('handles zero tokens', () => {
      const result = normalizeTokenUsage(
        { inputTokens: 0, outputTokens: 0 },
        'anthropic',
        0
      );

      expect(result.newInputTokens).toBe(0);
      expect(result.outputTokens).toBe(0);
      expect(result.contextWindowTokens).toBe(0);
    });

    it('handles missing cache tokens', () => {
      const result = normalizeTokenUsage(
        { inputTokens: 1000, outputTokens: 100 },
        'anthropic',
        0
      );

      expect(result.cacheReadTokens).toBe(0);
      expect(result.cacheCreationTokens).toBe(0);
    });
  });
});

describe('detectProviderType', () => {
  it('detects Anthropic models', () => {
    expect(detectProviderType('claude-sonnet-4-20250514')).toBe('anthropic');
    expect(detectProviderType('claude-opus-4-0-20250514')).toBe('anthropic');
    expect(detectProviderType('claude-3-5-sonnet-20241022')).toBe('anthropic');
    expect(detectProviderType('claude-3-5-haiku-20241022')).toBe('anthropic');
  });

  it('detects OpenAI Codex models', () => {
    expect(detectProviderType('gpt-5.2-codex')).toBe('openai-codex');
    expect(detectProviderType('gpt-5.1-codex-max')).toBe('openai-codex');
    expect(detectProviderType('gpt-5.1-codex-mini')).toBe('openai-codex');
    expect(detectProviderType('o1-preview')).toBe('openai-codex');
    expect(detectProviderType('o3-mini')).toBe('openai-codex');
    expect(detectProviderType('o4-mini')).toBe('openai-codex');
  });

  it('detects OpenAI GPT models', () => {
    expect(detectProviderType('gpt-4o')).toBe('openai');
    expect(detectProviderType('gpt-4-turbo')).toBe('openai');
    expect(detectProviderType('gpt-3.5-turbo')).toBe('openai');
    expect(detectProviderType('openai/gpt-4')).toBe('openai');
  });

  it('detects Google Gemini models', () => {
    expect(detectProviderType('gemini-3-pro-preview')).toBe('google');
    expect(detectProviderType('gemini-2.5-flash')).toBe('google');
    expect(detectProviderType('google/gemini-pro')).toBe('google');
  });

  it('defaults to anthropic for unknown models', () => {
    expect(detectProviderType('unknown-model')).toBe('anthropic');
    expect(detectProviderType('my-custom-model')).toBe('anthropic');
  });
});
