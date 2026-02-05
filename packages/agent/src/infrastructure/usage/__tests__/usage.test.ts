/**
 * @fileoverview Tests for Token Usage and Cost Tracking
 *
 * Tests pricing calculations, cost formatting, and session usage tracking.
 */

import { describe, it, expect } from 'vitest';
import {
  getPricingTier,
  calculateCost,
  formatCost,
  formatTokens,
  createSessionUsage,
  addRequestUsage,
  getUsageDelta,
  getContextLimit,
  getContextPercentage,
} from '../index.js';

describe('getPricingTier', () => {
  it('returns exact model pricing for Claude models', () => {
    const tier = getPricingTier('claude-opus-4-5-20251101');
    expect(tier.inputPerMillion).toBe(5);
    expect(tier.outputPerMillion).toBe(25);
  });

  it('returns exact model pricing for OpenAI models', () => {
    const tier = getPricingTier('gpt-4o');
    expect(tier.inputPerMillion).toBe(2.5);
    expect(tier.outputPerMillion).toBe(10);
  });

  it('returns exact model pricing for Google models', () => {
    const tier = getPricingTier('gemini-2.5-pro');
    expect(tier.inputPerMillion).toBe(1.25);
    expect(tier.outputPerMillion).toBe(5);
  });

  it('matches model family patterns for opus', () => {
    const tier = getPricingTier('some-custom-opus-model');
    expect(tier.inputPerMillion).toBe(15); // opus-4 pricing
  });

  it('matches model family patterns for sonnet-4.5', () => {
    const tier = getPricingTier('claude-sonnet-4.5-latest');
    expect(tier.inputPerMillion).toBe(3); // sonnet-4.5 pricing
  });

  it('matches model family patterns for haiku', () => {
    const tier = getPricingTier('claude-haiku-something');
    expect(tier.inputPerMillion).toBe(0.25); // haiku-3 pricing
  });

  it('matches gpt-4o-mini specifically before gpt-4o', () => {
    const tier = getPricingTier('gpt-4o-mini-2024-07-18');
    expect(tier.inputPerMillion).toBe(0.15); // mini pricing, not gpt-4o
  });

  it('defaults to sonnet pricing for unknown models', () => {
    const tier = getPricingTier('unknown-model-xyz');
    // Defaults to claude-sonnet-4-20250514 pricing
    expect(tier.inputPerMillion).toBe(3);
    expect(tier.outputPerMillion).toBe(15);
  });
});

describe('calculateCost', () => {
  it('calculates basic input/output cost', () => {
    const cost = calculateCost('claude-sonnet-4-20250514', {
      inputTokens: 1_000_000,
      outputTokens: 100_000,
    });

    expect(cost.inputCost).toBe(3); // 1M tokens at $3/M
    expect(cost.outputCost).toBe(1.5); // 100K tokens at $15/M
    expect(cost.total).toBe(4.5);
    expect(cost.currency).toBe('USD');
  });

  it('applies cache read discount', () => {
    const cost = calculateCost('claude-sonnet-4-20250514', {
      inputTokens: 1_000_000,
      outputTokens: 0,
      cacheReadTokens: 800_000, // 80% cache hit
    });

    // Base: 200K tokens at $3/M = $0.60
    // Cache read: 800K at $3/M * 0.1 = $0.24
    expect(cost.inputCost).toBeCloseTo(0.84, 2);
  });

  it('applies cache write multiplier', () => {
    const cost = calculateCost('claude-sonnet-4-20250514', {
      inputTokens: 1_000_000,
      outputTokens: 0,
      cacheCreationTokens: 500_000,
    });

    // Base: 500K tokens at $3/M = $1.50
    // Cache write: 500K at $3/M * 1.25 = $1.875
    expect(cost.inputCost).toBeCloseTo(3.375, 2);
  });

  it('handles zero tokens', () => {
    const cost = calculateCost('claude-sonnet-4-20250514', {
      inputTokens: 0,
      outputTokens: 0,
    });

    expect(cost.total).toBe(0);
  });
});

describe('formatCost', () => {
  it('formats cost object', () => {
    expect(formatCost({ inputCost: 1, outputCost: 2, total: 3, currency: 'USD' })).toBe('$3.00');
  });

  it('formats cost number', () => {
    expect(formatCost(5.5)).toBe('$5.50');
  });

  it('shows 3 decimals for tiny costs', () => {
    expect(formatCost(0.005)).toBe('$0.005');
  });

  it('shows $0.00 for very small costs', () => {
    expect(formatCost(0.0001)).toBe('$0.00');
  });
});

describe('formatTokens', () => {
  it('formats millions', () => {
    expect(formatTokens(1_500_000)).toBe('1.5M');
  });

  it('formats thousands', () => {
    expect(formatTokens(50_000)).toBe('50K');
  });

  it('formats small numbers as-is', () => {
    expect(formatTokens(500)).toBe('500');
  });
});

describe('SessionUsage tracking', () => {
  it('creates empty session usage', () => {
    const session = createSessionUsage();

    expect(session.requestCount).toBe(0);
    expect(session.totalInputTokens).toBe(0);
    expect(session.totalOutputTokens).toBe(0);
    expect(session.totalCost.total).toBe(0);
    expect(session.requests).toHaveLength(0);
  });

  it('accumulates request usage', () => {
    let session = createSessionUsage();

    session = addRequestUsage(session, 'claude-sonnet-4-20250514', {
      inputTokens: 1000,
      outputTokens: 500,
    });

    expect(session.requestCount).toBe(1);
    expect(session.totalInputTokens).toBe(1000);
    expect(session.totalOutputTokens).toBe(500);
    expect(session.requests).toHaveLength(1);

    session = addRequestUsage(session, 'claude-sonnet-4-20250514', {
      inputTokens: 2000,
      outputTokens: 1000,
    });

    expect(session.requestCount).toBe(2);
    expect(session.totalInputTokens).toBe(3000);
    expect(session.totalOutputTokens).toBe(1500);
    expect(session.requests).toHaveLength(2);
  });

  it('tracks cache tokens', () => {
    let session = createSessionUsage();

    session = addRequestUsage(session, 'claude-sonnet-4-20250514', {
      inputTokens: 10000,
      outputTokens: 1000,
      cacheCreationTokens: 5000,
      cacheReadTokens: 3000,
    });

    expect(session.totalCacheCreationTokens).toBe(5000);
    expect(session.totalCacheReadTokens).toBe(3000);
  });
});

describe('getUsageDelta', () => {
  it('calculates delta between usage snapshots', () => {
    const previous = {
      inputTokens: 1000,
      outputTokens: 500,
      cacheCreationTokens: 100,
      cacheReadTokens: 200,
    };

    const current = {
      inputTokens: 3000,
      outputTokens: 1500,
      cacheCreationTokens: 300,
      cacheReadTokens: 500,
    };

    const delta = getUsageDelta(previous, current);

    expect(delta.inputTokens).toBe(2000);
    expect(delta.outputTokens).toBe(1000);
    expect(delta.cacheCreationTokens).toBe(200);
    expect(delta.cacheReadTokens).toBe(300);
  });

  it('handles missing cache tokens', () => {
    const previous = { inputTokens: 1000, outputTokens: 500 };
    const current = { inputTokens: 2000, outputTokens: 1000 };

    const delta = getUsageDelta(previous, current);

    expect(delta.cacheCreationTokens).toBe(0);
    expect(delta.cacheReadTokens).toBe(0);
  });
});

describe('Long Context Pricing', () => {
  it('uses standard rates when input <= 200K for Opus 4.6', () => {
    const cost = calculateCost('claude-opus-4-6', {
      inputTokens: 200_000,
      outputTokens: 10_000,
    });
    // Standard: 200K input at $5/M = $1.00, 10K output at $25/M = $0.25
    expect(cost.inputCost).toBeCloseTo(1.0, 4);
    expect(cost.outputCost).toBeCloseTo(0.25, 4);
    expect(cost.total).toBeCloseTo(1.25, 4);
  });

  it('applies 2x input and 1.5x output when input > 200K for Opus 4.6', () => {
    const cost = calculateCost('claude-opus-4-6', {
      inputTokens: 500_000,
      outputTokens: 10_000,
    });
    // Long context: 500K input at $10/M = $5.00, 10K output at $37.50/M = $0.375
    expect(cost.inputCost).toBeCloseTo(5.0, 4);
    expect(cost.outputCost).toBeCloseTo(0.375, 4);
    expect(cost.total).toBeCloseTo(5.375, 4);
  });

  it('boundary: exactly 200K uses standard pricing', () => {
    const cost = calculateCost('claude-opus-4-6', {
      inputTokens: 200_000,
      outputTokens: 1_000,
    });
    // Standard: $5/M input, $25/M output
    const expectedInput = (200_000 / 1_000_000) * 5;
    const expectedOutput = (1_000 / 1_000_000) * 25;
    expect(cost.inputCost).toBeCloseTo(expectedInput, 4);
    expect(cost.outputCost).toBeCloseTo(expectedOutput, 4);
  });

  it('cache multipliers stack on top of long context multipliers', () => {
    const cost = calculateCost('claude-opus-4-6', {
      inputTokens: 500_000,
      outputTokens: 0,
      cacheCreationTokens: 200_000,
      cacheReadTokens: 100_000,
    });
    // Long context rate: $10/M (2x of $5/M)
    // Base input: (500K - 100K - 200K) = 200K at $10/M = $2.00
    // Cache write: 200K at $10/M * 1.25 = $2.50
    // Cache read: 100K at $10/M * 0.1 = $0.10
    expect(cost.inputCost).toBeCloseTo(4.6, 4);
    expect(cost.outputCost).toBeCloseTo(0, 4);
  });

  it('Opus 4.5 never gets long context pricing (regression)', () => {
    const cost = calculateCost('claude-opus-4-5-20251101', {
      inputTokens: 500_000,
      outputTokens: 10_000,
    });
    // Standard Opus 4.5: 500K at $5/M = $2.50, 10K at $25/M = $0.25
    expect(cost.inputCost).toBeCloseTo(2.5, 4);
    expect(cost.outputCost).toBeCloseTo(0.25, 4);
  });

  it('getPricingTier matches opus-4-6 pattern', () => {
    const tier = getPricingTier('claude-opus-4-6');
    expect(tier.inputPerMillion).toBe(5);
    expect(tier.longContextThreshold).toBe(200_000);
    expect(tier.longContextInputMultiplier).toBe(2.0);
    expect(tier.longContextOutputMultiplier).toBe(1.5);
  });

  it('getPricingTier matches opus-4.6 fuzzy pattern', () => {
    const tier = getPricingTier('some-opus-4.6-variant');
    expect(tier.longContextThreshold).toBe(200_000);
  });
});

describe('getContextLimit', () => {
  it('returns 1M for claude-opus-4-6', () => {
    expect(getContextLimit('claude-opus-4-6')).toBe(1_000_000);
  });

  it('returns exact limit for known models', () => {
    expect(getContextLimit('claude-opus-4-5-20251101')).toBe(200_000);
    expect(getContextLimit('gpt-4o')).toBe(128_000);
    expect(getContextLimit('gemini-2.5-pro')).toBe(2_097_152);
  });

  it('returns default for Gemini family', () => {
    expect(getContextLimit('gemini-unknown')).toBe(1_000_000);
  });

  it('returns default for GPT family', () => {
    expect(getContextLimit('gpt-something')).toBe(128_000);
  });

  it('returns Claude default for unknown models', () => {
    expect(getContextLimit('unknown-model')).toBe(200_000);
  });
});

describe('getContextPercentage', () => {
  it('calculates percentage correctly', () => {
    // 100K tokens with 200K limit = 50%
    expect(getContextPercentage(100_000, 'claude-sonnet-4-20250514')).toBe(50);
  });

  it('rounds to nearest integer', () => {
    // 33K with 200K = 16.5% -> 17%
    expect(getContextPercentage(33_000, 'claude-sonnet-4-20250514')).toBe(17);
  });

  it('handles zero tokens', () => {
    expect(getContextPercentage(0, 'claude-sonnet-4-20250514')).toBe(0);
  });

  it('can exceed 100% when over limit', () => {
    expect(getContextPercentage(300_000, 'claude-sonnet-4-20250514')).toBe(150);
  });
});
