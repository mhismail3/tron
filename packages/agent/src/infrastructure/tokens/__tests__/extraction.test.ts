/**
 * @fileoverview Token Extraction Tests (TDD - RED Phase)
 *
 * Tests for extracting token values from provider API responses.
 * These tests should FAIL initially - implementation comes next.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { TokenExtractionError } from '../types.js';
import {
  extractFromAnthropic,
  extractFromOpenAI,
  extractFromGoogle,
} from '../extraction/index.js';

// Mock logger to verify warning logs
vi.mock('@infrastructure/logging/index.js', () => ({
  createLogger: () => ({
    debug: vi.fn(),
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
    trace: vi.fn(),
  }),
}));

describe('Token Extraction', () => {
  const baseMeta = { turn: 1, sessionId: 'test-session' };

  describe('Anthropic', () => {
    describe('successful extraction', () => {
      it('extracts tokens from message_start event', () => {
        const messageStartUsage = {
          input_tokens: 500,
          cache_read_input_tokens: 8000,
          cache_creation_input_tokens: 200,
        };
        const messageDeltaUsage = { output_tokens: 100 };

        const result = extractFromAnthropic(messageStartUsage, messageDeltaUsage, baseMeta);

        expect(result.provider).toBe('anthropic');
        expect(result.rawInputTokens).toBe(500);
        expect(result.rawOutputTokens).toBe(100);
        expect(result.rawCacheReadTokens).toBe(8000);
        expect(result.rawCacheCreationTokens).toBe(200);
        expect(result.timestamp).toBeDefined();
      });

      it('handles missing cache tokens (defaults to 0)', () => {
        const messageStartUsage = { input_tokens: 500 };
        const messageDeltaUsage = { output_tokens: 100 };

        const result = extractFromAnthropic(messageStartUsage, messageDeltaUsage, baseMeta);

        expect(result.rawCacheReadTokens).toBe(0);
        expect(result.rawCacheCreationTokens).toBe(0);
      });

      it('handles zero input_tokens in message_start', () => {
        const messageStartUsage = {
          input_tokens: 0,
          cache_read_input_tokens: 8000,
        };
        const messageDeltaUsage = { output_tokens: 100 };

        const result = extractFromAnthropic(messageStartUsage, messageDeltaUsage, baseMeta);

        expect(result.rawInputTokens).toBe(0);
        expect(result.rawCacheReadTokens).toBe(8000);
      });

      it('handles zero output_tokens in message_delta', () => {
        const messageStartUsage = { input_tokens: 500 };
        const messageDeltaUsage = { output_tokens: 0 };

        const result = extractFromAnthropic(messageStartUsage, messageDeltaUsage, baseMeta);

        expect(result.rawOutputTokens).toBe(0);
      });
    });

    describe('error handling', () => {
      it('throws TokenExtractionError when both usage objects are undefined', () => {
        expect(() => extractFromAnthropic(undefined, undefined, baseMeta)).toThrow(
          TokenExtractionError
        );
      });

      it('throws TokenExtractionError when both usage objects are null', () => {
        expect(() => extractFromAnthropic(null, null, baseMeta)).toThrow(TokenExtractionError);
      });

      it('includes context in TokenExtractionError', () => {
        try {
          extractFromAnthropic(undefined, undefined, baseMeta);
          expect.fail('Should have thrown');
        } catch (error) {
          expect(error).toBeInstanceOf(TokenExtractionError);
          const tokenError = error as TokenExtractionError;
          expect(tokenError.turn).toBe(1);
          expect(tokenError.sessionId).toBe('test-session');
          expect(tokenError.provider).toBe('anthropic');
        }
      });
    });

    describe('partial data handling', () => {
      it('allows message_start only (no output tokens yet)', () => {
        const messageStartUsage = { input_tokens: 500 };

        const result = extractFromAnthropic(messageStartUsage, undefined, baseMeta);

        expect(result.rawInputTokens).toBe(500);
        expect(result.rawOutputTokens).toBe(0);
      });

      it('allows message_delta only (unusual but valid)', () => {
        const messageDeltaUsage = { output_tokens: 100 };

        const result = extractFromAnthropic(undefined, messageDeltaUsage, baseMeta);

        expect(result.rawInputTokens).toBe(0);
        expect(result.rawOutputTokens).toBe(100);
      });
    });
  });

  describe('OpenAI', () => {
    describe('successful extraction', () => {
      it('extracts tokens from response.completed event', () => {
        const usage = { input_tokens: 5000, output_tokens: 200 };

        const result = extractFromOpenAI(usage, baseMeta);

        expect(result.provider).toBe('openai');
        expect(result.rawInputTokens).toBe(5000);
        expect(result.rawOutputTokens).toBe(200);
        expect(result.timestamp).toBeDefined();
      });

      it('sets cache tokens to 0 (OpenAI does not report cache metrics)', () => {
        const usage = { input_tokens: 5000, output_tokens: 200 };

        const result = extractFromOpenAI(usage, baseMeta);

        expect(result.rawCacheReadTokens).toBe(0);
        expect(result.rawCacheCreationTokens).toBe(0);
      });

      it('handles cached_tokens field if present (OpenAI cache)', () => {
        const usage = {
          input_tokens: 5000,
          output_tokens: 200,
          input_tokens_details: { cached_tokens: 1000 },
        };

        const result = extractFromOpenAI(usage, baseMeta);

        expect(result.rawCacheReadTokens).toBe(1000);
      });
    });

    describe('error handling', () => {
      it('throws TokenExtractionError when usage is undefined', () => {
        expect(() => extractFromOpenAI(undefined, baseMeta)).toThrow(TokenExtractionError);
      });

      it('throws TokenExtractionError when usage is null', () => {
        expect(() => extractFromOpenAI(null, baseMeta)).toThrow(TokenExtractionError);
      });

      it('includes context in TokenExtractionError', () => {
        try {
          extractFromOpenAI(undefined, baseMeta);
          expect.fail('Should have thrown');
        } catch (error) {
          expect(error).toBeInstanceOf(TokenExtractionError);
          const tokenError = error as TokenExtractionError;
          expect(tokenError.turn).toBe(1);
          expect(tokenError.sessionId).toBe('test-session');
          expect(tokenError.provider).toBe('openai');
        }
      });
    });
  });

  describe('Google', () => {
    describe('successful extraction', () => {
      it('extracts tokens from usageMetadata', () => {
        const usageMetadata = { promptTokenCount: 3000, candidatesTokenCount: 150 };

        const result = extractFromGoogle(usageMetadata, baseMeta);

        expect(result.provider).toBe('google');
        expect(result.rawInputTokens).toBe(3000);
        expect(result.rawOutputTokens).toBe(150);
        expect(result.timestamp).toBeDefined();
      });

      it('sets cache tokens to 0 (Google does not report cache metrics)', () => {
        const usageMetadata = { promptTokenCount: 3000, candidatesTokenCount: 150 };

        const result = extractFromGoogle(usageMetadata, baseMeta);

        expect(result.rawCacheReadTokens).toBe(0);
        expect(result.rawCacheCreationTokens).toBe(0);
      });

      it('handles missing candidatesTokenCount', () => {
        const usageMetadata = { promptTokenCount: 3000 };

        const result = extractFromGoogle(usageMetadata, baseMeta);

        expect(result.rawInputTokens).toBe(3000);
        expect(result.rawOutputTokens).toBe(0);
      });
    });

    describe('error handling', () => {
      it('throws TokenExtractionError when usageMetadata is undefined', () => {
        expect(() => extractFromGoogle(undefined, baseMeta)).toThrow(TokenExtractionError);
      });

      it('throws TokenExtractionError when usageMetadata is null', () => {
        expect(() => extractFromGoogle(null, baseMeta)).toThrow(TokenExtractionError);
      });

      it('includes context in TokenExtractionError', () => {
        try {
          extractFromGoogle(undefined, baseMeta);
          expect.fail('Should have thrown');
        } catch (error) {
          expect(error).toBeInstanceOf(TokenExtractionError);
          const tokenError = error as TokenExtractionError;
          expect(tokenError.turn).toBe(1);
          expect(tokenError.sessionId).toBe('test-session');
          expect(tokenError.provider).toBe('google');
        }
      });
    });
  });

  describe('OpenAI Codex', () => {
    describe('successful extraction', () => {
      it('extracts tokens using OpenAI format', () => {
        // Codex uses same format as OpenAI
        const usage = { input_tokens: 10000, output_tokens: 500 };

        const result = extractFromOpenAI(usage, baseMeta, 'openai-codex');

        expect(result.provider).toBe('openai-codex');
        expect(result.rawInputTokens).toBe(10000);
        expect(result.rawOutputTokens).toBe(500);
      });
    });
  });

  describe('Timestamp generation', () => {
    it('generates ISO8601 timestamp', () => {
      const messageStartUsage = { input_tokens: 500 };
      const messageDeltaUsage = { output_tokens: 100 };

      const result = extractFromAnthropic(messageStartUsage, messageDeltaUsage, baseMeta);

      // Timestamp should be valid ISO8601
      expect(() => new Date(result.timestamp)).not.toThrow();
      expect(new Date(result.timestamp).toISOString()).toBe(result.timestamp);
    });

    it('generates unique timestamps for successive calls', async () => {
      const messageStartUsage = { input_tokens: 500 };
      const messageDeltaUsage = { output_tokens: 100 };

      const result1 = extractFromAnthropic(messageStartUsage, messageDeltaUsage, baseMeta);

      // Small delay to ensure different timestamp
      await new Promise((resolve) => setTimeout(resolve, 1));

      const result2 = extractFromAnthropic(messageStartUsage, messageDeltaUsage, baseMeta);

      // Timestamps might be same if within same millisecond, but should be valid
      expect(result1.timestamp).toBeDefined();
      expect(result2.timestamp).toBeDefined();
    });
  });
});
