/**
 * @fileoverview TokenUsageTracker Unit Tests (TDD)
 *
 * Tests for the TokenUsageTracker utility class.
 * Handles token normalization, provider type management, and context baseline tracking.
 */
import { describe, it, expect, beforeEach } from 'vitest';
import {
  TokenUsageTracker,
  createTokenUsageTracker,
  type RawTokenUsage,
} from '../token-usage-tracker.js';

describe('TokenUsageTracker', () => {
  let tracker: TokenUsageTracker;

  beforeEach(() => {
    tracker = createTokenUsageTracker();
  });

  // ===========================================================================
  // Provider Type Management
  // ===========================================================================

  describe('Provider Type Management', () => {
    it('defaults to anthropic provider', () => {
      expect(tracker.getProviderType()).toBe('anthropic');
    });

    it('can set provider type', () => {
      tracker.setProviderType('openai');
      expect(tracker.getProviderType()).toBe('openai');
    });

    it('accepts all valid provider types', () => {
      const providers = ['anthropic', 'openai', 'openai-codex', 'google'] as const;
      for (const provider of providers) {
        tracker.setProviderType(provider);
        expect(tracker.getProviderType()).toBe(provider);
      }
    });

    it('resets context baseline when provider changes', () => {
      // Record some token usage to establish baseline
      tracker.recordTokenUsage({
        inputTokens: 1000,
        outputTokens: 100,
      });
      expect(tracker.getContextBaseline()).toBe(1000);

      // Change provider - baseline should reset
      tracker.setProviderType('openai');
      expect(tracker.getContextBaseline()).toBe(0);
    });

    it('does not reset baseline when setting same provider', () => {
      tracker.recordTokenUsage({
        inputTokens: 1000,
        outputTokens: 100,
      });
      expect(tracker.getContextBaseline()).toBe(1000);

      // Set same provider - baseline should persist
      tracker.setProviderType('anthropic');
      expect(tracker.getContextBaseline()).toBe(1000);
    });

    it('can initialize with custom provider type', () => {
      const customTracker = createTokenUsageTracker({ initialProviderType: 'google' });
      expect(customTracker.getProviderType()).toBe('google');
    });
  });

  // ===========================================================================
  // Token Usage Recording
  // ===========================================================================

  describe('Token Usage Recording', () => {
    it('records raw token usage', () => {
      const usage: RawTokenUsage = {
        inputTokens: 500,
        outputTokens: 100,
      };
      tracker.recordTokenUsage(usage);

      const raw = tracker.getLastRawUsage();
      expect(raw).toEqual(usage);
    });

    it('records usage with cache tokens', () => {
      const usage: RawTokenUsage = {
        inputTokens: 200,
        outputTokens: 100,
        cacheReadTokens: 300,
        cacheCreationTokens: 50,
      };
      tracker.recordTokenUsage(usage);

      const raw = tracker.getLastRawUsage();
      expect(raw).toEqual(usage);
    });

    it('returns undefined when no usage recorded', () => {
      expect(tracker.getLastRawUsage()).toBeUndefined();
      expect(tracker.getLastNormalizedUsage()).toBeUndefined();
    });

    it('overwrites previous usage on new recording', () => {
      tracker.recordTokenUsage({ inputTokens: 100, outputTokens: 10 });
      tracker.recordTokenUsage({ inputTokens: 200, outputTokens: 20 });

      const raw = tracker.getLastRawUsage();
      expect(raw?.inputTokens).toBe(200);
      expect(raw?.outputTokens).toBe(20);
    });
  });

  // ===========================================================================
  // Token Normalization - Anthropic
  // ===========================================================================

  describe('Token Normalization - Anthropic', () => {
    beforeEach(() => {
      tracker.setProviderType('anthropic');
    });

    it('calculates contextWindowTokens as input + cache for Anthropic', () => {
      tracker.recordTokenUsage({
        inputTokens: 200,
        outputTokens: 100,
        cacheReadTokens: 300,
        cacheCreationTokens: 50,
      });

      const normalized = tracker.getLastNormalizedUsage();
      // contextWindowTokens = inputTokens + cacheRead + cacheCreate
      expect(normalized?.contextWindowTokens).toBe(200 + 300 + 50);
    });

    it('handles missing cache tokens for Anthropic', () => {
      tracker.recordTokenUsage({
        inputTokens: 500,
        outputTokens: 100,
      });

      const normalized = tracker.getLastNormalizedUsage();
      expect(normalized?.contextWindowTokens).toBe(500);
    });

    it('calculates newInputTokens as delta from baseline', () => {
      // First turn - no baseline
      tracker.recordTokenUsage({ inputTokens: 1000, outputTokens: 100 });
      let normalized = tracker.getLastNormalizedUsage();
      expect(normalized?.newInputTokens).toBe(1000); // Full amount on first turn

      // Second turn - should show delta
      tracker.recordTokenUsage({ inputTokens: 1200, outputTokens: 50 });
      normalized = tracker.getLastNormalizedUsage();
      expect(normalized?.newInputTokens).toBe(200); // Delta from previous
    });

    it('updates baseline after each recording', () => {
      tracker.recordTokenUsage({ inputTokens: 1000, outputTokens: 100 });
      expect(tracker.getContextBaseline()).toBe(1000);

      tracker.recordTokenUsage({ inputTokens: 1500, outputTokens: 100 });
      expect(tracker.getContextBaseline()).toBe(1500);
    });
  });

  // ===========================================================================
  // Token Normalization - OpenAI
  // ===========================================================================

  describe('Token Normalization - OpenAI', () => {
    beforeEach(() => {
      tracker.setProviderType('openai');
    });

    it('uses inputTokens directly as contextWindowTokens for OpenAI', () => {
      tracker.recordTokenUsage({
        inputTokens: 1000,
        outputTokens: 100,
      });

      const normalized = tracker.getLastNormalizedUsage();
      expect(normalized?.contextWindowTokens).toBe(1000);
    });

    it('calculates delta correctly for OpenAI', () => {
      tracker.recordTokenUsage({ inputTokens: 500, outputTokens: 50 });
      let normalized = tracker.getLastNormalizedUsage();
      expect(normalized?.newInputTokens).toBe(500);

      tracker.recordTokenUsage({ inputTokens: 800, outputTokens: 50 });
      normalized = tracker.getLastNormalizedUsage();
      expect(normalized?.newInputTokens).toBe(300);
    });
  });

  // ===========================================================================
  // Token Normalization - OpenAI Codex
  // ===========================================================================

  describe('Token Normalization - OpenAI Codex', () => {
    beforeEach(() => {
      tracker.setProviderType('openai-codex');
    });

    it('uses inputTokens directly for Codex', () => {
      tracker.recordTokenUsage({
        inputTokens: 2000,
        outputTokens: 200,
      });

      const normalized = tracker.getLastNormalizedUsage();
      expect(normalized?.contextWindowTokens).toBe(2000);
    });
  });

  // ===========================================================================
  // Token Normalization - Google
  // ===========================================================================

  describe('Token Normalization - Google', () => {
    beforeEach(() => {
      tracker.setProviderType('google');
    });

    it('uses inputTokens directly for Google', () => {
      tracker.recordTokenUsage({
        inputTokens: 1500,
        outputTokens: 150,
      });

      const normalized = tracker.getLastNormalizedUsage();
      expect(normalized?.contextWindowTokens).toBe(1500);
    });
  });

  // ===========================================================================
  // Context Baseline Tracking
  // ===========================================================================

  describe('Context Baseline Tracking', () => {
    it('starts with zero baseline', () => {
      expect(tracker.getContextBaseline()).toBe(0);
    });

    it('persists baseline across multiple recordings', () => {
      tracker.recordTokenUsage({ inputTokens: 100, outputTokens: 10 });
      tracker.recordTokenUsage({ inputTokens: 200, outputTokens: 20 });
      tracker.recordTokenUsage({ inputTokens: 300, outputTokens: 30 });

      // Baseline should be last contextWindowTokens
      expect(tracker.getContextBaseline()).toBe(300);
    });

    it('preserves baseline on resetForNewTurn', () => {
      tracker.recordTokenUsage({ inputTokens: 1000, outputTokens: 100 });
      expect(tracker.getContextBaseline()).toBe(1000);

      tracker.resetForNewTurn();

      // Baseline persists
      expect(tracker.getContextBaseline()).toBe(1000);
      // But raw/normalized usage is cleared
      expect(tracker.getLastRawUsage()).toBeUndefined();
      expect(tracker.getLastNormalizedUsage()).toBeUndefined();
    });

    it('preserves baseline on resetForNewAgent', () => {
      tracker.recordTokenUsage({ inputTokens: 2000, outputTokens: 200 });
      expect(tracker.getContextBaseline()).toBe(2000);

      tracker.resetForNewAgent();

      // Baseline persists (critical for accurate delta calculation)
      expect(tracker.getContextBaseline()).toBe(2000);
      // Usage is cleared
      expect(tracker.getLastRawUsage()).toBeUndefined();
    });

    it('resets baseline only on provider change', () => {
      tracker.recordTokenUsage({ inputTokens: 1000, outputTokens: 100 });

      // These should NOT reset baseline
      tracker.resetForNewTurn();
      expect(tracker.getContextBaseline()).toBe(1000);

      tracker.resetForNewAgent();
      expect(tracker.getContextBaseline()).toBe(1000);

      // This SHOULD reset baseline
      tracker.setProviderType('openai');
      expect(tracker.getContextBaseline()).toBe(0);
    });
  });

  // ===========================================================================
  // Lifecycle Methods
  // ===========================================================================

  describe('Lifecycle Methods', () => {
    describe('resetForNewTurn', () => {
      it('clears raw and normalized usage', () => {
        tracker.recordTokenUsage({ inputTokens: 500, outputTokens: 50 });
        expect(tracker.getLastRawUsage()).toBeDefined();
        expect(tracker.getLastNormalizedUsage()).toBeDefined();

        tracker.resetForNewTurn();

        expect(tracker.getLastRawUsage()).toBeUndefined();
        expect(tracker.getLastNormalizedUsage()).toBeUndefined();
      });

      it('preserves provider type', () => {
        tracker.setProviderType('google');
        tracker.resetForNewTurn();
        expect(tracker.getProviderType()).toBe('google');
      });
    });

    describe('resetForNewAgent', () => {
      it('clears raw and normalized usage', () => {
        tracker.recordTokenUsage({ inputTokens: 500, outputTokens: 50 });

        tracker.resetForNewAgent();

        expect(tracker.getLastRawUsage()).toBeUndefined();
        expect(tracker.getLastNormalizedUsage()).toBeUndefined();
      });

      it('preserves provider type', () => {
        tracker.setProviderType('openai-codex');
        tracker.resetForNewAgent();
        expect(tracker.getProviderType()).toBe('openai-codex');
      });

      it('preserves baseline for accurate delta across agent runs', () => {
        // This is critical behavior - agent runs start on every user message
        // but we want consistent delta tracking across the session
        tracker.recordTokenUsage({ inputTokens: 5000, outputTokens: 500 });
        const baseline = tracker.getContextBaseline();

        tracker.resetForNewAgent();

        expect(tracker.getContextBaseline()).toBe(baseline);
      });
    });
  });

  // ===========================================================================
  // Normalized Usage Fields
  // ===========================================================================

  describe('Normalized Usage Fields', () => {
    it('includes all required fields', () => {
      tracker.recordTokenUsage({
        inputTokens: 1000,
        outputTokens: 100,
        cacheReadTokens: 200,
        cacheCreationTokens: 50,
      });

      const normalized = tracker.getLastNormalizedUsage();
      expect(normalized).toBeDefined();
      expect(normalized).toHaveProperty('rawInputTokens');
      expect(normalized).toHaveProperty('newInputTokens');
      expect(normalized).toHaveProperty('contextWindowTokens');
      expect(normalized).toHaveProperty('outputTokens');
      expect(normalized).toHaveProperty('cacheReadTokens');
      expect(normalized).toHaveProperty('cacheCreationTokens');
    });

    it('preserves raw values in normalized output', () => {
      const usage: RawTokenUsage = {
        inputTokens: 1000,
        outputTokens: 100,
        cacheReadTokens: 200,
        cacheCreationTokens: 50,
      };
      tracker.recordTokenUsage(usage);

      const normalized = tracker.getLastNormalizedUsage();
      expect(normalized?.rawInputTokens).toBe(1000);
      expect(normalized?.outputTokens).toBe(100);
      expect(normalized?.cacheReadTokens).toBe(200);
      expect(normalized?.cacheCreationTokens).toBe(50);
    });
  });

  // ===========================================================================
  // Edge Cases
  // ===========================================================================

  describe('Edge Cases', () => {
    it('handles zero input tokens', () => {
      tracker.recordTokenUsage({ inputTokens: 0, outputTokens: 100 });

      const normalized = tracker.getLastNormalizedUsage();
      expect(normalized?.contextWindowTokens).toBe(0);
      expect(normalized?.newInputTokens).toBe(0);
    });

    it('handles context shrinking (returns 0 for new tokens)', () => {
      // Record high baseline
      tracker.recordTokenUsage({ inputTokens: 1000, outputTokens: 100 });

      // Record lower value (edge case - context shrinking from summarization/truncation)
      tracker.recordTokenUsage({ inputTokens: 500, outputTokens: 50 });

      const normalized = tracker.getLastNormalizedUsage();
      // When context shrinks, newInputTokens should be 0 (not negative)
      expect(normalized?.newInputTokens).toBe(0);
    });

    it('handles very large token counts', () => {
      const largeCount = 1_000_000;
      tracker.recordTokenUsage({
        inputTokens: largeCount,
        outputTokens: largeCount / 10,
      });

      const normalized = tracker.getLastNormalizedUsage();
      expect(normalized?.contextWindowTokens).toBe(largeCount);
    });

    it('handles rapid successive recordings', () => {
      for (let i = 1; i <= 10; i++) {
        tracker.recordTokenUsage({
          inputTokens: i * 100,
          outputTokens: i * 10,
        });
      }

      const normalized = tracker.getLastNormalizedUsage();
      expect(normalized?.contextWindowTokens).toBe(1000);
      expect(normalized?.newInputTokens).toBe(100); // Delta from 900 to 1000
    });

    it('maintains consistency across provider switch mid-session', () => {
      // Start with Anthropic
      tracker.setProviderType('anthropic');
      tracker.recordTokenUsage({
        inputTokens: 500,
        outputTokens: 50,
        cacheReadTokens: 500,
      });
      expect(tracker.getContextBaseline()).toBe(1000); // 500 + 500

      // Switch to OpenAI - baseline resets
      tracker.setProviderType('openai');
      expect(tracker.getContextBaseline()).toBe(0);

      // Record with new provider
      tracker.recordTokenUsage({ inputTokens: 800, outputTokens: 80 });
      const normalized = tracker.getLastNormalizedUsage();
      expect(normalized?.newInputTokens).toBe(800); // Full amount, fresh baseline
      expect(normalized?.contextWindowTokens).toBe(800);
    });
  });
});
