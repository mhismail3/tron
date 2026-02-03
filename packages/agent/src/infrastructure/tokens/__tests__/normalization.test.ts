/**
 * @fileoverview Token Normalization Tests (TDD - RED Phase)
 *
 * Tests for normalizing token values across different providers.
 * These tests should FAIL initially - implementation comes next.
 */

import { describe, it, expect, vi } from 'vitest';
import type { TokenSource, TokenMeta } from '../types.js';
import { normalizeTokens } from '../normalization/index.js';

// Mock logger
vi.mock('@infrastructure/logging/index.js', () => ({
  createLogger: () => ({
    debug: vi.fn(),
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
    trace: vi.fn(),
  }),
}));

// Helper to create a TokenSource
function createSource(
  provider: TokenSource['provider'],
  rawInputTokens: number,
  rawOutputTokens: number,
  rawCacheReadTokens: number = 0,
  rawCacheCreationTokens: number = 0
): TokenSource {
  return {
    provider,
    timestamp: new Date().toISOString(),
    rawInputTokens,
    rawOutputTokens,
    rawCacheReadTokens,
    rawCacheCreationTokens,
  };
}

// Helper to create TokenMeta
function createMeta(turn: number, sessionId: string = 'test-session'): TokenMeta {
  return {
    turn,
    sessionId,
    extractedAt: new Date().toISOString(),
    normalizedAt: '',
  };
}

describe('Token Normalization', () => {
  describe('Context Window Calculation', () => {
    describe('Anthropic (cache-aware)', () => {
      it('contextWindow = inputTokens + cacheRead + cacheCreation', () => {
        const source = createSource('anthropic', 500, 100, 8000, 200);

        const record = normalizeTokens(source, 0, createMeta(1));

        // contextWindowTokens = 500 + 8000 + 200 = 8700
        expect(record.computed.contextWindowTokens).toBe(8700);
        expect(record.computed.calculationMethod).toBe('anthropic_cache_aware');
      });

      it('cacheCreation tokens ARE part of context window', () => {
        // First turn: cache is being created - these tokens are sent to the model
        const source = createSource('anthropic', 500, 100, 0, 8000);

        const record = normalizeTokens(source, 0, createMeta(1));

        // contextWindowTokens = 500 + 0 + 8000 = 8500
        expect(record.computed.contextWindowTokens).toBe(8500);
      });

      it('handles both cacheRead and cacheCreation correctly', () => {
        // Partial cache hit, partial new cache write
        const source = createSource('anthropic', 500, 100, 4000, 200);

        const record = normalizeTokens(source, 0, createMeta(1));

        // contextWindowTokens = 500 + 4000 + 200 = 4700
        expect(record.computed.contextWindowTokens).toBe(4700);
      });
    });

    describe('OpenAI (direct)', () => {
      it('contextWindow = inputTokens (full context sent)', () => {
        const source = createSource('openai', 5000, 200, 0, 0);

        const record = normalizeTokens(source, 0, createMeta(1));

        expect(record.computed.contextWindowTokens).toBe(5000);
        expect(record.computed.calculationMethod).toBe('direct');
      });

      it('ignores cacheReadTokens for context calculation', () => {
        // OpenAI might report cached_tokens but it doesn't affect context
        const source = createSource('openai', 5000, 200, 1000, 0);

        const record = normalizeTokens(source, 0, createMeta(1));

        // Still just inputTokens for OpenAI
        expect(record.computed.contextWindowTokens).toBe(5000);
      });
    });

    describe('OpenAI Codex (direct)', () => {
      it('contextWindow = inputTokens', () => {
        const source = createSource('openai-codex', 10000, 500, 0, 0);

        const record = normalizeTokens(source, 0, createMeta(1));

        expect(record.computed.contextWindowTokens).toBe(10000);
        expect(record.computed.calculationMethod).toBe('direct');
      });
    });

    describe('Google (direct)', () => {
      it('contextWindow = inputTokens', () => {
        const source = createSource('google', 3000, 150, 0, 0);

        const record = normalizeTokens(source, 0, createMeta(1));

        expect(record.computed.contextWindowTokens).toBe(3000);
        expect(record.computed.calculationMethod).toBe('direct');
      });
    });
  });

  describe('Delta Calculation', () => {
    it('first turn: newInputTokens = contextWindowTokens', () => {
      const source = createSource('anthropic', 500, 100, 8000, 0);

      const record = normalizeTokens(source, 0, createMeta(1));

      // First turn with no baseline - all tokens are "new"
      expect(record.computed.newInputTokens).toBe(8500);
      expect(record.computed.previousContextBaseline).toBe(0);
    });

    it('subsequent turn: newInputTokens = delta from previous', () => {
      const source = createSource('anthropic', 600, 100, 8000, 0);

      // Previous context was 8500
      const record = normalizeTokens(source, 8500, createMeta(2));

      // Delta: 8600 - 8500 = 100
      expect(record.computed.newInputTokens).toBe(100);
      expect(record.computed.contextWindowTokens).toBe(8600);
      expect(record.computed.previousContextBaseline).toBe(8500);
    });

    it('context growth: shows positive delta', () => {
      // Simulates realistic multi-turn session
      // Turn 5: context was 21090
      // Turn 6: context is 22070
      const source = createSource('anthropic', 3644, 486, 18426, 0);

      const record = normalizeTokens(source, 21090, createMeta(6));

      expect(record.computed.contextWindowTokens).toBe(22070); // 3644 + 18426
      expect(record.computed.newInputTokens).toBe(980); // 22070 - 21090
    });
  });

  describe('Context Shrink Handling', () => {
    it('context shrink: newInputTokens = 0 (not negative)', () => {
      // Context shrank from 10000 to 4500 (e.g., cache eviction)
      const source = createSource('anthropic', 500, 100, 4000, 0);

      const record = normalizeTokens(source, 10000, createMeta(3));

      expect(record.computed.contextWindowTokens).toBe(4500);
      expect(record.computed.newInputTokens).toBe(0); // Clamped to 0
    });

    it('context shrink: preserves baseline in record', () => {
      const source = createSource('openai', 5000, 100, 0, 0);

      const record = normalizeTokens(source, 8000, createMeta(3));

      expect(record.computed.previousContextBaseline).toBe(8000);
      expect(record.computed.newInputTokens).toBe(0);
    });

    it('handles exact same context (no change)', () => {
      const source = createSource('openai', 5000, 100, 0, 0);

      const record = normalizeTokens(source, 5000, createMeta(2));

      expect(record.computed.newInputTokens).toBe(0);
      expect(record.computed.contextWindowTokens).toBe(5000);
    });
  });

  describe('Immutability', () => {
    it('source object is frozen', () => {
      const source = createSource('anthropic', 500, 100, 0, 0);

      const record = normalizeTokens(source, 0, createMeta(1));

      expect(Object.isFrozen(record.source)).toBe(true);
    });

    it('computed object is frozen', () => {
      const source = createSource('anthropic', 500, 100, 0, 0);

      const record = normalizeTokens(source, 0, createMeta(1));

      expect(Object.isFrozen(record.computed)).toBe(true);
    });

    it('meta object is frozen', () => {
      const source = createSource('anthropic', 500, 100, 0, 0);

      const record = normalizeTokens(source, 0, createMeta(1));

      expect(Object.isFrozen(record.meta)).toBe(true);
    });

    it('entire record is frozen', () => {
      const source = createSource('anthropic', 500, 100, 0, 0);

      const record = normalizeTokens(source, 0, createMeta(1));

      expect(Object.isFrozen(record)).toBe(true);
    });

    it('cannot modify source values', () => {
      const source = createSource('anthropic', 500, 100, 0, 0);
      const record = normalizeTokens(source, 0, createMeta(1));

      // Attempting to modify should throw in strict mode or silently fail
      expect(() => {
        (record.source as { rawInputTokens: number }).rawInputTokens = 9999;
      }).toThrow();
    });
  });

  describe('Metadata Updates', () => {
    it('sets normalizedAt timestamp', () => {
      const source = createSource('anthropic', 500, 100, 0, 0);
      const meta = createMeta(1);

      const record = normalizeTokens(source, 0, meta);

      expect(record.meta.normalizedAt).toBeDefined();
      expect(record.meta.normalizedAt).not.toBe('');
      // Should be valid ISO8601
      expect(() => new Date(record.meta.normalizedAt)).not.toThrow();
    });

    it('preserves original meta values', () => {
      const source = createSource('anthropic', 500, 100, 0, 0);
      const meta = createMeta(5, 'my-session-id');

      const record = normalizeTokens(source, 0, meta);

      expect(record.meta.turn).toBe(5);
      expect(record.meta.sessionId).toBe('my-session-id');
    });
  });

  describe('Edge Cases', () => {
    it('handles zero tokens', () => {
      const source = createSource('anthropic', 0, 0, 0, 0);

      const record = normalizeTokens(source, 0, createMeta(1));

      expect(record.computed.contextWindowTokens).toBe(0);
      expect(record.computed.newInputTokens).toBe(0);
    });

    it('handles very large token counts', () => {
      const largeCount = 1_000_000;
      const source = createSource('anthropic', largeCount, largeCount / 10, 0, 0);

      const record = normalizeTokens(source, 0, createMeta(1));

      expect(record.computed.contextWindowTokens).toBe(largeCount);
    });

    it('preserves all source values in record', () => {
      const source = createSource('anthropic', 500, 100, 8000, 200);

      const record = normalizeTokens(source, 0, createMeta(1));

      expect(record.source.rawInputTokens).toBe(500);
      expect(record.source.rawOutputTokens).toBe(100);
      expect(record.source.rawCacheReadTokens).toBe(8000);
      expect(record.source.rawCacheCreationTokens).toBe(200);
      expect(record.source.provider).toBe('anthropic');
    });
  });

  describe('Real-World Scenarios', () => {
    it('handles realistic Anthropic multi-turn session', () => {
      // Turn 1: System prompt being cached (cacheCreation), small new input
      const turn1Source = createSource('anthropic', 500, 100, 0, 8000);
      const turn1 = normalizeTokens(turn1Source, 0, createMeta(1));
      // contextWindowTokens = 500 + 0 + 8000 = 8500 (cache creation IS part of context)
      expect(turn1.computed.contextWindowTokens).toBe(8500);
      expect(turn1.computed.newInputTokens).toBe(8500);

      // Turn 2: Cache hit (cacheRead), input grows slightly
      const turn2Source = createSource('anthropic', 604, 150, 8000, 0);
      const turn2 = normalizeTokens(turn2Source, turn1.computed.contextWindowTokens, createMeta(2));
      expect(turn2.computed.contextWindowTokens).toBe(8604);
      expect(turn2.computed.newInputTokens).toBe(104); // Small delta since cache was already counted

      // Turn 3: Normal growth
      const turn3Source = createSource('anthropic', 700, 200, 8000, 0);
      const turn3 = normalizeTokens(turn3Source, turn2.computed.contextWindowTokens, createMeta(3));
      expect(turn3.computed.contextWindowTokens).toBe(8700);
      expect(turn3.computed.newInputTokens).toBe(96);
    });

    it('handles OpenAI session with consistent growth', () => {
      // Turn 1
      const turn1Source = createSource('openai', 1000, 100, 0, 0);
      const turn1 = normalizeTokens(turn1Source, 0, createMeta(1));
      expect(turn1.computed.newInputTokens).toBe(1000);

      // Turn 2
      const turn2Source = createSource('openai', 1200, 150, 0, 0);
      const turn2 = normalizeTokens(turn2Source, 1000, createMeta(2));
      expect(turn2.computed.newInputTokens).toBe(200);

      // Turn 3
      const turn3Source = createSource('openai', 1500, 200, 0, 0);
      const turn3 = normalizeTokens(turn3Source, 1200, createMeta(3));
      expect(turn3.computed.newInputTokens).toBe(300);
    });
  });
});
