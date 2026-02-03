/**
 * @fileoverview TokenStateManager Tests (TDD - RED Phase)
 *
 * Tests for the TokenStateManager which handles session-level token tracking.
 * These tests should FAIL initially - implementation comes next.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import type { TokenSource, TokenMeta, TokenRecord, TokenState, AccumulatedTokens } from '../types.js';
import { TokenStateManager, createTokenStateManager } from '../state/token-state-manager.js';

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

describe('TokenStateManager', () => {
  let manager: TokenStateManager;

  beforeEach(() => {
    manager = createTokenStateManager();
  });

  describe('Construction', () => {
    it('creates with empty state', () => {
      const state = manager.getState();

      expect(state.current).toBeNull();
      expect(state.history).toEqual([]);
      expect(state.accumulated.inputTokens).toBe(0);
      expect(state.accumulated.outputTokens).toBe(0);
    });

    it('creates with default context limit', () => {
      const state = manager.getState();

      expect(state.contextWindow.maxSize).toBe(200_000);
      expect(state.contextWindow.currentSize).toBe(0);
    });

    it('can be created with custom context limit', () => {
      const customManager = createTokenStateManager({ contextLimit: 100_000 });
      const state = customManager.getState();

      expect(state.contextWindow.maxSize).toBe(100_000);
    });
  });

  describe('recordTurn', () => {
    describe('first turn', () => {
      it('creates correct state', () => {
        const source = createSource('anthropic', 500, 100, 8000, 0);
        const record = manager.recordTurn(source, createMeta(1));

        expect(record.computed.contextWindowTokens).toBe(8500);
        expect(manager.getState().current).toBe(record);
      });

      it('accumulates tokens', () => {
        const source = createSource('anthropic', 500, 100, 8000, 200);
        manager.recordTurn(source, createMeta(1));

        const state = manager.getState();
        expect(state.accumulated.inputTokens).toBe(500);
        expect(state.accumulated.outputTokens).toBe(100);
        expect(state.accumulated.cacheReadTokens).toBe(8000);
        expect(state.accumulated.cacheCreationTokens).toBe(200);
      });

      it('updates context window', () => {
        const source = createSource('anthropic', 500, 100, 8000, 0);
        manager.recordTurn(source, createMeta(1));

        const state = manager.getState();
        expect(state.contextWindow.currentSize).toBe(8500);
      });

      it('adds to history', () => {
        const source = createSource('anthropic', 500, 100, 0, 0);
        manager.recordTurn(source, createMeta(1));

        expect(manager.getState().history).toHaveLength(1);
      });
    });

    describe('subsequent turns', () => {
      it('accumulates correctly', () => {
        manager.recordTurn(createSource('anthropic', 500, 100, 8000, 0), createMeta(1));
        manager.recordTurn(createSource('anthropic', 600, 150, 8000, 0), createMeta(2));

        const state = manager.getState();
        expect(state.accumulated.inputTokens).toBe(1100); // 500 + 600
        expect(state.accumulated.outputTokens).toBe(250); // 100 + 150
        expect(state.accumulated.cacheReadTokens).toBe(16000); // 8000 + 8000
      });

      it('calculates delta from previous', () => {
        manager.recordTurn(createSource('anthropic', 500, 100, 8000, 0), createMeta(1));
        const record = manager.recordTurn(createSource('anthropic', 600, 150, 8000, 0), createMeta(2));

        expect(record.computed.newInputTokens).toBe(100); // 8600 - 8500
      });

      it('updates current to most recent', () => {
        const record1 = manager.recordTurn(createSource('anthropic', 500, 100, 0, 0), createMeta(1));
        const record2 = manager.recordTurn(createSource('anthropic', 600, 150, 0, 0), createMeta(2));

        expect(manager.getState().current).toBe(record2);
        expect(manager.getState().current).not.toBe(record1);
      });

      it('maintains full history', () => {
        manager.recordTurn(createSource('anthropic', 500, 100, 0, 0), createMeta(1));
        manager.recordTurn(createSource('anthropic', 600, 150, 0, 0), createMeta(2));
        manager.recordTurn(createSource('anthropic', 700, 200, 0, 0), createMeta(3));

        expect(manager.getState().history).toHaveLength(3);
      });
    });
  });

  describe('Context Window Calculation', () => {
    it('calculates percentUsed correctly', () => {
      manager.setContextLimit(200_000);
      manager.recordTurn(createSource('anthropic', 500, 100, 8000, 0), createMeta(1));

      const state = manager.getState();
      // 8500 / 200000 * 100 = 4.25%
      expect(state.contextWindow.percentUsed).toBeCloseTo(4.25, 1);
    });

    it('calculates tokensRemaining correctly', () => {
      manager.setContextLimit(200_000);
      manager.recordTurn(createSource('anthropic', 500, 100, 8000, 0), createMeta(1));

      const state = manager.getState();
      expect(state.contextWindow.tokensRemaining).toBe(191_500);
    });

    it('caps percentUsed at 100', () => {
      manager.setContextLimit(1000);
      manager.recordTurn(createSource('anthropic', 500, 100, 1000, 0), createMeta(1));

      const state = manager.getState();
      // 1500 / 1000 = 150%, should cap at 100
      expect(state.contextWindow.percentUsed).toBeLessThanOrEqual(100);
    });

    it('tokensRemaining never goes negative', () => {
      manager.setContextLimit(1000);
      manager.recordTurn(createSource('anthropic', 500, 100, 1000, 0), createMeta(1));

      const state = manager.getState();
      expect(state.contextWindow.tokensRemaining).toBeGreaterThanOrEqual(0);
    });
  });

  describe('Provider Switch', () => {
    it('resets baseline when provider changes', () => {
      // Start with Anthropic
      manager.recordTurn(createSource('anthropic', 500, 100, 8000, 0), createMeta(1));
      expect(manager.getState().current!.computed.previousContextBaseline).toBe(0);

      // Switch to OpenAI - baseline should reset
      manager.onProviderChange('openai');
      const record = manager.recordTurn(createSource('openai', 5000, 200, 0, 0), createMeta(2));

      expect(record.computed.previousContextBaseline).toBe(0);
      expect(record.computed.newInputTokens).toBe(5000); // All "new"
    });

    it('preserves accumulated tokens on provider switch', () => {
      manager.recordTurn(createSource('anthropic', 500, 100, 0, 0), createMeta(1));

      manager.onProviderChange('openai');
      manager.recordTurn(createSource('openai', 1000, 200, 0, 0), createMeta(2));

      const state = manager.getState();
      expect(state.accumulated.inputTokens).toBe(1500); // 500 + 1000
      expect(state.accumulated.outputTokens).toBe(300); // 100 + 200
    });

    it('preserves history on provider switch', () => {
      manager.recordTurn(createSource('anthropic', 500, 100, 0, 0), createMeta(1));

      manager.onProviderChange('openai');
      manager.recordTurn(createSource('openai', 1000, 200, 0, 0), createMeta(2));

      expect(manager.getState().history).toHaveLength(2);
    });

    it('no-op if same provider', () => {
      manager.recordTurn(createSource('anthropic', 500, 100, 8000, 0), createMeta(1));
      const baseline = manager.getState().contextWindow.currentSize;

      // Setting same provider shouldn't reset
      manager.onProviderChange('anthropic');
      const record = manager.recordTurn(createSource('anthropic', 600, 150, 8000, 0), createMeta(2));

      // Should calculate delta from previous, not treat as first turn
      expect(record.computed.previousContextBaseline).toBe(baseline);
    });
  });

  describe('Session Resume', () => {
    it('restores state from records', () => {
      // Simulate records from a previous session
      const previousRecords: TokenRecord[] = [
        {
          source: createSource('anthropic', 500, 100, 8000, 0),
          computed: {
            contextWindowTokens: 8500,
            newInputTokens: 8500,
            previousContextBaseline: 0,
            calculationMethod: 'anthropic_cache_aware',
          },
          meta: { turn: 1, sessionId: 'test', extractedAt: '', normalizedAt: '' },
        },
        {
          source: createSource('anthropic', 600, 150, 8000, 0),
          computed: {
            contextWindowTokens: 8600,
            newInputTokens: 100,
            previousContextBaseline: 8500,
            calculationMethod: 'anthropic_cache_aware',
          },
          meta: { turn: 2, sessionId: 'test', extractedAt: '', normalizedAt: '' },
        },
      ];
      const accumulated: AccumulatedTokens = {
        inputTokens: 1100,
        outputTokens: 250,
        cacheReadTokens: 16000,
        cacheCreationTokens: 0,
        cost: 0.05,
      };

      manager.restoreState({ history: previousRecords, accumulated });

      const state = manager.getState();
      expect(state.current).toEqual(previousRecords[1]);
      expect(state.accumulated).toEqual(accumulated);
      expect(state.contextWindow.currentSize).toBe(8600);
      expect(state.history).toHaveLength(2);
    });

    it('can continue recording after restore', () => {
      const previousRecords: TokenRecord[] = [
        {
          source: createSource('anthropic', 500, 100, 8000, 0),
          computed: {
            contextWindowTokens: 8500,
            newInputTokens: 8500,
            previousContextBaseline: 0,
            calculationMethod: 'anthropic_cache_aware',
          },
          meta: { turn: 1, sessionId: 'test', extractedAt: '', normalizedAt: '' },
        },
      ];
      const accumulated: AccumulatedTokens = {
        inputTokens: 500,
        outputTokens: 100,
        cacheReadTokens: 8000,
        cacheCreationTokens: 0,
        cost: 0.02,
      };

      manager.restoreState({ history: previousRecords, accumulated });

      // Continue with turn 2
      const record = manager.recordTurn(createSource('anthropic', 600, 150, 8000, 0), createMeta(2));

      expect(record.computed.previousContextBaseline).toBe(8500);
      expect(record.computed.newInputTokens).toBe(100);
      expect(manager.getState().history).toHaveLength(2);
    });

    it('handles empty restore', () => {
      manager.restoreState({ history: [], accumulated: undefined as unknown as AccumulatedTokens });

      expect(manager.getState().current).toBeNull();
      expect(manager.getState().history).toHaveLength(0);
    });
  });

  describe('Context Limit', () => {
    it('can set context limit', () => {
      manager.setContextLimit(100_000);

      expect(manager.getState().contextWindow.maxSize).toBe(100_000);
    });

    it('updates tokensRemaining when limit changes', () => {
      manager.recordTurn(createSource('anthropic', 500, 100, 8000, 0), createMeta(1));

      manager.setContextLimit(50_000);

      const state = manager.getState();
      expect(state.contextWindow.maxSize).toBe(50_000);
      expect(state.contextWindow.tokensRemaining).toBe(41_500); // 50000 - 8500
    });

    it('recalculates percentUsed when limit changes', () => {
      manager.recordTurn(createSource('anthropic', 500, 100, 8000, 0), createMeta(1));

      manager.setContextLimit(10_000);

      const state = manager.getState();
      // 8500 / 10000 * 100 = 85%
      expect(state.contextWindow.percentUsed).toBeCloseTo(85, 0);
    });
  });

  describe('Cost Accumulation', () => {
    it('accumulates cost when provided', () => {
      manager.recordTurn(createSource('anthropic', 500, 100, 0, 0), createMeta(1), 0.01);
      manager.recordTurn(createSource('anthropic', 600, 150, 0, 0), createMeta(2), 0.02);

      expect(manager.getState().accumulated.cost).toBe(0.03);
    });

    it('handles undefined cost', () => {
      manager.recordTurn(createSource('anthropic', 500, 100, 0, 0), createMeta(1));

      expect(manager.getState().accumulated.cost).toBe(0);
    });
  });

  describe('State Immutability', () => {
    it('getState returns a copy', () => {
      manager.recordTurn(createSource('anthropic', 500, 100, 0, 0), createMeta(1));

      const state1 = manager.getState();
      const state2 = manager.getState();

      // Should be equal but not the same reference
      expect(state1).toEqual(state2);
      // Modifying returned state shouldn't affect manager
    });
  });

  describe('Edge Cases', () => {
    it('handles zero tokens', () => {
      const source = createSource('anthropic', 0, 0, 0, 0);

      expect(() => manager.recordTurn(source, createMeta(1))).not.toThrow();

      const state = manager.getState();
      expect(state.contextWindow.currentSize).toBe(0);
    });

    it('handles many rapid turns', () => {
      for (let i = 1; i <= 100; i++) {
        manager.recordTurn(createSource('anthropic', i * 100, i * 10, 0, 0), createMeta(i));
      }

      const state = manager.getState();
      expect(state.history).toHaveLength(100);
      expect(state.current!.meta.turn).toBe(100);
    });

    it('handles very large token counts', () => {
      const largeCount = 1_000_000;
      manager.setContextLimit(2_000_000);

      expect(() =>
        manager.recordTurn(createSource('anthropic', largeCount, largeCount / 10, 0, 0), createMeta(1))
      ).not.toThrow();

      expect(manager.getState().contextWindow.currentSize).toBe(largeCount);
    });
  });
});
