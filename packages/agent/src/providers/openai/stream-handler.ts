/**
 * @fileoverview OpenAI Stream Handler
 *
 * Handles SSE stream parsing and event processing for OpenAI Responses API.
 * Converts stream events to Tron StreamEvent format.
 */

import type {
  StreamEvent,
  AssistantMessage,
  TextContent,
  ThinkingContent,
  ToolCall,
} from '../../types/index.js';
import { createLogger } from '../../logging/index.js';
import type { ResponsesStreamEvent } from './types.js';

const logger = createLogger('openai-stream');

/**
 * State for tracking stream accumulation
 */
export interface StreamState {
  accumulatedText: string;
  accumulatedThinking: string;
  toolCalls: Map<string, { id: string; name: string; args: string }>;
  inputTokens: number;
  outputTokens: number;
  textStarted: boolean;
  thinkingStarted: boolean;
  seenThinkingTexts: Set<string>;
}

/**
 * Create initial stream state
 */
export function createStreamState(): StreamState {
  return {
    accumulatedText: '',
    accumulatedThinking: '',
    toolCalls: new Map(),
    inputTokens: 0,
    outputTokens: 0,
    textStarted: false,
    thinkingStarted: false,
    seenThinkingTexts: new Set(),
  };
}

/**
 * Process a single SSE event and yield corresponding StreamEvents
 */
export function* processStreamEvent(
  event: ResponsesStreamEvent,
  state: StreamState
): Generator<StreamEvent> {
  // Log SSE events at trace level for debugging
  logger.trace('OpenAI SSE event received', {
    type: event.type,
    hasDelta: !!event.delta,
    deltaPreview: event.delta?.substring(0, 50),
    hasItem: !!event.item,
    itemType: event.item?.type,
    hasSummary: !!event.item?.summary,
    summaryLength: event.item?.summary?.length,
  });

  // Log tool call events for debugging
  if (event.type?.includes('function') || event.type?.includes('output_item')) {
    logger.debug('OpenAI SSE event', {
      type: event.type,
      hasItem: !!event.item,
      itemType: event.item?.type,
      callId: event.call_id ?? event.item?.call_id,
      hasArguments: !!event.item?.arguments || !!event.delta,
      argumentsPreview: (event.item?.arguments ?? event.delta ?? '').substring(0, 100),
    });
  }

  switch (event.type) {
    case 'response.output_text.delta':
      if (event.delta) {
        if (!state.textStarted) {
          state.textStarted = true;
          yield { type: 'text_start' };
        }
        state.accumulatedText += event.delta;
        yield { type: 'text_delta', delta: event.delta };
      }
      break;

    case 'response.output_item.added':
      if (event.item?.type === 'function_call' && event.item.call_id && event.item.name) {
        const callId = event.item.call_id;
        const initialArgs = event.item.arguments || '';
        logger.debug('Tool call added via output_item.added', {
          callId,
          name: event.item.name,
          hasArguments: !!event.item.arguments,
          argumentsLength: initialArgs.length,
        });
        state.toolCalls.set(callId, {
          id: callId,
          name: event.item.name,
          args: initialArgs,
        });
        yield {
          type: 'toolcall_start',
          toolCallId: callId,
          name: event.item.name,
        };
      } else if (event.item?.type === 'reasoning') {
        // Reasoning item added - start thinking if not already started
        if (!state.thinkingStarted) {
          state.thinkingStarted = true;
          yield { type: 'thinking_start' };
        }
      }
      break;

    case 'response.output_item.done':
      // Handle completed reasoning items - summary may be in item.summary
      // Only process if we didn't already get content via streaming deltas
      if (event.item?.type === 'reasoning' && event.item.summary && !state.accumulatedThinking) {
        if (!state.thinkingStarted) {
          state.thinkingStarted = true;
          yield { type: 'thinking_start' };
        }
        for (const summaryPart of event.item.summary) {
          if (summaryPart.type === 'summary_text' && summaryPart.text) {
            state.seenThinkingTexts.add(summaryPart.text);
            state.accumulatedThinking += summaryPart.text;
            yield { type: 'thinking_delta', delta: summaryPart.text };
          }
        }
      }
      break;

    case 'response.reasoning_summary_part.added':
      // A new reasoning summary part is being added
      if (!state.thinkingStarted) {
        state.thinkingStarted = true;
        yield { type: 'thinking_start' };
      }
      break;

    case 'response.reasoning_summary_text.delta':
      // Delta for reasoning summary text - skip if we already have this content
      if (event.delta && !state.seenThinkingTexts.has(event.delta)) {
        state.seenThinkingTexts.add(event.delta);
        if (!state.thinkingStarted) {
          state.thinkingStarted = true;
          yield { type: 'thinking_start' };
        }
        state.accumulatedThinking += event.delta;
        yield { type: 'thinking_delta', delta: event.delta };
      }
      break;

    case 'response.function_call_arguments.delta':
      if (event.call_id && event.delta) {
        const tc = state.toolCalls.get(event.call_id);
        if (tc) {
          tc.args += event.delta;
          logger.debug('Tool call arguments delta', {
            callId: event.call_id,
            deltaLength: event.delta.length,
            totalArgsLength: tc.args.length,
          });
          yield {
            type: 'toolcall_delta',
            toolCallId: event.call_id,
            argumentsDelta: event.delta,
          };
        }
      }
      break;

    case 'response.completed':
      yield* processCompletedResponse(event, state);
      break;
  }
}

/**
 * Process the response.completed event and emit final events
 */
function* processCompletedResponse(
  event: ResponsesStreamEvent,
  state: StreamState
): Generator<StreamEvent> {
  if (!event.response) return;

  // Log the full response for debugging
  const reasoningItems = event.response.output.filter(o => o.type === 'reasoning');
  logger.trace('OpenAI response.completed', {
    outputCount: event.response.output.length,
    outputTypes: event.response.output.map(o => o.type),
    reasoningItemCount: reasoningItems.length,
    reasoningItems: reasoningItems.map(r => ({
      hasSummary: !!r.summary,
      summaryLength: r.summary?.length,
      summaryTexts: r.summary?.map(s => s.text?.substring(0, 200)),
    })),
    functionCalls: event.response.output.filter(o => o.type === 'function_call').map(fc => ({
      name: fc.name,
      callId: fc.call_id,
      hasArguments: !!fc.arguments,
      argumentsLength: fc.arguments?.length ?? 0,
      argumentsPreview: fc.arguments?.substring(0, 200),
    })),
  });

  // Get usage
  if (event.response.usage) {
    state.inputTokens = event.response.usage.input_tokens;
    state.outputTokens = event.response.usage.output_tokens;
  }

  // Process output items from completed response
  for (const item of event.response.output) {
    if (item.type === 'message' && item.content) {
      for (const content of item.content) {
        if (content.type === 'output_text' && content.text) {
          if (!state.textStarted) {
            state.textStarted = true;
            state.accumulatedText = content.text;
          }
        }
      }
    } else if (item.type === 'reasoning' && item.summary && !state.accumulatedThinking) {
      // Handle reasoning item from completed response - only if we didn't get content via deltas
      for (const summaryItem of item.summary) {
        if (summaryItem.type === 'summary_text' && summaryItem.text) {
          if (!state.thinkingStarted) {
            state.thinkingStarted = true;
            yield { type: 'thinking_start' };
          }
          state.accumulatedThinking = summaryItem.text;
        }
      }
    } else if (item.type === 'function_call' && item.call_id) {
      logger.debug('Tool call in completed response', {
        callId: item.call_id,
        name: item.name,
        hasArguments: !!item.arguments,
        argumentsLength: item.arguments?.length ?? 0,
        argumentsPreview: item.arguments?.substring(0, 100),
      });
      const existing = state.toolCalls.get(item.call_id);
      if (existing) {
        // Update with completed response data if streaming didn't capture it
        if (item.arguments && !existing.args) {
          logger.debug('Updating tool call args from completed response', {
            callId: item.call_id,
            existingArgsLength: existing.args.length,
            newArgsLength: item.arguments.length,
          });
          existing.args = item.arguments;
        }
        if (item.name && !existing.name) {
          existing.name = item.name;
        }
      } else {
        state.toolCalls.set(item.call_id, {
          id: item.call_id,
          name: item.name || '',
          args: item.arguments || '',
        });
      }
    }
  }

  // Emit thinking_end if we had thinking
  if (state.thinkingStarted) {
    yield { type: 'thinking_end', thinking: state.accumulatedThinking };
  }

  // Emit text_end if we had text
  if (state.textStarted) {
    yield { type: 'text_end', text: state.accumulatedText };
  }

  // Emit toolcall_end for each tool call
  for (const [, tc] of state.toolCalls) {
    if (tc.id && tc.name) {
      logger.debug('Final tool call before emit', {
        id: tc.id,
        name: tc.name,
        argsLength: tc.args.length,
        argsPreview: tc.args.substring(0, 200),
      });
      let parsedArgs: Record<string, unknown> = {};
      try {
        parsedArgs = JSON.parse(tc.args || '{}');
      } catch {
        logger.warn('Failed to parse tool call arguments', { args: tc.args });
      }
      const toolCall: ToolCall = {
        type: 'tool_use',
        id: tc.id,
        name: tc.name,
        arguments: parsedArgs,
      };
      yield { type: 'toolcall_end', toolCall };
    }
  }

  // Build and emit final message
  yield buildDoneEvent(state);
}

/**
 * Build the final 'done' event with the complete message
 */
function buildDoneEvent(state: StreamState): StreamEvent {
  const content: (TextContent | ThinkingContent | ToolCall)[] = [];

  if (state.accumulatedThinking) {
    content.push({ type: 'thinking', thinking: state.accumulatedThinking });
  }

  if (state.accumulatedText) {
    content.push({ type: 'text', text: state.accumulatedText });
  }

  for (const [, tc] of state.toolCalls) {
    if (tc.id && tc.name) {
      let parsedArgs: Record<string, unknown> = {};
      try {
        parsedArgs = JSON.parse(tc.args || '{}');
      } catch {
        // Already logged above
      }
      content.push({
        type: 'tool_use',
        id: tc.id,
        name: tc.name,
        arguments: parsedArgs,
      });
    }
  }

  const message: AssistantMessage = {
    role: 'assistant',
    content,
    usage: {
      inputTokens: state.inputTokens,
      outputTokens: state.outputTokens,
      providerType: 'openai' as const,
    },
    stopReason: state.toolCalls.size > 0 ? 'tool_use' : 'end_turn',
  };

  return {
    type: 'done',
    message,
    stopReason: state.toolCalls.size > 0 ? 'tool_calls' : 'stop',
  };
}

/**
 * Parse SSE stream and yield events
 */
export async function* parseSSEStream(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  state: StreamState
): AsyncGenerator<StreamEvent> {
  const decoder = new TextDecoder();
  let buffer = '';

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;

    buffer += decoder.decode(value, { stream: true });

    // Process complete lines
    const lines = buffer.split('\n');
    buffer = lines.pop() || '';

    for (const line of lines) {
      if (!line.startsWith('data: ')) continue;

      const data = line.slice(6).trim();
      if (!data || data === '[DONE]') continue;

      try {
        const event = JSON.parse(data) as ResponsesStreamEvent;
        yield* processStreamEvent(event, state);
      } catch (e) {
        logger.warn('Failed to parse OpenAI event', { data, error: e });
      }
    }
  }
}
