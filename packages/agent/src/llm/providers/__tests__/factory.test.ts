import { describe, expect, it, vi, beforeEach } from 'vitest';
import {
  detectProviderFromModel,
  getModelCapabilities,
  getDefaultModel,
  createProvider,
  validateModelId,
} from '../factory.js';
import { AnthropicProvider } from '../anthropic/index.js';

// Mock logger to capture warnings
const mockWarn = vi.fn();
vi.mock('@infrastructure/logging/index.js', () => ({
  createLogger: vi.fn().mockReturnValue({
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
    debug: vi.fn(),
  }),
}));

// Mock Anthropic provider to capture stream options
const mockStream = vi.fn();
vi.mock('../anthropic/index.js', async (importOriginal) => {
  const original = await importOriginal<typeof import('../anthropic/index.js')>();
  return {
    ...original,
    AnthropicProvider: vi.fn(),
  };
});

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

  it('resolves claude-opus-4-6 to anthropic', () => {
    expect(detectProviderFromModel('claude-opus-4-6')).toBe('anthropic');
  });

  it('detects gpt-5.3-codex as openai-codex', () => {
    expect(detectProviderFromModel('gpt-5.3-codex')).toBe('openai-codex');
  });

  it('uses deterministic anthropic fallback for unknown models', () => {
    expect(detectProviderFromModel('custom-provider-unknown-model')).toBe('anthropic');
    expect(detectProviderFromModel('   ')).toBe('anthropic');
  });

  it('detects provider by family prefix for unregistered models', () => {
    expect(detectProviderFromModel('claude-future-9000')).toBe('anthropic');
    expect(detectProviderFromModel('gpt-99-turbo')).toBe('openai');
    expect(detectProviderFromModel('gemini-4-ultra')).toBe('google');
  });

  it('detects o-series models as openai-codex via family prefix', () => {
    expect(detectProviderFromModel('o1-preview')).toBe('openai-codex');
    expect(detectProviderFromModel('o3-mini')).toBe('openai-codex');
    expect(detectProviderFromModel('o4-mega')).toBe('openai-codex');
  });

  describe('strict mode', () => {
    it('throws for unknown models when strict=true', () => {
      expect(() => detectProviderFromModel('totally-unknown-model', { strict: true }))
        .toThrow('Unknown model');
    });

    it('still resolves known registry models in strict mode', () => {
      expect(detectProviderFromModel('claude-opus-4-6', { strict: true })).toBe('anthropic');
      expect(detectProviderFromModel('gpt-5.3-codex', { strict: true })).toBe('openai-codex');
      expect(detectProviderFromModel('gemini-2.5-flash', { strict: true })).toBe('google');
    });

    it('resolves family-prefix models in strict mode', () => {
      expect(detectProviderFromModel('claude-future-model', { strict: true })).toBe('anthropic');
      expect(detectProviderFromModel('gpt-99', { strict: true })).toBe('openai');
      expect(detectProviderFromModel('gemini-99', { strict: true })).toBe('google');
    });
  });
});

describe('validateModelId', () => {
  it('returns valid for known registry models', () => {
    const result = validateModelId('claude-opus-4-6');
    expect(result.valid).toBe(true);
    expect(result.provider).toBe('anthropic');
    expect(result.inRegistry).toBe(true);
  });

  it('returns valid but not in registry for family-matched models', () => {
    const result = validateModelId('claude-future-9000');
    expect(result.valid).toBe(true);
    expect(result.provider).toBe('anthropic');
    expect(result.inRegistry).toBe(false);
  });

  it('returns invalid for unrecognized models', () => {
    const result = validateModelId('totally-unknown');
    expect(result.valid).toBe(false);
    expect(result.provider).toBeUndefined();
    expect(result.inRegistry).toBe(false);
  });

  it('returns invalid for empty strings', () => {
    const result = validateModelId('');
    expect(result.valid).toBe(false);
    expect(result.provider).toBeUndefined();
  });
});

describe('getModelCapabilities', () => {
  it('returns supportsEffort=true, maxOutput=128000 for claude-opus-4-6', () => {
    const caps = getModelCapabilities('anthropic', 'claude-opus-4-6');
    expect(caps.supportsEffort).toBe(true);
    expect(caps.maxOutput).toBe(128000);
  });

  it('returns effortLevels and defaultEffortLevel for claude-opus-4-6', () => {
    const caps = getModelCapabilities('anthropic', 'claude-opus-4-6');
    expect(caps.effortLevels).toEqual(['low', 'medium', 'high', 'max']);
    expect(caps.defaultEffortLevel).toBe('high');
  });

  // REGRESSION
  it('returns supportsEffort=false, maxOutput=64000 for claude-opus-4-5 (regression)', () => {
    const caps = getModelCapabilities('anthropic', 'claude-opus-4-5-20251101');
    expect(caps.supportsEffort).toBe(false);
    expect(caps.maxOutput).toBe(64000);
    expect(caps.effortLevels).toBeUndefined();
    expect(caps.defaultEffortLevel).toBeUndefined();
  });

  it('returns supportsEffort=true for gpt-5.3-codex', () => {
    const caps = getModelCapabilities('openai-codex', 'gpt-5.3-codex');
    expect(caps.supportsEffort).toBe(true);
    expect(caps.effortLevels).toEqual(['low', 'medium', 'high', 'xhigh']);
    expect(caps.defaultEffortLevel).toBe('medium');
    expect(caps.maxOutput).toBe(128000);
    expect(caps.contextWindow).toBe(400000);
  });

  it('returns supportsEffort=true for gpt-5.2-codex', () => {
    const caps = getModelCapabilities('openai-codex', 'gpt-5.2-codex');
    expect(caps.supportsEffort).toBe(true);
    expect(caps.effortLevels).toEqual(['low', 'medium', 'high', 'xhigh']);
    expect(caps.defaultEffortLevel).toBe('medium');
    expect(caps.maxOutput).toBe(128000);
    expect(caps.contextWindow).toBe(400000);
  });
});

describe('getDefaultModel', () => {
  it('returns gpt-5.3-codex for openai-codex', () => {
    expect(getDefaultModel('openai-codex')).toBe('gpt-5.3-codex');
  });

  it('returns gpt-5.3-codex for openai', () => {
    expect(getDefaultModel('openai')).toBe('gpt-5.3-codex');
  });
});

describe('createProvider Anthropic effort wiring', () => {
  beforeEach(() => {
    mockStream.mockReturnValue((async function* () {
      // no-op async generator
    })());

    vi.mocked(AnthropicProvider).mockImplementation(() => ({
      model: 'claude-opus-4-6',
      stream: mockStream,
    }) as unknown as AnthropicProvider);
  });

  it('passes effortLevel through to AnthropicProvider.stream()', async () => {
    const provider = createProvider({
      type: 'anthropic',
      model: 'claude-opus-4-6',
      auth: { type: 'api_key', apiKey: 'test-key' },
    });

    const context = {
      messages: [{ role: 'user' as const, content: 'test' }],
      tools: [],
      workingDirectory: '/tmp',
    };

    const gen = provider.stream(context, { effortLevel: 'high' });
    for await (const _ of gen) { /* drain */ }

    expect(mockStream).toHaveBeenCalledWith(
      context,
      expect.objectContaining({ effortLevel: 'high' })
    );
  });

  it('passes effortLevel "max" through for Opus 4.6', async () => {
    mockStream.mockReturnValue((async function* () {
      // fresh generator for second test
    })());

    const provider = createProvider({
      type: 'anthropic',
      model: 'claude-opus-4-6',
      auth: { type: 'api_key', apiKey: 'test-key' },
    });

    const context = {
      messages: [{ role: 'user' as const, content: 'test' }],
      tools: [],
      workingDirectory: '/tmp',
    };

    const gen = provider.stream(context, { effortLevel: 'max' });
    for await (const _ of gen) { /* drain */ }

    expect(mockStream).toHaveBeenCalledWith(
      context,
      expect.objectContaining({ effortLevel: 'max' })
    );
  });
});
