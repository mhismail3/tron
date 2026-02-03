/**
 * @fileoverview Token Extraction Module
 *
 * Unified API for extracting token values from provider API responses.
 * Each provider has different response structures, so we provide
 * provider-specific extractors that all return a consistent TokenSource.
 */

// Re-export all extractors
export {
  extractFromAnthropic,
  type AnthropicMessageStartUsage,
  type AnthropicMessageDeltaUsage,
} from './anthropic.js';

export { extractFromOpenAI, type OpenAIUsage } from './openai.js';

export { extractFromGoogle, type GoogleUsageMetadata } from './google.js';

// Re-export common types
export type { ExtractionMeta } from './anthropic.js';
