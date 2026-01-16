/**
 * @fileoverview Provider Base Module
 *
 * Provides shared utilities and interfaces for LLM providers:
 * - Provider interface contract (types.ts)
 * - Stream retry utilities (stream-retry.ts)
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
