/**
 * @fileoverview Google Token Extraction
 *
 * Extracts token values from Google Gemini API responses.
 *
 * Google reports tokens in usageMetadata on each chunk:
 * - promptTokenCount: Input tokens (full context)
 * - candidatesTokenCount: Output tokens
 */

import { createLogger } from '@infrastructure/logging/index.js';
import { TokenExtractionError, type TokenSource } from '../types.js';

const logger = createLogger('token-extraction-google');

/**
 * Google usage metadata from response chunks.
 */
export interface GoogleUsageMetadata {
  promptTokenCount?: number;
  candidatesTokenCount?: number;
}

/**
 * Metadata required for extraction context.
 */
export interface ExtractionMeta {
  turn: number;
  sessionId: string;
}

/**
 * Extract tokens from Google Gemini API response.
 *
 * @param usageMetadata - Usage metadata from response chunk
 * @param meta - Extraction context metadata
 * @returns TokenSource with extracted values
 * @throws TokenExtractionError if usageMetadata is missing
 *
 * @example
 * const source = extractFromGoogle(
 *   { promptTokenCount: 3000, candidatesTokenCount: 150 },
 *   { turn: 1, sessionId: 'sess_abc' }
 * );
 */
export function extractFromGoogle(
  usageMetadata: GoogleUsageMetadata | undefined | null,
  meta: ExtractionMeta
): TokenSource {
  if (!usageMetadata) {
    throw new TokenExtractionError('Google response missing usageMetadata', {
      provider: 'google',
      turn: meta.turn,
      sessionId: meta.sessionId,
      hasPartialData: false,
    });
  }

  const now = new Date().toISOString();

  const rawInputTokens = usageMetadata.promptTokenCount ?? 0;
  const rawOutputTokens = usageMetadata.candidatesTokenCount ?? 0;
  // Google doesn't report cache tokens
  const rawCacheReadTokens = 0;
  const rawCacheCreationTokens = 0;

  logger.debug('[TOKEN-SOURCE] Google extraction', {
    turn: meta.turn,
    promptTokenCount: rawInputTokens,
    candidatesTokenCount: rawOutputTokens,
    hasUsageMetadata: true,
  });

  return {
    provider: 'google',
    timestamp: now,
    rawInputTokens,
    rawOutputTokens,
    rawCacheReadTokens,
    rawCacheCreationTokens,
    rawCacheCreation5mTokens: 0,
    rawCacheCreation1hTokens: 0,
  };
}
