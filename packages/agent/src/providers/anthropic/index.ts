/**
 * @fileoverview Anthropic Provider Module
 *
 * Public API for the Anthropic Claude provider.
 * Exports maintain exact compatibility with the original monolithic anthropic.ts.
 */

// Re-export types
export type {
  AnthropicAuth,
  AnthropicConfig,
  StreamOptions,
  ClaudeModelId,
  ClaudeModelInfo,
  SystemPromptBlock,
} from './types.js';

export {
  CLAUDE_MODELS,
  DEFAULT_MODEL,
  OAUTH_SYSTEM_PROMPT_PREFIX,
} from './types.js';

// Re-export provider class and helpers
export {
  AnthropicProvider,
  getDefaultModel,
  getOAuthSystemPromptPrefix,
} from './anthropic-provider.js';

// Re-export message conversion utilities (for testing)
export {
  convertMessages,
  convertTools,
  convertResponse,
} from './message-converter.js';
