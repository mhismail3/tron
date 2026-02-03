/**
 * @fileoverview Tests for Transcription Module
 *
 * Tests transcription client utilities and model listing.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// Settings mock that can be modified per test
let mockSettings = {
  server: {
    transcription: {
      enabled: true,
      baseUrl: 'http://localhost:8000',
      timeoutMs: 30000,
      maxBytes: 25_000_000,
      cleanupMode: 'basic',
    },
  },
};

// Mock settings
vi.mock('@infrastructure/settings/index.js', () => ({
  getSettings: vi.fn(() => mockSettings),
}));

// Mock logger
vi.mock('@infrastructure/logging/index.js', () => ({
  createLogger: vi.fn(() => ({
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
    debug: vi.fn(),
  })),
}));

describe('listTranscriptionModels', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockSettings = {
      server: {
        transcription: {
          enabled: true,
          baseUrl: 'http://localhost:8000',
          timeoutMs: 30000,
          maxBytes: 25_000_000,
          cleanupMode: 'basic',
        },
      },
    };
  });

  it('returns available transcription models', async () => {
    const { listTranscriptionModels } = await import('../client.js');
    const result = await listTranscriptionModels();

    expect(result.models).toBeInstanceOf(Array);
    expect(result.models.length).toBeGreaterThan(0);
    expect(result.defaultModelId).toBeDefined();
  });

  it('returns models with required properties', async () => {
    const { listTranscriptionModels } = await import('../client.js');
    const result = await listTranscriptionModels();

    for (const model of result.models) {
      expect(model.id).toBeDefined();
      expect(typeof model.id).toBe('string');
      expect(model.label).toBeDefined();
      expect(typeof model.label).toBe('string');
      expect(model.description).toBeDefined();
      expect(typeof model.description).toBe('string');
    }
  });

  it('includes parakeet model', async () => {
    const { listTranscriptionModels } = await import('../client.js');
    const result = await listTranscriptionModels();

    const parakeetModel = result.models.find(m => m.id.includes('parakeet'));
    expect(parakeetModel).toBeDefined();
  });

  it('sets default model ID to a valid model', async () => {
    const { listTranscriptionModels } = await import('../client.js');
    const result = await listTranscriptionModels();

    if (result.defaultModelId) {
      const defaultModel = result.models.find(m => m.id === result.defaultModelId);
      expect(defaultModel).toBeDefined();
    }
  });
});

describe('transcribeAudio', () => {
  let originalFetch: typeof globalThis.fetch;

  beforeEach(() => {
    vi.resetModules();
    vi.clearAllMocks();
    originalFetch = globalThis.fetch;
    mockSettings = {
      server: {
        transcription: {
          enabled: true,
          baseUrl: 'http://localhost:8000',
          timeoutMs: 30000,
          maxBytes: 25_000_000,
          cleanupMode: 'basic',
        },
      },
    };
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  it('throws when transcription is disabled', async () => {
    mockSettings.server.transcription.enabled = false;

    vi.resetModules();
    const { transcribeAudio } = await import('../client.js');

    await expect(
      transcribeAudio({
        audioBase64: Buffer.from('test audio').toString('base64'),
      })
    ).rejects.toThrow('Transcription is disabled');
  });

  it('throws for empty audio payload', async () => {
    vi.resetModules();
    const { transcribeAudio } = await import('../client.js');

    await expect(
      transcribeAudio({
        audioBase64: '',
      })
    ).rejects.toThrow('Audio payload is empty');
  });

  it('throws when audio exceeds max bytes', async () => {
    mockSettings.server.transcription.maxBytes = 100;

    vi.resetModules();
    const { transcribeAudio } = await import('../client.js');

    // Create base64 that decodes to more than 100 bytes
    const largeData = Buffer.alloc(200).fill(65).toString('base64');

    await expect(
      transcribeAudio({
        audioBase64: largeData,
      })
    ).rejects.toThrow('Audio payload exceeds 100 bytes');
  });

  it('sends correct form data to sidecar', async () => {
    let capturedBody: FormData | null = null;
    let capturedUrl: string = '';

    globalThis.fetch = vi.fn().mockImplementation(async (url: string, init: RequestInit) => {
      capturedUrl = url;
      capturedBody = init.body as FormData;
      return {
        ok: true,
        json: async () => ({
          text: 'transcribed text',
          raw_text: 'raw text',
          language: 'en',
          duration_s: 5.0,
          processing_time_ms: 100,
          model: 'parakeet',
          device: 'mlx',
          compute_type: 'mlx',
          cleanup_mode: 'basic',
        }),
      };
    });

    vi.resetModules();
    const { transcribeAudio } = await import('../client.js');

    const result = await transcribeAudio({
      audioBase64: Buffer.from('test audio').toString('base64'),
      language: 'en',
      task: 'transcribe',
      prompt: 'test prompt',
      cleanupMode: 'basic',
    });

    expect(capturedUrl).toBe('http://localhost:8000/transcribe');
    expect(capturedBody).toBeInstanceOf(FormData);
    expect(result.text).toBe('transcribed text');
    expect(result.language).toBe('en');
    expect(result.durationSeconds).toBe(5.0);
  });

  it('handles timeout errors', async () => {
    const abortError = new Error('Aborted');
    abortError.name = 'AbortError';

    globalThis.fetch = vi.fn().mockRejectedValue(abortError);

    vi.resetModules();
    const { transcribeAudio } = await import('../client.js');

    await expect(
      transcribeAudio({
        audioBase64: Buffer.from('test audio').toString('base64'),
      })
    ).rejects.toThrow('Transcription request timed out');
  });

  it('handles sidecar errors', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: false,
      status: 500,
      text: async () => 'Internal server error',
    });

    vi.resetModules();
    const { transcribeAudio } = await import('../client.js');

    await expect(
      transcribeAudio({
        audioBase64: Buffer.from('test audio').toString('base64'),
      })
    ).rejects.toThrow('Sidecar error (500): Internal server error');
  });

  it('handles network errors', async () => {
    globalThis.fetch = vi.fn().mockRejectedValue(new Error('Network error'));

    vi.resetModules();
    const { transcribeAudio } = await import('../client.js');

    await expect(
      transcribeAudio({
        audioBase64: Buffer.from('test audio').toString('base64'),
      })
    ).rejects.toThrow('Network error');
  });

  it('normalizes base64 with data URL prefix', async () => {
    let capturedBody: FormData | null = null;

    globalThis.fetch = vi.fn().mockImplementation(async (_url: string, init: RequestInit) => {
      capturedBody = init.body as FormData;
      return {
        ok: true,
        json: async () => ({
          text: 'transcribed',
          raw_text: 'raw',
          language: 'en',
        }),
      };
    });

    vi.resetModules();
    const { transcribeAudio } = await import('../client.js');

    const rawBase64 = Buffer.from('test audio').toString('base64');
    await transcribeAudio({
      audioBase64: `data:audio/m4a;base64,${rawBase64}`,
    });

    // The audio should have been extracted correctly
    expect(capturedBody).toBeInstanceOf(FormData);
  });

  it('uses quality-based model selection', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        text: 'transcribed',
        raw_text: 'raw',
        language: 'en',
      }),
    });

    vi.resetModules();
    const { transcribeAudio } = await import('../client.js');

    // Should not throw with quality parameter
    await transcribeAudio({
      audioBase64: Buffer.from('test').toString('base64'),
      transcriptionQuality: 'faster',
    });

    expect(globalThis.fetch).toHaveBeenCalled();
  });

  it('uses explicit model ID when provided', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        text: 'transcribed',
        raw_text: 'raw',
        language: 'en',
      }),
    });

    vi.resetModules();
    const { transcribeAudio } = await import('../client.js');

    await transcribeAudio({
      audioBase64: Buffer.from('test').toString('base64'),
      transcriptionModelId: 'parakeet-tdt-0.6b-v3',
    });

    expect(globalThis.fetch).toHaveBeenCalled();
  });
});

describe('getDefaultTranscriptionSettings', () => {
  beforeEach(() => {
    vi.resetModules();
    mockSettings = {
      server: {
        transcription: {
          enabled: true,
          baseUrl: 'http://localhost:9999',
          timeoutMs: 60000,
          maxBytes: 50_000_000,
          cleanupMode: 'llm',
        },
      },
    };
  });

  it('returns transcription settings from global settings', async () => {
    const { getDefaultTranscriptionSettings } = await import('../client.js');
    const settings = getDefaultTranscriptionSettings();

    expect(settings.enabled).toBe(true);
    expect(settings.baseUrl).toBe('http://localhost:9999');
    expect(settings.timeoutMs).toBe(60000);
    expect(settings.maxBytes).toBe(50_000_000);
    expect(settings.cleanupMode).toBe('llm');
  });
});
