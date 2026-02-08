/**
 * @fileoverview EmbeddingService Tests
 *
 * Tests the embedding service with mocked transformers.js pipeline.
 * Verifies initialization, embedding, truncation, and error handling.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { EmbeddingService } from '../embedding-service.js';

// Mock the dynamic import of @huggingface/transformers
vi.mock('@huggingface/transformers', () => {
  const mockPipeline = vi.fn();
  return {
    pipeline: mockPipeline,
    env: {
      cacheDir: '',
      allowLocalModels: false,
    },
  };
});

describe('EmbeddingService', () => {
  let service: EmbeddingService;

  beforeEach(() => {
    service = new EmbeddingService({
      dimensions: 4, // Small for testing
    });
  });

  describe('construction', () => {
    it('uses default config values', () => {
      const s = new EmbeddingService();
      expect(s.dimensions).toBe(512);
    });

    it('accepts custom config', () => {
      const s = new EmbeddingService({
        modelId: 'test-model',
        dtype: 'fp32',
        dimensions: 256,
        cacheDir: '/tmp/models',
      });
      expect(s.dimensions).toBe(256);
    });
  });

  describe('initialization', () => {
    it('starts not ready', () => {
      expect(service.isReady()).toBe(false);
    });

    it('initializes successfully with mock pipeline', async () => {
      const { pipeline } = await import('@huggingface/transformers');
      const mockExtract = vi.fn();
      (pipeline as ReturnType<typeof vi.fn>).mockResolvedValue(mockExtract);

      await service.initialize();
      expect(service.isReady()).toBe(true);
    });

    it('handles initialization failure gracefully', async () => {
      const { pipeline } = await import('@huggingface/transformers');
      (pipeline as ReturnType<typeof vi.fn>).mockRejectedValue(new Error('Model not found'));

      await expect(service.initialize()).rejects.toThrow('Model not found');
      expect(service.isReady()).toBe(false);
    });

    it('only initializes once (idempotent)', async () => {
      const { pipeline } = await import('@huggingface/transformers');
      const mockExtract = vi.fn();
      (pipeline as ReturnType<typeof vi.fn>).mockResolvedValue(mockExtract);

      await service.initialize();
      await service.initialize();
      expect(pipeline).toHaveBeenCalledTimes(1);
    });
  });

  describe('embedding', () => {
    it('throws when not initialized', async () => {
      await expect(service.embed(['hello'])).rejects.toThrow('not initialized');
    });

    it('embeds text and truncates to target dimensions', async () => {
      const { pipeline } = await import('@huggingface/transformers');
      // Mock a pipeline that returns a 8-dimensional embedding (will be truncated to 4)
      const mockExtract = vi.fn().mockResolvedValue({
        data: new Float32Array([1, 2, 3, 4, 5, 6, 7, 8]),
        dims: [1, 8],
      });
      (pipeline as ReturnType<typeof vi.fn>).mockResolvedValue(mockExtract);

      await service.initialize();
      const results = await service.embed(['hello']);

      expect(results).toHaveLength(1);
      expect(results[0]).toBeInstanceOf(Float32Array);
      expect(results[0]!.length).toBe(4); // Truncated from 8 to 4
    });

    it('normalizes vectors after truncation', async () => {
      const { pipeline } = await import('@huggingface/transformers');
      const mockExtract = vi.fn().mockResolvedValue({
        data: new Float32Array([3, 4, 0, 0, 99, 99, 99, 99]),
        dims: [1, 8],
      });
      (pipeline as ReturnType<typeof vi.fn>).mockResolvedValue(mockExtract);

      await service.initialize();
      const results = await service.embed(['hello']);
      const vec = results[0]!;

      // L2 norm of [3,4,0,0] = 5, so normalized = [0.6, 0.8, 0, 0]
      expect(vec[0]).toBeCloseTo(0.6, 5);
      expect(vec[1]).toBeCloseTo(0.8, 5);
      expect(vec[2]).toBeCloseTo(0, 5);
      expect(vec[3]).toBeCloseTo(0, 5);
    });

    it('handles batch embedding', async () => {
      const { pipeline } = await import('@huggingface/transformers');
      const mockExtract = vi.fn().mockResolvedValue({
        data: new Float32Array([
          1, 0, 0, 0, 0, 0, 0, 0,  // first embedding
          0, 1, 0, 0, 0, 0, 0, 0,  // second embedding
        ]),
        dims: [2, 8],
      });
      (pipeline as ReturnType<typeof vi.fn>).mockResolvedValue(mockExtract);

      await service.initialize();
      const results = await service.embed(['hello', 'world']);

      expect(results).toHaveLength(2);
      expect(results[0]![0]).toBeCloseTo(1, 5); // Normalized unit vector
      expect(results[1]![1]).toBeCloseTo(1, 5);
    });
  });

  describe('embedSingle', () => {
    it('returns a single Float32Array', async () => {
      const { pipeline } = await import('@huggingface/transformers');
      const mockExtract = vi.fn().mockResolvedValue({
        data: new Float32Array([1, 0, 0, 0, 0, 0, 0, 0]),
        dims: [1, 8],
      });
      (pipeline as ReturnType<typeof vi.fn>).mockResolvedValue(mockExtract);

      await service.initialize();
      const result = await service.embedSingle('hello');

      expect(result).toBeInstanceOf(Float32Array);
      expect(result.length).toBe(4);
    });
  });
});
