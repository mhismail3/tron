import { describe, expect, it, vi, beforeEach } from 'vitest';
import { detectProviderFromModel, getModelCapabilities, createProvider } from '../factory.js';
import { AnthropicProvider } from '../anthropic/index.js';

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

  it('uses deterministic anthropic fallback for unknown models', () => {
    expect(detectProviderFromModel('custom-provider-unknown-model')).toBe('anthropic');
    expect(detectProviderFromModel('   ')).toBe('anthropic');
  });
});

describe('getModelCapabilities', () => {
  it('returns supportsEffort=true, maxOutput=128000, contextWindow=1M for claude-opus-4-6', () => {
    const caps = getModelCapabilities('anthropic', 'claude-opus-4-6');
    expect(caps.supportsEffort).toBe(true);
    expect(caps.maxOutput).toBe(128000);
    expect(caps.contextWindow).toBe(1_000_000);
  });

  it('returns effortLevels and defaultEffortLevel for claude-opus-4-6', () => {
    const caps = getModelCapabilities('anthropic', 'claude-opus-4-6');
    expect(caps.effortLevels).toEqual(['low', 'medium', 'high', 'max']);
    expect(caps.defaultEffortLevel).toBe('high');
  });

  // REGRESSION
  it('returns supportsEffort=false, maxOutput=64000, contextWindow=200K for claude-opus-4-5 (regression)', () => {
    const caps = getModelCapabilities('anthropic', 'claude-opus-4-5-20251101');
    expect(caps.supportsEffort).toBe(false);
    expect(caps.maxOutput).toBe(64000);
    expect(caps.contextWindow).toBe(200_000);
    expect(caps.effortLevels).toBeUndefined();
    expect(caps.defaultEffortLevel).toBeUndefined();
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
