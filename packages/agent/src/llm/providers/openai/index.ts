/**
 * @fileoverview OpenAI Provider Module
 *
 * Exports the OpenAI provider and related types.
 * This module provides OAuth-based access to OpenAI models via the Responses API.
 */

// Main provider
export { OpenAIProvider, getDefaultOpenAISettings } from './openai-provider.js';

// Types
export type {
  OpenAIConfig,
  OpenAIStreamOptions,
  OpenAIOAuth,
  OpenAIApiSettings,
  ReasoningEffort,
  OpenAIModelId,
  OpenAICodexModelInfo,
  ResponsesInputItem,
  ResponsesTool,
  ResponsesOutputItem,
  ResponsesStreamEvent,
  MessageContent,
} from './types.js';

// Model constants
export { OPENAI_MODELS, DEFAULT_OPENAI_MODEL } from './types.js';

// Auth utilities (for testing/advanced use)
export {
  OpenAITokenManager,
  extractAccountId,
  shouldRefreshTokens,
  refreshTokens,
} from './auth.js';

// Message conversion (for testing/advanced use)
export {
  convertToResponsesInput,
  convertTools,
  generateToolClarificationMessage,
} from './message-converter.js';

// Stream handling (for testing/advanced use)
export {
  parseSSEStream,
  processStreamEvent,
  createStreamState,
  type StreamState,
} from './stream-handler.js';
