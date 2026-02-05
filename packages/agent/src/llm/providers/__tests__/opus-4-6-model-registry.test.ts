/**
 * @fileoverview Tests for Opus 4.6 model registry entries
 *
 * TDD: Written before implementation. Tests both new Opus 4.6 behavior
 * and regression tests ensuring existing 4.5 models are unchanged.
 */

import { describe, it, expect } from 'vitest';
import { CLAUDE_MODELS, DEFAULT_MODEL } from '../anthropic/types.js';
import { ANTHROPIC_MODELS, ANTHROPIC_MODEL_CATEGORIES } from '../models.js';
import { detectProviderFromModel } from '../factory.js';

describe('Opus 4.6 Model Registry', () => {
  // =========================================================================
  // New Opus 4.6 entries
  // =========================================================================

  it('claude-opus-4-6 exists in CLAUDE_MODELS with correct capabilities', () => {
    const model = CLAUDE_MODELS['claude-opus-4-6'];
    expect(model).toBeDefined();
    expect(model.name).toBe('Claude Opus 4.6');
    expect(model.contextWindow).toBe(1_000_000);
    expect(model.maxOutput).toBe(128000);
    expect(model.supportsThinking).toBe(true);
    expect(model.supportsAdaptiveThinking).toBe(true);
    expect(model.supportsEffort).toBe(true);
    expect(model.effortLevels).toEqual(['low', 'medium', 'high', 'max']);
    expect(model.defaultEffortLevel).toBe('high');
    expect(model.requiresThinkingBetaHeaders).toBe(false);
    expect(model.supportsLongContext).toBe(true);
    expect(model.longContextThreshold).toBe(200_000);
    expect(model.betaFeatures).toEqual(['context-1m-2025-08-07']);
  });

  it('claude-opus-4-6 exists in ANTHROPIC_MODELS with correct UI metadata', () => {
    const model = ANTHROPIC_MODELS.find(m => m.id === 'claude-opus-4-6');
    expect(model).toBeDefined();
    expect(model!.family).toBe('Claude 4.6');
    expect(model!.tier).toBe('opus');
    expect(model!.recommended).toBe(true);
    expect(model!.maxOutput).toBe(128000);
    expect(model!.supportsThinking).toBe(true);
    expect(model!.supportsReasoning).toBe(true);
    expect(model!.reasoningLevels).toEqual(['low', 'medium', 'high', 'max']);
    expect(model!.defaultReasoningLevel).toBe('high');
  });

  it('detectProviderFromModel resolves claude-opus-4-6 to anthropic', () => {
    expect(detectProviderFromModel('claude-opus-4-6')).toBe('anthropic');
  });

  it('DEFAULT_MODEL is claude-opus-4-6', () => {
    expect(DEFAULT_MODEL).toBe('claude-opus-4-6');
  });

  it('ANTHROPIC_MODEL_CATEGORIES Latest includes 4.6 models', () => {
    const latest = ANTHROPIC_MODEL_CATEGORIES.find(c => c.name === 'Latest');
    expect(latest).toBeDefined();
    const opus46 = latest!.models.find(m => m.id === 'claude-opus-4-6');
    expect(opus46).toBeDefined();
  });

  // =========================================================================
  // REGRESSION: Verify 4.5 models are UNCHANGED
  // =========================================================================

  it('claude-opus-4-5-20251101 retains original capabilities (regression)', () => {
    const model = CLAUDE_MODELS['claude-opus-4-5-20251101'];
    expect(model).toBeDefined();
    expect(model.maxOutput).toBe(64000); // NOT 128000
    expect(model.supportsAdaptiveThinking).toBe(false);
    expect(model.supportsEffort).toBe(false);
    expect(model.requiresThinkingBetaHeaders).toBe(true);
  });

  it('all existing 4.5 models have supportsAdaptiveThinking: false', () => {
    const models45 = ['claude-opus-4-5-20251101', 'claude-sonnet-4-5-20250929', 'claude-haiku-4-5-20251001'];
    for (const id of models45) {
      expect(CLAUDE_MODELS[id].supportsAdaptiveThinking).toBe(false);
    }
  });

  it('all existing 4.5 models have supportsEffort: false', () => {
    const models45 = ['claude-opus-4-5-20251101', 'claude-sonnet-4-5-20250929', 'claude-haiku-4-5-20251001'];
    for (const id of models45) {
      expect(CLAUDE_MODELS[id].supportsEffort).toBe(false);
    }
  });

  it('all existing 4.5 models have requiresThinkingBetaHeaders: true', () => {
    const models45 = ['claude-opus-4-5-20251101', 'claude-sonnet-4-5-20250929', 'claude-haiku-4-5-20251001'];
    for (const id of models45) {
      expect(CLAUDE_MODELS[id].requiresThinkingBetaHeaders).toBe(true);
    }
  });

  it('opus 4.5 is no longer the recommended opus model', () => {
    const opus45 = ANTHROPIC_MODELS.find(m => m.id === 'claude-opus-4-5-20251101');
    expect(opus45).toBeDefined();
    expect(opus45!.recommended).toBe(false);
  });

  it('opus 4.5 does NOT have supportsReasoning in UI models', () => {
    const opus45 = ANTHROPIC_MODELS.find(m => m.id === 'claude-opus-4-5-20251101');
    expect(opus45).toBeDefined();
    expect(opus45!.supportsReasoning).toBeUndefined();
  });

  it('opus 4.5 has no supportsLongContext or betaFeatures (regression)', () => {
    const model = CLAUDE_MODELS['claude-opus-4-5-20251101'];
    expect(model.supportsLongContext).toBeUndefined();
    expect(model.betaFeatures).toBeUndefined();
  });

  it('claude-opus-4-6 UI model shows 1M context window', () => {
    const model = ANTHROPIC_MODELS.find(m => m.id === 'claude-opus-4-6');
    expect(model).toBeDefined();
    expect(model!.contextWindow).toBe(1_000_000);
  });
});
