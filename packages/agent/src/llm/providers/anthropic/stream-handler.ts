/**
 * @fileoverview Anthropic Stream Handler
 *
 * Processes Anthropic SDK MessageStream events and yields standardized StreamEvents.
 * Extracted from anthropic-provider.ts for modularity and testability.
 */

import type Anthropic from '@anthropic-ai/sdk';
import type {
  AssistantMessage,
  StreamEvent,
  ToolCall,
} from '@core/types/index.js';
import { createLogger } from '@infrastructure/logging/index.js';
import { convertResponse } from './message-converter.js';

const logger = createLogger('anthropic-stream');

// =============================================================================
// Types
// =============================================================================

/**
 * State accumulated during stream processing
 */
export interface StreamState {
  currentBlockType: 'text' | 'thinking' | 'tool_use' | null;
  currentToolCallId: string | null;
  currentToolName: string | null;
  accumulatedText: string;
  accumulatedThinking: string;
  accumulatedSignature: string;
  accumulatedArgs: string;
  inputTokens: number;
  outputTokens: number;
  cacheCreationTokens: number;
  cacheReadTokens: number;
}

/**
 * Create initial stream state
 */
export function createStreamState(): StreamState {
  return {
    currentBlockType: null,
    currentToolCallId: null,
    currentToolName: null,
    accumulatedText: '',
    accumulatedThinking: '',
    accumulatedSignature: '',
    accumulatedArgs: '',
    inputTokens: 0,
    outputTokens: 0,
    cacheCreationTokens: 0,
    cacheReadTokens: 0,
  };
}

/**
 * Minimal interface for the Anthropic SDK stream object.
 * This allows testing without the full SDK dependency.
 */
export interface AnthropicMessageStream {
  [Symbol.asyncIterator](): AsyncIterator<Anthropic.Messages.MessageStreamEvent>;
  finalMessage(): Promise<Anthropic.Messages.Message>;
}

// =============================================================================
// Stream Processing
// =============================================================================

/**
 * Process a single Anthropic stream event and yield corresponding StreamEvents.
 *
 * This is a synchronous generator — it processes one SDK event at a time
 * and yields zero or more StreamEvents.
 */
export function* processStreamEvent(
  event: Anthropic.Messages.MessageStreamEvent,
  state: StreamState
): Generator<StreamEvent> {
  switch (event.type) {
    case 'message_start':
      if ('message' in event && event.message?.usage) {
        const usage = event.message.usage as {
          input_tokens?: number;
          cache_creation_input_tokens?: number;
          cache_read_input_tokens?: number;
        };
        state.inputTokens = usage.input_tokens ?? 0;
        state.cacheCreationTokens = usage.cache_creation_input_tokens ?? 0;
        state.cacheReadTokens = usage.cache_read_input_tokens ?? 0;
        logger.info('[CACHE] API response', {
          inputTokens: state.inputTokens,
          cacheCreationTokens: state.cacheCreationTokens,
          cacheReadTokens: state.cacheReadTokens,
          cacheHit: state.cacheReadTokens > 0,
          cacheWrite: state.cacheCreationTokens > 0,
        });
      }
      break;

    case 'message_delta':
      if ('usage' in event && event.usage) {
        state.outputTokens = (event.usage as { output_tokens?: number }).output_tokens ?? 0;
      }
      break;

    case 'content_block_start':
      if (event.content_block.type === 'text') {
        state.currentBlockType = 'text';
        yield { type: 'text_start' };
      } else if (event.content_block.type === 'thinking') {
        state.currentBlockType = 'thinking';
        yield { type: 'thinking_start' };
      } else if (event.content_block.type === 'tool_use') {
        state.currentBlockType = 'tool_use';
        state.currentToolCallId = event.content_block.id;
        state.currentToolName = event.content_block.name;
        yield {
          type: 'toolcall_start',
          toolCallId: event.content_block.id,
          name: event.content_block.name,
        };
      }
      break;

    case 'content_block_delta':
      if (event.delta.type === 'text_delta') {
        state.accumulatedText += event.delta.text;
        yield { type: 'text_delta', delta: event.delta.text };
      } else if (event.delta.type === 'thinking_delta') {
        state.accumulatedThinking += event.delta.thinking;
        yield { type: 'thinking_delta', delta: event.delta.thinking };
      } else if (event.delta.type === 'signature_delta') {
        state.accumulatedSignature += (event.delta as { signature: string }).signature;
      } else if (event.delta.type === 'input_json_delta') {
        state.accumulatedArgs += event.delta.partial_json;
        yield {
          type: 'toolcall_delta',
          toolCallId: state.currentToolCallId!,
          argumentsDelta: event.delta.partial_json,
        };
      }
      break;

    case 'content_block_stop':
      if (state.currentBlockType === 'text') {
        yield { type: 'text_end', text: state.accumulatedText };
        state.accumulatedText = '';
      } else if (state.currentBlockType === 'thinking') {
        yield {
          type: 'thinking_end',
          thinking: state.accumulatedThinking,
          ...(state.accumulatedSignature && { signature: state.accumulatedSignature }),
        };
        state.accumulatedThinking = '';
        state.accumulatedSignature = '';
      } else if (state.currentBlockType === 'tool_use') {
        const toolCall: ToolCall = {
          type: 'tool_use',
          id: state.currentToolCallId!,
          name: state.currentToolName!,
          arguments: JSON.parse(state.accumulatedArgs || '{}'),
        };
        yield { type: 'toolcall_end', toolCall };
        state.accumulatedArgs = '';
        state.currentToolCallId = null;
        state.currentToolName = null;
      }
      state.currentBlockType = null;
      break;
  }
}

/**
 * Process an Anthropic SDK MessageStream and yield standardized StreamEvents.
 *
 * Iterates over SDK events, delegates to processStreamEvent for each,
 * and handles the message_stop → finalMessage flow.
 */
export async function* processAnthropicStream(
  stream: AnthropicMessageStream,
  state: StreamState
): AsyncGenerator<StreamEvent> {
  for await (const event of stream) {
    if (event.type === 'message_stop') {
      yield* buildDoneEvent(stream, state);
      return;
    }
    yield* processStreamEvent(event, state);
  }
}

/**
 * Build the final 'done' event from the stream's finalMessage
 */
async function* buildDoneEvent(
  stream: AnthropicMessageStream,
  state: StreamState
): AsyncGenerator<StreamEvent> {
  try {
    const finalMessage = await stream.finalMessage();
    if (finalMessage) {
      const assistantMessage = convertResponse(finalMessage);
      if (state.inputTokens > 0 || state.outputTokens > 0) {
        assistantMessage.usage = {
          inputTokens: state.inputTokens || assistantMessage.usage?.inputTokens || 0,
          outputTokens: state.outputTokens || assistantMessage.usage?.outputTokens || 0,
          cacheCreationTokens: state.cacheCreationTokens || assistantMessage.usage?.cacheCreationTokens,
          cacheReadTokens: state.cacheReadTokens || assistantMessage.usage?.cacheReadTokens,
          providerType: 'anthropic' as const,
        };
      }
      yield {
        type: 'done',
        message: assistantMessage as AssistantMessage,
        stopReason: finalMessage.stop_reason ?? 'end_turn',
      };
    } else {
      yield* buildFallbackDoneEvent(state);
    }
  } catch (err) {
    const errMsg = err instanceof Error ? err.message : String(err);
    logger.warn('Could not get final message', { error: errMsg });
    yield* buildFallbackDoneEvent(state);
  }
}

/**
 * Build a fallback done event when finalMessage is unavailable
 */
function* buildFallbackDoneEvent(state: StreamState): Generator<StreamEvent> {
  yield {
    type: 'done',
    message: {
      role: 'assistant' as const,
      content: [],
      usage: {
        inputTokens: state.inputTokens,
        outputTokens: state.outputTokens,
        cacheCreationTokens: state.cacheCreationTokens,
        cacheReadTokens: state.cacheReadTokens,
        providerType: 'anthropic' as const,
      },
    },
    stopReason: 'end_turn',
  };
}
