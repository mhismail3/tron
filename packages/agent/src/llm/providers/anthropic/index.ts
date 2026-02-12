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
  AnthropicProviderSettings,
} from './types.js';

export {
  CLAUDE_MODELS,
  DEFAULT_MODEL,
  OAUTH_SYSTEM_PROMPT_PREFIX,
} from './types.js';

// Re-export provider class
export {
  AnthropicProvider,
} from './anthropic-provider.js';

// Re-export message conversion utilities (for testing)
export {
  convertMessages,
  convertTools,
  convertResponse,
} from './message-converter.js';

// Re-export stream handler (for testing)
export {
  processAnthropicStream,
  processStreamEvent,
  createStreamState,
  type StreamState,
  type AnthropicMessageStream,
} from './stream-handler.js';

// Re-export auth utilities (for testing)
export {
  getOAuthHeaders,
  ensureValidTokens,
  type TokenRefreshResult,
  type TokenPersistenceConfig,
} from './auth.js';
