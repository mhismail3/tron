/**
 * @fileoverview Content Truncator
 *
 * Smart content truncation that preserves structure like headers and code blocks.
 * Used to limit content size before sending to Haiku for summarization.
 */

import type { ContentTruncateResult, ContentTruncatorConfig } from './types.js';

const DEFAULT_MAX_TOKENS = 50000;
const DEFAULT_PRESERVE_START_LINES = 100;
const DEFAULT_CHARS_PER_TOKEN = 4;

/**
 * Estimate token count from text
 *
 * @param text - Text to estimate
 * @param charsPerToken - Characters per token (default: 4)
 * @returns Estimated token count
 */
export function estimateTokens(textLength: number, charsPerToken = DEFAULT_CHARS_PER_TOKEN): number {
  if (textLength === 0) return 0;
  return Math.ceil(textLength / charsPerToken);
}

/**
 * Convert tokens to characters
 *
 * @param tokens - Token count
 * @param charsPerToken - Characters per token (default: 4)
 * @returns Character count
 */
export function tokensToChars(tokens: number, charsPerToken = DEFAULT_CHARS_PER_TOKEN): number {
  return tokens * charsPerToken;
}

/**
 * Truncate content to stay within token budget while preserving structure
 *
 * @param content - Content to truncate
 * @param config - Truncation configuration
 * @returns Truncation result with content and metadata
 */
export function truncateContent(
  content: string,
  config: ContentTruncatorConfig = {}
): ContentTruncateResult {
  const {
    maxTokens = DEFAULT_MAX_TOKENS,
    preserveStartLines = DEFAULT_PRESERVE_START_LINES,
    charsPerToken = DEFAULT_CHARS_PER_TOKEN,
  } = config;

  // Handle empty/whitespace content
  const trimmedContent = content?.trim() ?? '';
  if (!trimmedContent) {
    return {
      content: '',
      truncated: false,
      originalTokens: 0,
      finalTokens: 0,
      linesPreserved: 0,
    };
  }

  const originalTokens = estimateTokens(trimmedContent.length, charsPerToken);

  // If under limit, return as-is
  if (originalTokens <= maxTokens) {
    const lines = trimmedContent.split('\n');
    return {
      content: trimmedContent,
      truncated: false,
      originalTokens,
      finalTokens: originalTokens,
      linesPreserved: lines.length,
    };
  }

  // Calculate character budget
  const truncationMarker = '\n\n[Content truncated: exceeded token limit]';
  const markerChars = truncationMarker.length;
  const maxChars = tokensToChars(maxTokens, charsPerToken) - markerChars;

  if (maxChars <= 0) {
    // Edge case: marker alone exceeds budget
    const minimalResult = truncationMarker.slice(0, tokensToChars(maxTokens, charsPerToken));
    return {
      content: minimalResult,
      truncated: true,
      originalTokens,
      finalTokens: estimateTokens(minimalResult.length, charsPerToken),
      linesPreserved: 0,
    };
  }

  // Split into lines for smart truncation
  const lines = trimmedContent.split('\n');

  // Try to preserve important structure
  const result = smartTruncate(lines, maxChars, preserveStartLines);

  const finalContent = result.content + truncationMarker;
  const finalTokens = estimateTokens(finalContent.length, charsPerToken);

  return {
    content: finalContent,
    truncated: true,
    originalTokens,
    finalTokens,
    linesPreserved: result.linesPreserved,
  };
}

interface SmartTruncateResult {
  content: string;
  linesPreserved: number;
}

/**
 * Smart truncation that tries to preserve structure
 */
function smartTruncate(
  lines: string[],
  maxChars: number,
  preserveStartLines: number
): SmartTruncateResult {
  // Always preserve the specified number of start lines if possible
  const startLines = lines.slice(0, preserveStartLines);
  let currentContent = startLines.join('\n');
  let linesPreserved = startLines.length;

  // If start lines already exceed budget, truncate them
  if (currentContent.length > maxChars) {
    // Try to preserve at least headers and code blocks from start
    return truncatePreservingStructure(lines, maxChars);
  }

  // Add more lines while under budget
  const remainingLines = lines.slice(preserveStartLines);
  for (const line of remainingLines) {
    const tentative = currentContent + '\n' + line;
    if (tentative.length > maxChars) {
      break;
    }
    currentContent = tentative;
    linesPreserved++;
  }

  return {
    content: currentContent,
    linesPreserved,
  };
}

/**
 * Truncate while trying to preserve headers and code blocks
 */
function truncatePreservingStructure(
  lines: string[],
  maxChars: number
): SmartTruncateResult {
  const result: string[] = [];
  let currentLength = 0;
  let inCodeBlock = false;
  let linesPreserved = 0;

  for (const line of lines) {
    const lineWithNewline = (result.length > 0 ? '\n' : '') + line;
    const tentativeLength = currentLength + lineWithNewline.length;

    // Track code block state
    if (line.startsWith('```')) {
      inCodeBlock = !inCodeBlock;
    }

    // Priority preservation:
    // 1. Headers (# lines)
    // 2. Code block boundaries
    // 3. Regular content up to budget
    const isHeader = /^#{1,6}\s/.test(line);
    const isCodeBlockMarker = line.startsWith('```');

    if (tentativeLength <= maxChars) {
      result.push(line);
      currentLength = tentativeLength;
      linesPreserved++;
    } else if (isHeader || isCodeBlockMarker) {
      // Try to fit important lines even if we need to remove previous content
      // This is a simplified approach - just stop when budget exceeded
      break;
    } else {
      break;
    }
  }

  // If we're in an unclosed code block, close it
  if (inCodeBlock && result.length > 0) {
    const closingLine = '```';
    if (currentLength + closingLine.length + 1 <= maxChars) {
      result.push(closingLine);
      linesPreserved++;
    }
  }

  return {
    content: result.join('\n'),
    linesPreserved,
  };
}

/**
 * Content Truncator class for reusable truncation with configuration
 */
export class ContentTruncator {
  private config: ContentTruncatorConfig;

  constructor(config: ContentTruncatorConfig = {}) {
    this.config = config;
  }

  /**
   * Truncate content using configured or overridden settings
   */
  truncate(
    content: string,
    configOverride?: ContentTruncatorConfig
  ): ContentTruncateResult {
    const effectiveConfig = configOverride
      ? { ...this.config, ...configOverride }
      : this.config;
    return truncateContent(content, effectiveConfig);
  }

  /**
   * Update configuration
   */
  updateConfig(config: Partial<ContentTruncatorConfig>): void {
    this.config = { ...this.config, ...config };
  }

  /**
   * Get current configuration
   */
  getConfig(): ContentTruncatorConfig {
    return { ...this.config };
  }
}
