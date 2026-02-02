/**
 * @fileoverview Tests for Transcription Module
 *
 * Tests transcription client utilities and model listing.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { listTranscriptionModels } from '../client.js';

// Mock settings
vi.mock('../../settings/index.js', () => ({
  getSettings: vi.fn(() => ({
    server: {
      transcription: {
        enabled: true,
        baseUrl: 'http://localhost:8000',
        timeoutMs: 30000,
        maxBytes: 25_000_000,
        cleanupMode: 'basic',
      },
    },
  })),
}));

// Mock logger
vi.mock('../../logging/index.js', () => ({
  createLogger: vi.fn(() => ({
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
    debug: vi.fn(),
  })),
}));

describe('listTranscriptionModels', () => {
  it('returns available transcription models', async () => {
    const result = await listTranscriptionModels();

    expect(result.models).toBeInstanceOf(Array);
    expect(result.models.length).toBeGreaterThan(0);
    expect(result.defaultModelId).toBeDefined();
  });

  it('returns models with required properties', async () => {
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
    const result = await listTranscriptionModels();

    const parakeetModel = result.models.find(m => m.id.includes('parakeet'));
    expect(parakeetModel).toBeDefined();
  });

  it('sets default model ID to a valid model', async () => {
    const result = await listTranscriptionModels();

    if (result.defaultModelId) {
      const defaultModel = result.models.find(m => m.id === result.defaultModelId);
      expect(defaultModel).toBeDefined();
    }
  });
});

describe('transcribeAudio', () => {
  // These tests would require mocking fetch and the settings
  // The actual network calls are tested in integration tests

  it.todo('throws when transcription is disabled');
  it.todo('throws for empty audio payload');
  it.todo('throws when audio exceeds max bytes');
  it.todo('sends correct form data to sidecar');
  it.todo('handles timeout errors');
  it.todo('handles sidecar errors');
});
