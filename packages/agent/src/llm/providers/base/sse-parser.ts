/**
 * @fileoverview Shared SSE Parser
 *
 * Generic Server-Sent Events parser for LLM provider streams.
 * Extracts data lines and yields raw JSON strings for provider-specific processing.
 *
 * SSE Format:
 * - Lines starting with "data: " contain event data
 * - "[DONE]" is a common end marker (OpenAI)
 * - Empty data lines are skipped
 */

import { createLogger } from '@infrastructure/logging/index.js';

const logger = createLogger('sse-parser');

// =============================================================================
// Types
// =============================================================================

export interface SSEParserOptions {
  /**
   * Whether to process remaining buffer content after stream ends.
   * Google streams may have unparsed content in buffer when done=true.
   * Default: true
   */
  processRemainingBuffer?: boolean;
}

// =============================================================================
// SSE Parsing
// =============================================================================

/**
 * Parse SSE stream and yield raw data strings.
 *
 * This generator handles the common SSE parsing logic:
 * - Buffering partial chunks
 * - Extracting "data: " prefixed lines
 * - Filtering out "[DONE]" markers and empty lines
 * - Optionally processing remaining buffer after stream ends
 *
 * Providers consume this to get raw JSON strings, then parse and process
 * according to their specific event formats.
 *
 * @example
 * ```typescript
 * for await (const data of parseSSELines(reader)) {
 *   const event = JSON.parse(data) as ProviderEvent;
 *   yield* processProviderEvent(event, state);
 * }
 * ```
 */
export async function* parseSSELines(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  options: SSEParserOptions = {}
): AsyncGenerator<string> {
  const { processRemainingBuffer = true } = options;
  const decoder = new TextDecoder();
  let buffer = '';

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;

    buffer += decoder.decode(value, { stream: true });

    // Process complete lines
    const lines = buffer.split('\n');
    buffer = lines.pop() || '';

    for (const line of lines) {
      const data = extractDataFromLine(line);
      if (data !== null) {
        yield data;
      }
    }
  }

  // Process any remaining buffer content after stream ends
  if (processRemainingBuffer && buffer.trim()) {
    const remainingLines = buffer.split('\n');
    for (const line of remainingLines) {
      const data = extractDataFromLine(line);
      if (data !== null) {
        yield data;
      }
    }
  }
}

/**
 * Extract data from a single SSE line.
 *
 * @param line - The raw line from the stream
 * @returns The data string (trimmed) if valid, null otherwise
 */
function extractDataFromLine(line: string): string | null {
  // Only process "data: " prefixed lines
  if (!line.startsWith('data: ')) {
    return null;
  }

  const data = line.slice(6).trim(); // Remove "data: " prefix and trim whitespace

  // Skip empty data and [DONE] markers
  if (!data || data === '[DONE]') {
    return null;
  }

  return data;
}

/**
 * Safely parse JSON from SSE data with logging.
 *
 * This is a convenience helper for providers that want consistent
 * JSON parsing with error logging.
 *
 * @param data - The raw JSON string from SSE
 * @param providerName - Name for logging context
 * @returns Parsed object or null if parsing failed
 */
export function parseSSEData<T>(data: string, providerName: string): T | null {
  try {
    return JSON.parse(data) as T;
  } catch (e) {
    logger.warn(`Failed to parse ${providerName} SSE event`, { data, error: e });
    return null;
  }
}
