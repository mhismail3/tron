/**
 * @fileoverview Embedding Service
 *
 * In-process embedding via @huggingface/transformers with Qwen3-Embedding-0.6B.
 * Loads ONNX model at server start, provides batch and single embedding methods.
 *
 * Key design decisions:
 * - Matryoshka truncation to 512 dimensions (good quality/size tradeoff)
 * - last_token pooling (required by Qwen3-Embedding)
 * - L2 normalization for cosine similarity via dot product
 * - Model cached at ~/.tron/mods/models/ (not global HF cache)
 */

import { join } from 'path';
import { homedir } from 'os';
import { existsSync } from 'fs';
import { createLogger } from '@infrastructure/logging/index.js';

const logger = createLogger('embeddings');

// =============================================================================
// Types
// =============================================================================

export interface EmbeddingServiceConfig {
  modelId?: string;
  dtype?: string;
  dimensions?: number;
  cacheDir?: string;
}

// =============================================================================
// EmbeddingService
// =============================================================================

export class EmbeddingService {
  private extractor: unknown | null = null;
  private initPromise: Promise<void> | null = null;
  private initFailed = false;
  readonly dimensions: number;
  private readonly modelId: string;
  private readonly dtype: string;
  private readonly cacheDir: string;

  constructor(config?: EmbeddingServiceConfig) {
    this.modelId = config?.modelId ?? 'onnx-community/Qwen3-Embedding-0.6B-ONNX';
    this.dtype = config?.dtype ?? 'q4';
    this.dimensions = config?.dimensions ?? 512;
    // Expand ~ to home directory — settings may contain literal tilde
    const rawDir = config?.cacheDir ?? join(homedir(), '.tron', 'mods', 'models');
    this.cacheDir = rawDir.startsWith('~/') ? join(homedir(), rawDir.slice(2)) : rawDir;
  }

  async initialize(): Promise<void> {
    if (this.initPromise) return this.initPromise;
    this.initPromise = this._init();
    return this.initPromise;
  }

  private async _init(): Promise<void> {
    try {
      // Dynamic import — transformers.js is ESM-only and heavy
      const { pipeline, env } = await import('@huggingface/transformers');

      // Point cache to ~/.tron/mods/models/
      env.cacheDir = this.cacheDir;
      env.allowLocalModels = true;

      logger.info('Loading embedding model', {
        modelId: this.modelId,
        dtype: this.dtype,
        dimensions: this.dimensions,
        cacheDir: this.cacheDir,
      });

      this.extractor = await pipeline('feature-extraction', this.modelId, {
        dtype: this.dtype as 'q4',
      });

      logger.info('Embedding model loaded');
    } catch (error) {
      this.initFailed = true;
      logger.warn('Failed to load embedding model, semantic search disabled', {
        error: (error as Error).message,
      });
      throw error;
    }
  }

  isReady(): boolean {
    return this.extractor !== null && !this.initFailed;
  }

  isModelCached(): boolean {
    // transformers.js stores models as: {cacheDir}/models--{org}--{model}/
    const dirName = `models--${this.modelId.replace('/', '--')}`;
    return existsSync(join(this.cacheDir, dirName));
  }

  async embed(texts: string[]): Promise<Float32Array[]> {
    if (!this.extractor) throw new Error('EmbeddingService not initialized');
    const extract = this.extractor as (texts: string[], opts: Record<string, unknown>) => Promise<unknown>;

    const output = await extract(texts, {
      pooling: 'last_token',
      normalize: true,
    });

    return this.truncateAndExtract(output, texts.length);
  }

  async embedSingle(text: string): Promise<Float32Array> {
    const results = await this.embed([text]);
    return results[0]!;
  }

  /**
   * Truncate embeddings to target dimensions (Matryoshka) and
   * re-normalize after truncation.
   */
  private truncateAndExtract(output: unknown, batchSize: number): Float32Array[] {
    // transformers.js Tensor: { data: Float32Array, dims: number[] }
    const tensor = output as { data: Float32Array; dims: number[] };
    const fullDim = tensor.dims[tensor.dims.length - 1] ?? this.dimensions;
    const data = tensor.data;
    const results: Float32Array[] = [];

    for (let i = 0; i < batchSize; i++) {
      const start = i * fullDim;
      const truncated = new Float32Array(this.dimensions);
      for (let d = 0; d < this.dimensions; d++) {
        truncated[d] = data[start + d] ?? 0;
      }

      // Re-normalize after truncation
      let norm = 0;
      for (let d = 0; d < this.dimensions; d++) {
        norm += (truncated[d] ?? 0) * (truncated[d] ?? 0);
      }
      norm = Math.sqrt(norm);
      if (norm > 0) {
        for (let d = 0; d < this.dimensions; d++) {
          truncated[d] = (truncated[d] ?? 0) / norm;
        }
      }

      results.push(truncated);
    }

    return results;
  }
}
