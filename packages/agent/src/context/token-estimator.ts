/**
 * @fileoverview Token Estimator
 *
 * Pure utility functions for token estimation.
 * Uses chars/4 approximation (consistent with Anthropic's tokenizer).
 *
 * Extracted from ContextManager to provide a shared, testable utility
 * for token estimation across the codebase.
 *
 * ## Token Estimation Formula
 *
 * For text content: tokens ≈ characters / 4
 *
 * For images (Anthropic): tokens = (width × height) / 750
 * - We estimate pixels from base64 data size
 * - Minimum 85 tokens per image
 * - Default 1500 tokens for URL images (typical 1024x1024)
 */
import type { Message, Tool } from '@core/types/index.js';

// =============================================================================
// Constants
// =============================================================================

/** Characters per token (standard approximation) */
export const CHARS_PER_TOKEN = 4;

/** Minimum tokens for any image */
const MIN_IMAGE_TOKENS = 85;

/** Default tokens for URL images (typical 1024x1024) */
const DEFAULT_URL_IMAGE_TOKENS = 1500;

/** Rules header that gets prepended by providers */
const RULES_HEADER = '# Project Rules\n\n';
const RULES_HEADER_LENGTH = RULES_HEADER.length;

// =============================================================================
// Types
// =============================================================================

/** Image source for token estimation */
export interface ImageSource {
  type: 'base64' | 'url';
  data?: string;
  url?: string;
}

// =============================================================================
// Block Estimation
// =============================================================================

/**
 * Estimate tokens for a content block.
 *
 * Handles:
 * - text blocks
 * - thinking blocks
 * - tool_use blocks
 * - tool_result blocks
 * - image blocks
 *
 * @param block - Content block (from message.content array)
 * @returns Estimated token count
 */
export function estimateBlockTokens(block: unknown): number {
  if (typeof block !== 'object' || block === null) {
    return 0;
  }

  const b = block as Record<string, unknown>;

  // Text block
  if (b.type === 'text' && typeof b.text === 'string') {
    return Math.ceil(b.text.length / CHARS_PER_TOKEN);
  }

  // Thinking block
  if (b.type === 'thinking' && typeof b.thinking === 'string') {
    return Math.ceil(b.thinking.length / CHARS_PER_TOKEN);
  }

  // Tool use block
  if (b.type === 'tool_use') {
    let chars = 0;
    if (typeof b.id === 'string') chars += b.id.length;
    if (typeof b.name === 'string') chars += b.name.length;

    // Handle both 'input' and 'arguments' formats
    const inputData = b.input ?? b.arguments ?? {};
    chars += JSON.stringify(inputData).length;

    return Math.ceil(chars / CHARS_PER_TOKEN);
  }

  // Tool result block
  if (b.type === 'tool_result') {
    let chars = 0;
    if (typeof b.tool_use_id === 'string') chars += b.tool_use_id.length;
    if (typeof b.content === 'string') chars += b.content.length;
    return Math.ceil(chars / CHARS_PER_TOKEN);
  }

  // Image block
  if (b.type === 'image') {
    const source = b.source as ImageSource | undefined;
    return estimateImageTokens(source);
  }

  // Unknown type - fall back to JSON serialization
  return Math.ceil(JSON.stringify(block).length / CHARS_PER_TOKEN);
}

// =============================================================================
// Image Estimation
// =============================================================================

/**
 * Estimate tokens for an image.
 *
 * Uses Anthropic's formula: tokens = (width × height) / 750
 *
 * For base64 images, we estimate dimensions from data size:
 * - Base64 overhead is ~33%, so actual bytes = length * 0.75
 * - Use compression ratio of 5 for mixed content
 * - Minimum 85 tokens per image
 *
 * For URL images, we use a conservative default (1500 tokens for ~1024x1024).
 *
 * @param source - Image source object
 * @returns Estimated token count
 */
export function estimateImageTokens(source: ImageSource | undefined): number {
  if (!source) {
    return DEFAULT_URL_IMAGE_TOKENS;
  }

  if (source.type === 'base64' && typeof source.data === 'string') {
    // Estimate from base64 data size
    const dataLength = source.data.length;
    const estimatedBytes = dataLength * 0.75;
    const estimatedPixels = estimatedBytes * 5; // compression ratio estimate
    const tokens = Math.ceil(estimatedPixels / 750);
    return Math.max(MIN_IMAGE_TOKENS, tokens);
  }

  // URL or unknown - use conservative default
  return DEFAULT_URL_IMAGE_TOKENS;
}

// =============================================================================
// Message Estimation
// =============================================================================

/**
 * Estimate tokens for a single message.
 *
 * Includes overhead for role and message structure (~10 chars).
 *
 * @param message - Message to estimate
 * @returns Estimated token count
 */
export function estimateMessageTokens(message: Message): number {
  // Base overhead for role and structure
  let chars = (message.role?.length ?? 0) + 10;

  if (message.role === 'toolResult') {
    // Tool result message
    chars += message.toolCallId?.length ?? 0;

    if (typeof message.content === 'string') {
      chars += message.content.length;
    } else if (Array.isArray(message.content)) {
      for (const block of message.content) {
        chars += estimateBlockTokens(block) * CHARS_PER_TOKEN;
      }
    }
  } else if (typeof message.content === 'string') {
    // Simple string content
    chars += message.content.length;
  } else if (Array.isArray(message.content)) {
    // Array of content blocks
    for (const block of message.content) {
      chars += estimateBlockTokens(block) * CHARS_PER_TOKEN;
    }
  }

  return Math.ceil(chars / CHARS_PER_TOKEN);
}

/**
 * Estimate tokens for an array of messages.
 *
 * @param messages - Messages to estimate
 * @returns Total estimated token count
 */
export function estimateMessagesTokens(messages: Message[]): number {
  let total = 0;
  for (const message of messages) {
    total += estimateMessageTokens(message);
  }
  return total;
}

// =============================================================================
// System & Tools Estimation
// =============================================================================

/**
 * Estimate tokens for system prompt and tools combined.
 *
 * @param systemPrompt - System prompt text
 * @param tools - Array of tool definitions
 * @returns Estimated token count
 */
export function estimateSystemTokens(systemPrompt: string, tools: Tool[]): number {
  let chars = systemPrompt.length;

  // Add tool definitions
  for (const tool of tools) {
    chars += JSON.stringify(tool).length;
  }

  return Math.ceil(chars / CHARS_PER_TOKEN);
}

/**
 * Estimate tokens for system prompt.
 *
 * @param systemPrompt - System prompt text
 * @param toolClarification - Optional tool clarification message (for Codex providers)
 * @returns Estimated token count
 */
export function estimateSystemPromptTokens(
  systemPrompt: string,
  toolClarification?: string | null
): number {
  const totalLength = systemPrompt.length + (toolClarification?.length ?? 0);
  return Math.ceil(totalLength / CHARS_PER_TOKEN);
}

/**
 * Estimate tokens for tool definitions.
 *
 * @param tools - Array of tool definitions
 * @returns Estimated token count
 */
export function estimateToolsTokens(tools: Tool[]): number {
  return Math.ceil(
    tools.reduce((sum, t) => sum + JSON.stringify(t).length / CHARS_PER_TOKEN, 0)
  );
}

/**
 * Estimate tokens for rules content.
 *
 * Includes header overhead ("# Project Rules\n\n").
 *
 * @param rulesContent - Rules content from CLAUDE.md/AGENTS.md
 * @returns Estimated token count
 */
export function estimateRulesTokens(rulesContent: string | undefined): number {
  if (!rulesContent) {
    return 0;
  }

  // Include header that providers add
  const totalLength = rulesContent.length + RULES_HEADER_LENGTH;
  return Math.ceil(totalLength / CHARS_PER_TOKEN);
}
