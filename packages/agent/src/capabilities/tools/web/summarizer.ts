/**
 * @fileoverview Haiku Summarizer Service
 *
 * Lightweight service for summarizing web content using Claude Haiku.
 * Used by WebFetch tool to analyze fetched content.
 */

import Anthropic from '@anthropic-ai/sdk';
import { createLogger } from '@infrastructure/logging/index.js';
import type { SubagentSpawnResult, SubagentSpawnCallback } from './types.js';
import { SUMMARIZER_MAX_TOKENS, SUMMARIZER_HAIKU_MODEL } from './constants.js';

const logger = createLogger('summarizer');

/**
 * Summarizer configuration
 */
export interface SummarizerConfig {
  /** Anthropic API key */
  apiKey: string;
  /** Maximum tokens for response (default: 1024) */
  maxTokens?: number;
  /** Base URL for API (optional) */
  baseUrl?: string;
}

/**
 * Create a summarizer function that uses Haiku to analyze content
 *
 * @param config - Summarizer configuration
 * @param client - Optional Anthropic client (for testing)
 * @returns Summarizer callback compatible with WebFetch
 */
export function createSummarizer(
  config: SummarizerConfig,
  client?: Anthropic
): SubagentSpawnCallback {
  if (!config.apiKey || config.apiKey.trim() === '') {
    throw new Error('Summarizer requires an Anthropic API key');
  }

  const anthropic = client ?? new Anthropic({
    apiKey: config.apiKey,
    baseURL: config.baseUrl,
  });

  const maxTokens = config.maxTokens ?? SUMMARIZER_MAX_TOKENS;

  return async (params): Promise<SubagentSpawnResult> => {
    const { task, model, timeout: _timeout } = params;
    const sessionId = `summarizer-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;

    logger.debug('Summarizer starting', {
      sessionId,
      model: model || SUMMARIZER_HAIKU_MODEL,
      taskLength: task.length,
    });

    try {
      const response = await anthropic.messages.create({
        model: model || SUMMARIZER_HAIKU_MODEL,
        max_tokens: maxTokens,
        messages: [
          {
            role: 'user',
            content: task,
          },
        ],
      });

      // Extract text from response
      const output = response.content
        .filter((block): block is Anthropic.TextBlock => block.type === 'text')
        .map((block) => block.text)
        .join('\n');

      logger.debug('Summarizer completed', {
        sessionId,
        inputTokens: response.usage.input_tokens,
        outputTokens: response.usage.output_tokens,
        outputLength: output.length,
      });

      return {
        sessionId,
        success: true,
        output,
        tokenUsage: {
          inputTokens: response.usage.input_tokens,
          outputTokens: response.usage.output_tokens,
        },
      };
    } catch (error) {
      const err = error as Error;
      logger.error('Summarizer failed', {
        sessionId,
        error: err.message,
      });

      return {
        sessionId,
        success: false,
        error: err.message,
      };
    }
  };
}

/**
 * Alias for createSummarizer for clarity in different contexts
 */
export const createHaikuSummarizer = createSummarizer;
