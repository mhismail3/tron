/**
 * @fileoverview Tool Call Parsing Utilities
 *
 * Provides consistent JSON parsing for tool call arguments across providers.
 * Handles malformed JSON gracefully with logging.
 */

import { createLogger } from '@infrastructure/logging/index.js';

const logger = createLogger('tool-parsing');

// =============================================================================
// Types
// =============================================================================

export interface ToolCallContext {
  /** Tool call ID for logging context */
  toolCallId?: string;
  /** Tool name for logging context */
  toolName?: string;
  /** Provider name for logging context */
  provider?: string;
}

// =============================================================================
// Tool Call Parsing
// =============================================================================

/**
 * Safely parse tool call arguments JSON.
 *
 * This utility provides consistent parsing behavior across all providers:
 * - Handles empty/null arguments by returning empty object
 * - Logs warnings for malformed JSON
 * - Returns empty object on parse failure (fail-open)
 *
 * @param args - Raw JSON string of tool arguments
 * @param context - Optional context for logging
 * @returns Parsed arguments object, or empty object on failure
 *
 * @example
 * ```typescript
 * const args = parseToolCallArguments('{"file": "test.ts"}', {
 *   toolCallId: 'call_123',
 *   toolName: 'read_file',
 *   provider: 'openai',
 * });
 * ```
 */
export function parseToolCallArguments(
  args: string | undefined | null,
  context?: ToolCallContext
): Record<string, unknown> {
  // Handle empty/null args
  if (!args || args.trim() === '') {
    return {};
  }

  try {
    const parsed = JSON.parse(args);
    // Ensure we return an object
    if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) {
      return parsed;
    }
    // If parsed to non-object, return as-is in wrapper
    logger.warn('Tool arguments parsed to non-object', {
      ...context,
      type: typeof parsed,
      isArray: Array.isArray(parsed),
    });
    return { value: parsed };
  } catch (e) {
    logger.warn('Failed to parse tool call arguments', {
      ...context,
      args: args.length > 200 ? args.slice(0, 200) + '...' : args,
      error: e instanceof Error ? e.message : String(e),
    });
    return {};
  }
}

/**
 * Check if tool call arguments are valid JSON.
 *
 * Useful for validation before processing.
 *
 * @param args - Raw JSON string to validate
 * @returns True if args is valid JSON object
 */
export function isValidToolCallArguments(args: string | undefined | null): boolean {
  if (!args || args.trim() === '') {
    return true; // Empty args are valid (means no arguments)
  }

  try {
    const parsed = JSON.parse(args);
    return typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed);
  } catch {
    return false;
  }
}
