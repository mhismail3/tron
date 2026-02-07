/**
 * @fileoverview Tests for CompactionTrigger
 *
 * Tests smart compaction timing based on token ratio,
 * progress signals, and turn count.
 */
import { describe, it, expect, beforeEach } from 'vitest';
import { CompactionTrigger } from '../compaction-trigger.js';

// =============================================================================
// Tests
// =============================================================================

describe('CompactionTrigger', () => {
  let trigger: CompactionTrigger;

  beforeEach(() => {
    trigger = new CompactionTrigger();
  });

  describe('token threshold', () => {
    it('should trigger at >= 0.70 ratio', () => {
      const result = trigger.shouldCompact({
        currentTokenRatio: 0.70,
        recentEventTypes: [],
        recentToolCalls: [],
      });

      expect(result.compact).toBe(true);
      expect(result.reason).toContain('token');
    });

    it('should trigger at > 0.70 ratio', () => {
      const result = trigger.shouldCompact({
        currentTokenRatio: 0.85,
        recentEventTypes: [],
        recentToolCalls: [],
      });

      expect(result.compact).toBe(true);
    });

    it('should not trigger below 0.70 without other signals', () => {
      const result = trigger.shouldCompact({
        currentTokenRatio: 0.30,
        recentEventTypes: [],
        recentToolCalls: [],
      });

      expect(result.compact).toBe(false);
    });
  });

  describe('progress signals', () => {
    it('should trigger on worktree.commit event', () => {
      const result = trigger.shouldCompact({
        currentTokenRatio: 0.40,
        recentEventTypes: ['worktree.commit'],
        recentToolCalls: [],
      });

      expect(result.compact).toBe(true);
      expect(result.reason).toContain('commit');
    });

    it('should trigger on git push tool call', () => {
      const result = trigger.shouldCompact({
        currentTokenRatio: 0.40,
        recentEventTypes: [],
        recentToolCalls: ['git push origin main'],
      });

      expect(result.compact).toBe(true);
      expect(result.reason).toContain('push');
    });

    it('should trigger on gh pr create tool call', () => {
      const result = trigger.shouldCompact({
        currentTokenRatio: 0.40,
        recentEventTypes: [],
        recentToolCalls: ['gh pr create --title "Fix bug"'],
      });

      expect(result.compact).toBe(true);
      expect(result.reason).toContain('progress');
    });

    it('should not trigger on non-progress tool calls', () => {
      const result = trigger.shouldCompact({
        currentTokenRatio: 0.40,
        recentEventTypes: [],
        recentToolCalls: ['ls -la', 'cat file.txt'],
      });

      expect(result.compact).toBe(false);
    });
  });

  describe('turn-count fallback', () => {
    it('should trigger after 8 turns without compaction', () => {
      // Simulate 8 turns without triggering
      for (let i = 0; i < 7; i++) {
        trigger.shouldCompact({
          currentTokenRatio: 0.30,
          recentEventTypes: [],
          recentToolCalls: [],
        });
      }

      const result = trigger.shouldCompact({
        currentTokenRatio: 0.30,
        recentEventTypes: [],
        recentToolCalls: [],
      });

      expect(result.compact).toBe(true);
      expect(result.reason).toContain('turn');
    });

    it('should not trigger before 8 turns', () => {
      for (let i = 0; i < 7; i++) {
        const result = trigger.shouldCompact({
          currentTokenRatio: 0.30,
          recentEventTypes: [],
          recentToolCalls: [],
        });

        expect(result.compact).toBe(false);
      }
    });

    it('should lower fallback to 5 turns in alert zone (>= 0.50)', () => {
      for (let i = 0; i < 4; i++) {
        trigger.shouldCompact({
          currentTokenRatio: 0.55,
          recentEventTypes: [],
          recentToolCalls: [],
        });
      }

      const result = trigger.shouldCompact({
        currentTokenRatio: 0.55,
        recentEventTypes: [],
        recentToolCalls: [],
      });

      expect(result.compact).toBe(true);
      expect(result.reason).toContain('turn');
    });
  });

  describe('forceAlways', () => {
    it('should trigger immediately when forceAlways is enabled', () => {
      trigger.setForceAlways(true);

      const result = trigger.shouldCompact({
        currentTokenRatio: 0.10,
        recentEventTypes: [],
        recentToolCalls: [],
      });

      expect(result.compact).toBe(true);
      expect(result.reason).toContain('force-always');
    });

    it('should restore normal behavior when forceAlways is disabled', () => {
      trigger.setForceAlways(true);
      trigger.setForceAlways(false);

      const result = trigger.shouldCompact({
        currentTokenRatio: 0.10,
        recentEventTypes: [],
        recentToolCalls: [],
      });

      expect(result.compact).toBe(false);
    });

    it('should take precedence over token threshold check', () => {
      trigger.setForceAlways(true);

      // Even at 0% usage, forceAlways triggers
      const result = trigger.shouldCompact({
        currentTokenRatio: 0.0,
        recentEventTypes: [],
        recentToolCalls: [],
      });

      expect(result.compact).toBe(true);
      expect(result.reason).toContain('force-always');
    });
  });

  describe('configurable thresholds', () => {
    it('should accept custom token threshold', () => {
      const custom = new CompactionTrigger({ triggerTokenThreshold: 0.90 });

      // Should NOT trigger at 0.80 (below custom threshold)
      const result1 = custom.shouldCompact({
        currentTokenRatio: 0.80,
        recentEventTypes: [],
        recentToolCalls: [],
      });
      expect(result1.compact).toBe(false);

      // Should trigger at 0.90 (at custom threshold)
      const result2 = custom.shouldCompact({
        currentTokenRatio: 0.90,
        recentEventTypes: [],
        recentToolCalls: [],
      });
      expect(result2.compact).toBe(true);
    });

    it('should accept custom alert zone threshold', () => {
      const custom = new CompactionTrigger({
        alertZoneThreshold: 0.40,
        alertTurnFallback: 3,
        defaultTurnFallback: 10,
      });

      // At 0.45 ratio (above custom alert zone 0.40), fallback should be 3
      for (let i = 0; i < 2; i++) {
        custom.shouldCompact({
          currentTokenRatio: 0.45,
          recentEventTypes: [],
          recentToolCalls: [],
        });
      }

      const result = custom.shouldCompact({
        currentTokenRatio: 0.45,
        recentEventTypes: [],
        recentToolCalls: [],
      });
      expect(result.compact).toBe(true);
      expect(result.reason).toContain('turn');
    });

    it('should accept custom turn fallback values', () => {
      const custom = new CompactionTrigger({
        defaultTurnFallback: 3,
      });

      // Should trigger after 3 turns
      for (let i = 0; i < 2; i++) {
        custom.shouldCompact({
          currentTokenRatio: 0.20,
          recentEventTypes: [],
          recentToolCalls: [],
        });
      }

      const result = custom.shouldCompact({
        currentTokenRatio: 0.20,
        recentEventTypes: [],
        recentToolCalls: [],
      });
      expect(result.compact).toBe(true);
    });

    it('should use defaults when no config provided', () => {
      const defaultTrigger = new CompactionTrigger();

      // Default token threshold is 0.70
      const result = defaultTrigger.shouldCompact({
        currentTokenRatio: 0.69,
        recentEventTypes: [],
        recentToolCalls: [],
      });
      expect(result.compact).toBe(false);

      const result2 = defaultTrigger.shouldCompact({
        currentTokenRatio: 0.70,
        recentEventTypes: [],
        recentToolCalls: [],
      });
      expect(result2.compact).toBe(true);
    });
  });

  describe('reset', () => {
    it('should reset turn counter after compaction trigger', () => {
      // Trigger via commit
      const result1 = trigger.shouldCompact({
        currentTokenRatio: 0.40,
        recentEventTypes: ['worktree.commit'],
        recentToolCalls: [],
      });
      expect(result1.compact).toBe(true);

      // Reset
      trigger.reset();

      // Should not trigger immediately after reset
      const result2 = trigger.shouldCompact({
        currentTokenRatio: 0.30,
        recentEventTypes: [],
        recentToolCalls: [],
      });
      expect(result2.compact).toBe(false);
    });
  });
});
