/**
 * @fileoverview Tool Output Utilities
 *
 * Shared utilities for estimating tokens and truncating tool output.
 * Uses a consistent 4 chars = 1 token ratio (matches context.compactor.charsPerToken).
 */

const CHARS_PER_TOKEN = 4;

/**
 * Estimate tokens from character count.
 * This is a conservative estimate; real tokenization often produces fewer tokens.
 */
export function estimateTokens(chars: number): number {
  return Math.ceil(chars / CHARS_PER_TOKEN);
}

/**
 * Convert token limit to character limit.
 */
export function tokensToChars(tokens: number): number {
  return tokens * CHARS_PER_TOKEN;
}

export interface TruncateOptions {
  /** Keep first N lines always (default: 0) */
  preserveStartLines?: number;
  /** Keep last N lines always (default: 0) */
  preserveEndLines?: number;
  /** Custom truncation message (default: auto-generated) */
  truncationMessage?: string;
}

export interface TruncateResult {
  /** The (potentially truncated) content */
  content: string;
  /** Whether truncation occurred */
  truncated: boolean;
  /** Original size in estimated tokens */
  originalTokens: number;
  /** Final size in estimated tokens */
  finalTokens: number;
}

/**
 * Truncate output to stay within token budget.
 * Returns the truncated output and metadata about truncation.
 *
 * @param output - The output string to potentially truncate
 * @param maxTokens - Maximum tokens allowed
 * @param options - Truncation options
 * @returns Truncation result with content and metadata
 */
export function truncateOutput(
  output: string,
  maxTokens: number,
  options: TruncateOptions = {}
): TruncateResult {
  const originalChars = output.length;
  const originalTokens = estimateTokens(originalChars);

  if (originalTokens <= maxTokens) {
    return {
      content: output,
      truncated: false,
      originalTokens,
      finalTokens: originalTokens,
    };
  }

  const maxChars = tokensToChars(maxTokens);
  const defaultMessage = `\n\n... [Output truncated: ${originalTokens.toLocaleString()} tokens exceeded ${maxTokens.toLocaleString()} token limit]`;
  const message = options.truncationMessage ?? defaultMessage;

  const preserveStart = options.preserveStartLines ?? 0;
  const preserveEnd = options.preserveEndLines ?? 0;

  // Simple truncation if no line preservation needed
  if (preserveStart === 0 && preserveEnd === 0) {
    const availableChars = maxChars - message.length;
    if (availableChars <= 0) {
      // Edge case: message alone exceeds budget
      return {
        content: message.slice(0, maxChars),
        truncated: true,
        originalTokens,
        finalTokens: estimateTokens(Math.min(message.length, maxChars)),
      };
    }

    const truncated = output.slice(0, availableChars) + message;
    return {
      content: truncated,
      truncated: true,
      originalTokens,
      finalTokens: estimateTokens(truncated.length),
    };
  }

  // Smart truncation preserving start and end lines
  const lines = output.split('\n');
  const startLines = lines.slice(0, preserveStart);
  const endLines = preserveEnd > 0 ? lines.slice(-preserveEnd) : [];
  const middleLines = lines.slice(preserveStart, preserveEnd > 0 ? -preserveEnd : undefined);

  const startContent = startLines.join('\n');
  const endContent = endLines.join('\n');

  // Calculate remaining budget for middle content
  const reservedChars = startContent.length + endContent.length + message.length + 2; // +2 for newlines
  const remainingChars = maxChars - reservedChars;

  let result: string;

  if (remainingChars <= 0) {
    // Not enough room for middle content
    result = startContent + message + (endContent ? '\n' + endContent : '');
  } else {
    // Add as much of middle as fits
    let middleContent = '';
    for (const line of middleLines) {
      const lineWithNewline = line + '\n';
      if (middleContent.length + lineWithNewline.length > remainingChars) {
        break;
      }
      middleContent += lineWithNewline;
    }

    if (middleContent) {
      result = startContent + '\n' + middleContent.trimEnd() + message;
    } else {
      result = startContent + message;
    }

    if (endContent) {
      result += '\n' + endContent;
    }
  }

  return {
    content: result,
    truncated: true,
    originalTokens,
    finalTokens: estimateTokens(result.length),
  };
}
