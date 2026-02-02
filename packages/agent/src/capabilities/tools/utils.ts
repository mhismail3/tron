/**
 * @fileoverview Tool Utilities
 *
 * Shared utilities for tools:
 * - Token estimation and output truncation
 * - Path resolution
 * - Parameter validation
 * - File system error formatting
 */

import * as path from 'path';
import type { TronToolResult } from '@core/types/index.js';

const DEFAULT_CHARS_PER_TOKEN = 4;

/**
 * Estimate tokens from character count.
 * This is a conservative estimate; real tokenization often produces fewer tokens.
 *
 * @param chars - Number of characters to estimate tokens for
 * @param charsPerToken - Characters per token estimate (default: 4)
 * @returns Estimated token count
 */
export function estimateTokens(chars: number, charsPerToken = DEFAULT_CHARS_PER_TOKEN): number {
  return Math.ceil(chars / charsPerToken);
}

/**
 * Convert token limit to character limit.
 *
 * @param tokens - Number of tokens to convert
 * @param charsPerToken - Characters per token estimate (default: 4)
 * @returns Estimated character count
 */
export function tokensToChars(tokens: number, charsPerToken = DEFAULT_CHARS_PER_TOKEN): number {
  return tokens * charsPerToken;
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

// ============================================================================
// Path Resolution
// ============================================================================

/**
 * Resolve a file path relative to a working directory.
 * Returns absolute paths unchanged.
 */
export function resolvePath(filePath: string, workingDirectory: string): string {
  if (path.isAbsolute(filePath)) {
    return filePath;
  }
  return path.join(workingDirectory, filePath);
}

// ============================================================================
// Parameter Validation
// ============================================================================

/**
 * Result of parameter validation.
 */
export interface ValidationResult {
  valid: boolean;
  error?: TronToolResult;
}

/**
 * Validate that a required string parameter exists and is non-empty.
 * Returns a validation result that can be checked and returned early if invalid.
 *
 * @example
 * const validation = validateRequiredString(args, 'file_path', 'path to file');
 * if (!validation.valid) return validation.error!;
 */
export function validateRequiredString(
  args: Record<string, unknown>,
  paramName: string,
  description: string,
  example?: string
): ValidationResult {
  const value = args[paramName];

  if (value === undefined || value === null || typeof value !== 'string') {
    const exampleText = example ? ` Example: ${example}` : '';
    return {
      valid: false,
      error: {
        content: `Missing required parameter: ${paramName}. Please provide ${description}.${exampleText}`,
        isError: true,
        details: { [paramName]: value },
      },
    };
  }

  return { valid: true };
}

/**
 * Validate that a path string is not empty, '/', or '.'.
 * Call this after validateRequiredString for path parameters that need extra validation.
 */
export function validatePathNotRoot(
  pathValue: string,
  paramName: string
): ValidationResult {
  const trimmed = pathValue.trim();

  if (trimmed === '/' || trimmed === '.' || trimmed === '') {
    return {
      valid: false,
      error: {
        content: `Invalid ${paramName}: "${pathValue}". Please provide a specific file path, not a directory root. Example: "/path/to/file.txt" or "src/index.ts"`,
        isError: true,
        details: { [paramName]: pathValue },
      },
    };
  }

  return { valid: true };
}

/**
 * Validate that a required string parameter is non-empty (after trimming).
 * Use for pattern parameters where empty strings are invalid.
 */
export function validateNonEmptyString(
  value: string,
  paramName: string,
  example?: string
): ValidationResult {
  if (value.trim() === '') {
    const exampleText = example ? ` Example: ${example}` : '';
    return {
      valid: false,
      error: {
        content: `Invalid ${paramName}: ${paramName} cannot be empty.${exampleText}`,
        isError: true,
        details: { [paramName]: value },
      },
    };
  }

  return { valid: true };
}

// ============================================================================
// File System Error Formatting
// ============================================================================

/**
 * Format common file system errors into consistent TronToolResult.
 *
 * @param error - The caught error (expected to be NodeJS.ErrnoException)
 * @param filePath - The path that was being accessed
 * @param operation - Description of the operation (e.g., 'reading', 'writing', 'listing')
 */
export function formatFsError(
  error: unknown,
  filePath: string,
  operation: string
): TronToolResult {
  const err = error as NodeJS.ErrnoException;

  if (err.code === 'ENOENT') {
    return {
      content: `File not found: ${filePath}`,
      isError: true,
      details: { filePath, errorCode: err.code },
    };
  }

  if (err.code === 'EACCES') {
    return {
      content: `Permission denied: ${filePath}`,
      isError: true,
      details: { filePath, errorCode: err.code },
    };
  }

  if (err.code === 'EISDIR') {
    return {
      content: `Path is a directory, not a file: ${filePath}`,
      isError: true,
      details: { filePath, errorCode: err.code },
    };
  }

  if (err.code === 'ENOTDIR') {
    return {
      content: `Path is not a directory: ${filePath}`,
      isError: true,
      details: { filePath, errorCode: err.code },
    };
  }

  return {
    content: `Error ${operation} file: ${err.message}`,
    isError: true,
    details: { filePath, errorCode: err.code },
  };
}
