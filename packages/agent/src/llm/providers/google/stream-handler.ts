/**
 * @fileoverview Google SSE Stream Handler
 *
 * Parses Server-Sent Events from Gemini API and emits standardized StreamEvents.
 * Extracted from google-provider.ts for modularity and testability.
 */

import { createLogger } from '@infrastructure/logging/index.js';
import { mapGoogleStopReason, parseSSELines } from '../base/index.js';
import type {
  AssistantMessage,
  StreamEvent,
  TextContent,
  ThinkingContent,
  ToolCall,
} from '@core/types/index.js';
import type { GeminiStreamChunk, GeminiPart, SafetyRating } from './types.js';

const logger = createLogger('google-stream');

// =============================================================================
// Types
// =============================================================================

/**
 * State accumulated during stream processing
 */
export interface StreamState {
  accumulatedText: string;
  accumulatedThinking: string;
  toolCalls: Array<{
    id: string;
    name: string;
    args: Record<string, unknown>;
    thoughtSignature?: string;
  }>;
  inputTokens: number;
  outputTokens: number;
  textStarted: boolean;
  thinkingStarted: boolean;
  toolCallIndex: number;
  uniquePrefix: string;
}

/**
 * Create initial stream state
 */
export function createStreamState(): StreamState {
  return {
    accumulatedText: '',
    accumulatedThinking: '',
    toolCalls: [],
    inputTokens: 0,
    outputTokens: 0,
    textStarted: false,
    thinkingStarted: false,
    toolCallIndex: 0,
    // Generate a unique prefix for this streaming response to avoid ID collisions across turns
    // Other providers (Anthropic, OpenAI) return globally unique IDs from the API
    // But Gemini doesn't provide IDs, so we must generate them ourselves
    uniquePrefix: Math.random().toString(36).substring(2, 10),
  };
}

// =============================================================================
// SSE Parsing
// =============================================================================

/**
 * Parse SSE stream and yield StreamEvents
 *
 * Uses shared SSE parser utility for consistent line parsing,
 * then processes Google-specific Gemini event format.
 */
export async function* parseSSEStream(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  state: StreamState
): AsyncGenerator<StreamEvent> {
  let receivedDone = false;

  // Google streams may have remaining buffer content (processRemainingBuffer: true by default)
  for await (const data of parseSSELines(reader)) {
    for (const event of processChunk(data, state)) {
      if (event.type === 'done') receivedDone = true;
      yield event;
    }
  }

  // Emit fallback done event if stream ended without finishReason
  if (!receivedDone) {
    logger.warn('Stream ended without finishReason, synthesizing done event', {
      hasText: state.accumulatedText.length > 0,
      hasThinking: state.accumulatedThinking.length > 0,
      toolCallCount: state.toolCalls.length,
    });
    yield* synthesizeDoneEvent(state);
  }
}

/**
 * Process a single SSE chunk
 */
function* processChunk(
  data: string,
  state: StreamState
): Generator<StreamEvent> {
  try {
    const chunk = JSON.parse(data) as GeminiStreamChunk;

    // Check for errors
    if (chunk.error) {
      throw new Error(`Gemini error: ${chunk.error.message}`);
    }

    // Process usage
    if (chunk.usageMetadata) {
      state.inputTokens = chunk.usageMetadata.promptTokenCount;
      state.outputTokens = chunk.usageMetadata.candidatesTokenCount;
    }

    const candidate = chunk.candidates?.[0];
    if (!candidate?.content?.parts) {
      // Handle finish reason without content (e.g., SAFETY block)
      if (candidate?.finishReason === 'SAFETY') {
        const safetyRatings = candidate.safetyRatings ?? [];
        yield* emitSafetyBlock(safetyRatings);
      }
      return;
    }

    // Process each part
    for (const part of candidate.content.parts) {
      yield* processPart(part, state);
    }

    // Handle finish
    if (candidate.finishReason) {
      yield* handleFinish(candidate.finishReason, candidate.safetyRatings, state);
    }
  } catch (e) {
    if (e instanceof Error && e.message.startsWith('Gemini')) {
      throw e;
    }
    logger.warn('Failed to parse chunk', { data, error: e });
  }
}

/**
 * Process a single content part from the stream
 */
function* processPart(
  part: GeminiPart,
  state: StreamState
): Generator<StreamEvent> {
  // Handle thinking content (thought: true)
  if ('text' in part && part.thought === true) {
    if (!state.thinkingStarted) {
      state.thinkingStarted = true;
      yield { type: 'thinking_start' };
    }
    state.accumulatedThinking += part.text;
    yield { type: 'thinking_delta', delta: part.text };
    return;
  }

  // Handle regular text content
  if ('text' in part && !part.thought) {
    // End thinking if we were in thinking mode
    if (state.thinkingStarted) {
      yield { type: 'thinking_end', thinking: state.accumulatedThinking };
      state.thinkingStarted = false;
    }

    if (!state.textStarted) {
      state.textStarted = true;
      yield { type: 'text_start' };
    }
    state.accumulatedText += part.text;
    yield { type: 'text_delta', delta: part.text };
  }

  // Handle function calls
  if ('functionCall' in part) {
    const fc = part.functionCall;
    const id = `call_${state.uniquePrefix}_${state.toolCallIndex++}`;
    // thoughtSignature is at the part level, not inside functionCall
    const thoughtSig = (part as { thoughtSignature?: string }).thoughtSignature;

    yield {
      type: 'toolcall_start',
      toolCallId: id,
      name: fc.name,
    };

    yield {
      type: 'toolcall_delta',
      toolCallId: id,
      argumentsDelta: JSON.stringify(fc.args),
    };

    state.toolCalls.push({
      id,
      name: fc.name,
      args: fc.args,
      // Capture thoughtSignature for Gemini 3 multi-turn function calling
      thoughtSignature: thoughtSig,
    });

    const toolCall: ToolCall = {
      type: 'tool_use',
      id,
      name: fc.name,
      arguments: fc.args,
      // Include thoughtSignature so it's preserved in events
      thoughtSignature: thoughtSig,
    };
    yield { type: 'toolcall_end', toolCall };
  }
}

/**
 * Handle stream finish
 */
function* handleFinish(
  finishReason: string,
  safetyRatings: SafetyRating[] | undefined,
  state: StreamState
): Generator<StreamEvent> {
  // End thinking if still active
  if (state.thinkingStarted) {
    yield { type: 'thinking_end', thinking: state.accumulatedThinking };
    state.thinkingStarted = false;
  }

  // Handle SAFETY finish reason
  if (finishReason === 'SAFETY') {
    yield* emitSafetyBlock(safetyRatings ?? []);
    return;
  }

  // Emit text_end if we had text
  if (state.textStarted) {
    yield { type: 'text_end', text: state.accumulatedText };
  }

  // Build final message - include thinking content if accumulated
  const content: (TextContent | ThinkingContent | ToolCall)[] = [];
  if (state.accumulatedThinking) {
    content.push({ type: 'thinking', thinking: state.accumulatedThinking });
  }
  if (state.accumulatedText) {
    content.push({ type: 'text', text: state.accumulatedText });
  }
  for (const tc of state.toolCalls) {
    content.push({
      type: 'tool_use',
      id: tc.id,
      name: tc.name,
      arguments: tc.args,
      // Preserve thought_signature for Gemini 3 multi-turn conversations
      ...(tc.thoughtSignature && { thoughtSignature: tc.thoughtSignature }),
    });
  }

  const message: AssistantMessage = {
    role: 'assistant',
    content,
    usage: { inputTokens: state.inputTokens, outputTokens: state.outputTokens, providerType: 'google' as const },
    stopReason: mapGoogleStopReason(finishReason),
  };

  yield {
    type: 'done',
    message,
    stopReason: finishReason,
  };
}

/**
 * Synthesize a done event when stream ends without finishReason
 * This handles cases where the API response is truncated or malformed
 */
function* synthesizeDoneEvent(state: StreamState): Generator<StreamEvent> {
  // End thinking if still active
  if (state.thinkingStarted) {
    yield { type: 'thinking_end', thinking: state.accumulatedThinking };
  }

  // Emit text_end if we had text
  if (state.textStarted) {
    yield { type: 'text_end', text: state.accumulatedText };
  }

  // Build final message with whatever we accumulated
  const content: (TextContent | ThinkingContent | ToolCall)[] = [];
  if (state.accumulatedThinking) {
    content.push({ type: 'thinking', thinking: state.accumulatedThinking });
  }
  if (state.accumulatedText) {
    content.push({ type: 'text', text: state.accumulatedText });
  }
  for (const tc of state.toolCalls) {
    content.push({
      type: 'tool_use',
      id: tc.id,
      name: tc.name,
      arguments: tc.args,
      ...(tc.thoughtSignature && { thoughtSignature: tc.thoughtSignature }),
    });
  }

  // Determine stop reason based on content - if we have tool calls, it's tool_use
  const stopReason = state.toolCalls.length > 0 ? 'tool_use' : 'end_turn';

  const message: AssistantMessage = {
    role: 'assistant',
    content,
    usage: { inputTokens: state.inputTokens, outputTokens: state.outputTokens, providerType: 'google' as const },
    stopReason,
  };

  yield {
    type: 'done',
    message,
    stopReason: state.toolCalls.length > 0 ? 'TOOL_USE' : 'STOP',
  };
}

/**
 * Emit safety block event
 */
function* emitSafetyBlock(safetyRatings: SafetyRating[]): Generator<StreamEvent> {
  const blockedCategories = safetyRatings
    .filter((r: SafetyRating) => r.probability === 'HIGH' || r.probability === 'MEDIUM')
    .map((r: SafetyRating) => r.category);

  yield {
    type: 'safety_block',
    blockedCategories,
    error: new Error('Response blocked by safety filters'),
  } as StreamEvent;
}
