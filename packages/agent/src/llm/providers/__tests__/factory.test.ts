import { describe, expect, it } from 'vitest';
import { detectProviderFromModel } from '../factory.js';

describe('detectProviderFromModel', () => {
  it('prefers explicit provider prefixes', () => {
    expect(detectProviderFromModel('google/gpt-like-custom')).toBe('google');
    expect(detectProviderFromModel('anthropic/gpt-like-custom')).toBe('anthropic');
    expect(detectProviderFromModel('openai/gpt-5')).toBe('openai');
    expect(detectProviderFromModel('openai-codex/gpt-5.2-codex')).toBe('openai-codex');
  });

  it('resolves openai prefix to codex when model is codex/o-series', () => {
    expect(detectProviderFromModel('openai/gpt-5.2-codex')).toBe('openai-codex');
    expect(detectProviderFromModel('openai/o3-mini')).toBe('openai-codex');
  });

  it('matches known registry models deterministically', () => {
    expect(detectProviderFromModel('claude-sonnet-4-20250514')).toBe('anthropic');
    expect(detectProviderFromModel('gemini-2.5-flash')).toBe('google');
    expect(detectProviderFromModel('GPT-4.1')).toBe('openai');
  });

  it('uses deterministic anthropic fallback for unknown models', () => {
    expect(detectProviderFromModel('custom-provider-unknown-model')).toBe('anthropic');
    expect(detectProviderFromModel('   ')).toBe('anthropic');
  });
});
