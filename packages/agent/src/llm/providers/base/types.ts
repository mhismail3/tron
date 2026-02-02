/**
 * @fileoverview Provider Base Types
 *
 * Defines the common interface contract for all LLM providers.
 * Providers can implement this interface directly or use the composable
 * utilities provided in this module.
 *
 * Note: This is an interface contract, not a base class. Each provider
 * maintains its own implementation to handle provider-specific concerns
 * like OAuth, caching, and API formats.
 */

import type {
  AssistantMessage,
  Context,
  StreamEvent,
} from '@core/types/index.js';

// =============================================================================
// Provider Interface
// =============================================================================

/**
 * Base configuration shared by all providers
 */
export interface BaseProviderConfig {
  /** Model identifier */
  model: string;
  /** Maximum tokens to generate */
  maxTokens?: number;
  /** Temperature for generation */
  temperature?: number;
  /** Custom base URL for API */
  baseURL?: string;
}

/**
 * Base streaming options shared by all providers
 */
export interface BaseStreamOptions {
  /** Maximum tokens to generate */
  maxTokens?: number;
  /** Temperature for generation */
  temperature?: number;
  /** Stop sequences */
  stopSequences?: string[];
}

/**
 * Provider interface contract
 *
 * All providers must implement these methods. The interface is intentionally
 * minimal to allow provider-specific extensions.
 */
export interface Provider {
  /** Provider identifier */
  readonly id?: string;

  /** Current model ID */
  readonly model: string;

  /**
   * Stream a response from the LLM
   *
   * Must yield events in this order:
   * 1. { type: 'start' }
   * 2. { type: 'text_start' } (if text content)
   * 3. { type: 'text_delta', delta: string } (0 or more)
   * 4. { type: 'text_end', text: string }
   * 5. { type: 'toolcall_start', toolCallId, name } (if tool call)
   * 6. { type: 'toolcall_delta', toolCallId, argumentsDelta } (0 or more)
   * 7. { type: 'toolcall_end', toolCall }
   * 8. { type: 'done', message, stopReason }
   *
   * On error: { type: 'error', error }
   */
  stream(context: Context, options?: BaseStreamOptions): AsyncGenerator<StreamEvent>;
}

/**
 * Provider with non-streaming completion support
 */
export interface ProviderWithComplete extends Provider {
  /**
   * Non-streaming completion
   * Default implementation consumes the stream and returns the final message.
   */
  complete(context: Context, options?: BaseStreamOptions): Promise<AssistantMessage>;
}

// =============================================================================
// Stream Event Helpers
// =============================================================================

/**
 * Create a start event
 */
export function startEvent(): StreamEvent {
  return { type: 'start' };
}

/**
 * Create a text start event
 */
export function textStartEvent(): StreamEvent {
  return { type: 'text_start' };
}

/**
 * Create a text delta event
 */
export function textDeltaEvent(delta: string): StreamEvent {
  return { type: 'text_delta', delta };
}

/**
 * Create a text end event
 */
export function textEndEvent(text: string): StreamEvent {
  return { type: 'text_end', text };
}

/**
 * Create a tool call start event
 */
export function toolCallStartEvent(toolCallId: string, name: string): StreamEvent {
  return { type: 'toolcall_start', toolCallId, name };
}

/**
 * Create a tool call delta event
 */
export function toolCallDeltaEvent(toolCallId: string, argumentsDelta: string): StreamEvent {
  return { type: 'toolcall_delta', toolCallId, argumentsDelta };
}

/**
 * Create a done event
 */
export function doneEvent(message: AssistantMessage, stopReason: string): StreamEvent {
  return { type: 'done', message, stopReason };
}

/**
 * Create an error event
 */
export function errorEvent(error: Error): StreamEvent {
  return { type: 'error', error };
}
