/**
 * @fileoverview Compaction Threshold Boundary Tests
 *
 * Tests each threshold boundary (50%, 70%, 85%, 95%) with tokens exactly at,
 * just below, and just above the threshold to verify correct behavior.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { CompactionTestHarness } from '../__helpers__/compaction-test-harness.js';
import { PreciseTokenGenerator } from '../__helpers__/precise-token-generator.js';
import {
  ContextManager,
  createContextManager,
  type ThresholdLevel,
} from '../context-manager.js';

// =============================================================================
// Constants
// =============================================================================

const CONTEXT_LIMIT = 200_000;

// Threshold percentages (from ContextManager)
const THRESHOLDS = {
  warning: 0.50,
  alert: 0.70,
  critical: 0.85,
  exceeded: 0.95,
};

// Delta for boundary testing - needs to be large enough to account for
// system prompt overhead and token estimation variance (1% of limit)
const DELTA = Math.floor(CONTEXT_LIMIT * 0.01); // 2000 tokens

// =============================================================================
// Threshold Boundary Tests
// =============================================================================

describe('Compaction Threshold Boundaries', () => {
  describe('normal zone (0-50%)', () => {
    it('returns normal at 25% utilization', () => {
      const harness = CompactionTestHarness.atUtilization(25);
      harness.inject();

      const snapshot = harness.contextManager.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('normal');
      expect(harness.contextManager.shouldCompact()).toBe(false);
    });

    it('returns normal at 49% utilization', () => {
      const harness = CompactionTestHarness.atUtilization(49);
      harness.inject();

      const snapshot = harness.contextManager.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('normal');
    });

    it('canAcceptTurn returns true with no compaction needed', () => {
      const harness = CompactionTestHarness.atUtilization(25);
      harness.inject();

      const validation = harness.contextManager.canAcceptTurn({
        estimatedResponseTokens: 4000,
      });
      expect(validation.canProceed).toBe(true);
      expect(validation.needsCompaction).toBe(false);
    });
  });

  describe('warning threshold (50%)', () => {
    it('at exactly 49.9% returns normal', () => {
      const targetTokens = Math.floor(CONTEXT_LIMIT * 0.499);
      const harness = CompactionTestHarness.atTokens(targetTokens);
      harness.inject();

      const snapshot = harness.contextManager.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('normal');
    });

    it('at exactly 50% returns warning', () => {
      const harness = CompactionTestHarness.atThreshold('warning');
      harness.inject();

      const snapshot = harness.contextManager.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('warning');
    });

    it('at 50.1% returns warning', () => {
      const targetTokens = Math.floor(CONTEXT_LIMIT * 0.501);
      const harness = CompactionTestHarness.atTokens(targetTokens);
      harness.inject();

      const snapshot = harness.contextManager.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('warning');
    });

    it('shouldCompact still returns false at warning level', () => {
      const harness = CompactionTestHarness.atThreshold('warning');
      harness.inject();

      // Default threshold for shouldCompact is 70%, so warning (50%) should not trigger
      expect(harness.contextManager.shouldCompact()).toBe(false);
    });
  });

  describe('alert threshold (70%)', () => {
    it('at exactly 69.9% returns warning', () => {
      const targetTokens = Math.floor(CONTEXT_LIMIT * 0.699);
      const harness = CompactionTestHarness.atTokens(targetTokens);
      harness.inject();

      const snapshot = harness.contextManager.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('warning');
    });

    it('at exactly 70% returns alert', () => {
      const harness = CompactionTestHarness.atThreshold('alert');
      harness.inject();

      const snapshot = harness.contextManager.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('alert');
    });

    it('at 70.1% returns alert', () => {
      const targetTokens = Math.floor(CONTEXT_LIMIT * 0.701);
      const harness = CompactionTestHarness.atTokens(targetTokens);
      harness.inject();

      const snapshot = harness.contextManager.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('alert');
    });

    it('shouldCompact returns true at alert level', () => {
      const harness = CompactionTestHarness.atThreshold('alert');
      harness.inject();

      expect(harness.contextManager.shouldCompact()).toBe(true);
    });

    it('canAcceptTurn suggests compaction at alert level', () => {
      const harness = CompactionTestHarness.atThreshold('alert');
      harness.inject();

      const validation = harness.contextManager.canAcceptTurn({
        estimatedResponseTokens: 4000,
      });
      expect(validation.canProceed).toBe(true);
      expect(validation.needsCompaction).toBe(true);
    });

    it('just below alert boundary does not suggest compaction', () => {
      const harness = CompactionTestHarness.nearThreshold('alert', -DELTA);
      harness.inject();

      const validation = harness.contextManager.canAcceptTurn({
        estimatedResponseTokens: 4000,
      });
      expect(validation.needsCompaction).toBe(false);
    });

    it('just above alert boundary suggests compaction', () => {
      const harness = CompactionTestHarness.nearThreshold('alert', DELTA);
      harness.inject();

      const validation = harness.contextManager.canAcceptTurn({
        estimatedResponseTokens: 4000,
      });
      expect(validation.needsCompaction).toBe(true);
    });
  });

  describe('critical threshold (85%)', () => {
    it('at exactly 84.9% returns alert', () => {
      const targetTokens = Math.floor(CONTEXT_LIMIT * 0.849);
      const harness = CompactionTestHarness.atTokens(targetTokens);
      harness.inject();

      const snapshot = harness.contextManager.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('alert');
    });

    it('at exactly 85% returns critical', () => {
      const harness = CompactionTestHarness.atThreshold('critical');
      harness.inject();

      const snapshot = harness.contextManager.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('critical');
    });

    it('at 85.1% returns critical', () => {
      const targetTokens = Math.floor(CONTEXT_LIMIT * 0.851);
      const harness = CompactionTestHarness.atTokens(targetTokens);
      harness.inject();

      const snapshot = harness.contextManager.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('critical');
    });

    it('canAcceptTurn blocks new turns at critical level', () => {
      const harness = CompactionTestHarness.atThreshold('critical');
      harness.inject();

      const validation = harness.contextManager.canAcceptTurn({
        estimatedResponseTokens: 4000,
      });
      expect(validation.canProceed).toBe(false);
      expect(validation.needsCompaction).toBe(true);
    });

    it('just below critical boundary allows turns', () => {
      const harness = CompactionTestHarness.nearThreshold('critical', -DELTA);
      harness.inject();

      const validation = harness.contextManager.canAcceptTurn({
        estimatedResponseTokens: 4000,
      });
      expect(validation.canProceed).toBe(true);
    });

    it('just above critical boundary blocks turns', () => {
      const harness = CompactionTestHarness.nearThreshold('critical', DELTA);
      harness.inject();

      const validation = harness.contextManager.canAcceptTurn({
        estimatedResponseTokens: 4000,
      });
      expect(validation.canProceed).toBe(false);
    });
  });

  describe('exceeded threshold (95%)', () => {
    it('at exactly 94.9% returns critical', () => {
      const targetTokens = Math.floor(CONTEXT_LIMIT * 0.949);
      const harness = CompactionTestHarness.atTokens(targetTokens);
      harness.inject();

      const snapshot = harness.contextManager.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('critical');
    });

    it('at exactly 95% returns exceeded', () => {
      const harness = CompactionTestHarness.atThreshold('exceeded');
      harness.inject();

      const snapshot = harness.contextManager.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('exceeded');
    });

    it('at 96% returns exceeded', () => {
      const targetTokens = Math.floor(CONTEXT_LIMIT * 0.96);
      const harness = CompactionTestHarness.atTokens(targetTokens);
      harness.inject();

      const snapshot = harness.contextManager.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('exceeded');
    });

    it('canAcceptTurn blocks turns at exceeded level', () => {
      const harness = CompactionTestHarness.atThreshold('exceeded');
      harness.inject();

      const validation = harness.contextManager.canAcceptTurn({
        estimatedResponseTokens: 4000,
      });
      expect(validation.canProceed).toBe(false);
      expect(validation.needsCompaction).toBe(true);
    });

    it('compaction is mandatory at exceeded', () => {
      const harness = CompactionTestHarness.atThreshold('exceeded');
      harness.inject();

      expect(harness.contextManager.shouldCompact()).toBe(true);

      const validation = harness.contextManager.canAcceptTurn({
        estimatedResponseTokens: 4000,
      });
      expect(validation.canProceed).toBe(false);
    });
  });

  describe('threshold level detection accuracy', () => {
    it.each([
      [0.10, 'normal'],
      [0.25, 'normal'],
      [0.49, 'normal'],
      [0.50, 'warning'],
      [0.60, 'warning'],
      [0.69, 'warning'],
      [0.70, 'alert'],
      [0.75, 'alert'],
      [0.84, 'alert'],
      [0.85, 'critical'],
      [0.90, 'critical'],
      [0.94, 'critical'],
      [0.95, 'exceeded'],
      [0.99, 'exceeded'],
    ] as [number, ThresholdLevel][])(
      'at %d%% returns %s',
      (percentage, expectedLevel) => {
        const targetTokens = Math.floor(CONTEXT_LIMIT * percentage);
        const harness = CompactionTestHarness.atTokens(targetTokens);
        harness.inject();

        const snapshot = harness.contextManager.getSnapshot();
        expect(snapshot.thresholdLevel).toBe(expectedLevel);
      }
    );
  });

  describe('getSnapshot breakdown accuracy', () => {
    it('returns accurate breakdown at normal utilization', () => {
      const harness = CompactionTestHarness.atUtilization(30);
      harness.inject();

      const snapshot = harness.contextManager.getSnapshot();

      // Verify breakdown components are non-negative
      expect(snapshot.breakdown.systemPrompt).toBeGreaterThanOrEqual(0);
      expect(snapshot.breakdown.tools).toBeGreaterThanOrEqual(0);
      expect(snapshot.breakdown.rules).toBeGreaterThanOrEqual(0);
      expect(snapshot.breakdown.messages).toBeGreaterThan(0);

      // Verify breakdown sums to currentTokens
      const sum =
        snapshot.breakdown.systemPrompt +
        snapshot.breakdown.tools +
        snapshot.breakdown.rules +
        snapshot.breakdown.messages;
      expect(snapshot.currentTokens).toBe(sum);
    });

    it('returns accurate usagePercent', () => {
      const harness = CompactionTestHarness.atUtilization(50);
      harness.inject();

      const snapshot = harness.contextManager.getSnapshot();

      // Should be approximately 50% (within 5% tolerance due to token estimation)
      expect(snapshot.usagePercent).toBeGreaterThan(0.45);
      expect(snapshot.usagePercent).toBeLessThan(0.55);
    });
  });

  describe('different context limits', () => {
    it('respects smaller context limit (128k for GPT-4o)', () => {
      // Use GPT-4o model which has 128k context limit
      const harness = CompactionTestHarness.atUtilization(85, {
        model: 'gpt-4o',
        contextLimit: 128_000,
      });
      harness.inject();

      const snapshot = harness.contextManager.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('critical');
      expect(snapshot.contextLimit).toBe(128_000);
    });

    it('respects larger context limit (1M for Gemini)', () => {
      // Use Gemini model which has 1M context limit
      const harness = CompactionTestHarness.atUtilization(70, {
        model: 'gemini-1.5-pro',
        contextLimit: 1_000_000,
      });
      harness.inject();

      const snapshot = harness.contextManager.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('alert');
      expect(snapshot.contextLimit).toBe(1_000_000);
    });
  });
});
