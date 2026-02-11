/**
 * @fileoverview Provider Base Module
 *
 * Provides shared utilities and interfaces for LLM providers:
 * - Provider interface contract (types.ts)
 * - Stream retry utilities (stream-retry.ts)
 * - Stop reason mapping (stop-reason.ts)
 * - Tool call ID remapping (id-remapping.ts)
 *
 * This module is designed for composition, not inheritance. Each provider
 * maintains its own implementation while optionally using these utilities.
 */

// Types and interfaces
export type {
  BaseProviderConfig,
  BaseStreamOptions,
  Provider,
  ProviderWithComplete,
} from './types.js';

export {
  startEvent,
  textStartEvent,
  textDeltaEvent,
  textEndEvent,
  toolCallStartEvent,
  toolCallDeltaEvent,
  doneEvent,
  errorEvent,
} from './types.js';

// Stream retry utilities
export type { StreamRetryConfig } from './stream-retry.js';
export { withProviderRetry } from './stream-retry.js';

// Stop reason mapping utilities
export type { StopReason } from './stop-reason.js';
export { mapOpenAIStopReason, mapGoogleStopReason } from './stop-reason.js';

// Tool call ID remapping utilities
export type { IdFormat } from './id-remapping.js';
export {
  isAnthropicId,
  isOpenAIId,
  buildToolCallIdMapping,
  remapToolCallId,
  collectToolCallsFromMessages,
} from './id-remapping.js';

// SSE parsing utilities
export type { SSEParserOptions } from './sse-parser.js';
export { parseSSELines, parseSSEData } from './sse-parser.js';

// Tool call parsing utilities
export type { ToolCallContext } from './tool-parsing.js';
export { parseToolCallArguments, isValidToolCallArguments } from './tool-parsing.js';

// Context composition utilities
export { composeContextParts } from './context-composition.js';
