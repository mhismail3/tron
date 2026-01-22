/**
 * @fileoverview Stream Processor Module
 *
 * Handles processing of provider streams, accumulating text content
 * and tool calls into a final message. Provides interrupt recovery
 * by tracking partial streaming content.
 */

import type {
  AssistantMessage,
  ToolCall,
  TextContent,
  ThinkingContent,
  StreamEvent,
} from '../types/index.js';
import type {
  StreamProcessor as IStreamProcessor,
  StreamProcessorDependencies,
  StreamProcessorCallbacks,
  StreamResult,
  EventEmitter,
} from './internal-types.js';
import { createLogger } from '../logging/logger.js';

const logger = createLogger('agent:stream');

/**
 * Stream processor implementation
 */
export class AgentStreamProcessor implements IStreamProcessor {
  private readonly eventEmitter: EventEmitter;
  private readonly sessionId: string;
  private readonly getAbortSignal: () => AbortSignal | undefined;

  private streamingContent: string = '';

  /** Track accumulated thinking content */
  private accumulatedThinking: string = '';

  /** Track active tool calls for toolcall_delta events */
  private activeToolCalls: Map<string, string> = new Map(); // toolCallId -> toolName

  constructor(deps: StreamProcessorDependencies) {
    this.eventEmitter = deps.eventEmitter;
    this.sessionId = deps.sessionId;
    this.getAbortSignal = deps.getAbortSignal;
  }

  /**
   * Get the accumulated streaming content (for interrupt recovery)
   */
  getStreamingContent(): string {
    return this.streamingContent;
  }

  /**
   * Reset the streaming content accumulator
   */
  resetStreamingContent(): void {
    this.streamingContent = '';
    this.accumulatedThinking = '';
  }

  /**
   * Process a stream from the provider and accumulate the response
   */
  async process(
    stream: AsyncGenerator<StreamEvent>,
    callbacks?: StreamProcessorCallbacks
  ): Promise<StreamResult> {
    let assistantMessage: AssistantMessage | undefined;
    const toolCalls: ToolCall[] = [];
    let accumulatedText = '';
    let stopReason: string | undefined;

    for await (const event of stream) {
      // Check for abort
      const signal = this.getAbortSignal();
      if (signal?.aborted) {
        throw new Error('Aborted');
      }

      switch (event.type) {
        case 'text_delta':
          accumulatedText += event.delta;
          this.streamingContent += event.delta;

          // Emit message_update event
          this.eventEmitter.emit({
            type: 'message_update',
            sessionId: this.sessionId,
            timestamp: new Date().toISOString(),
            content: event.delta,
          });

          callbacks?.onTextDelta?.(event.delta);
          break;

        case 'toolcall_start':
          // Track tool name for subsequent delta events
          this.activeToolCalls.set(event.toolCallId, event.name);
          logger.debug('Tool call started', {
            toolCallId: event.toolCallId,
            toolName: event.name,
          });
          break;

        case 'toolcall_delta': {
          // Emit toolcall_delta TronEvent for progressive UI rendering
          const toolName = this.activeToolCalls.get(event.toolCallId);
          logger.debug('Tool call delta', {
            toolCallId: event.toolCallId,
            toolName,
            deltaLength: event.argumentsDelta.length,
          });
          this.eventEmitter.emit({
            type: 'toolcall_delta',
            sessionId: this.sessionId,
            timestamp: new Date().toISOString(),
            toolCallId: event.toolCallId,
            toolName,
            argumentsDelta: event.argumentsDelta,
          });
          break;
        }

        case 'toolcall_end':
          // Clean up tool call tracking
          this.activeToolCalls.delete(event.toolCall.id);
          toolCalls.push(event.toolCall);
          callbacks?.onToolCallEnd?.(event.toolCall);
          break;

        case 'thinking_start':
          // Emit thinking_start event for UI
          this.eventEmitter.emit({
            type: 'thinking_start',
            sessionId: this.sessionId,
            timestamp: new Date().toISOString(),
          });
          break;

        case 'thinking_delta':
          this.accumulatedThinking += event.delta;

          // Emit thinking_delta event for real-time UI streaming
          this.eventEmitter.emit({
            type: 'thinking_delta',
            sessionId: this.sessionId,
            timestamp: new Date().toISOString(),
            delta: event.delta,
          });

          callbacks?.onThinkingDelta?.(event.delta);
          break;

        case 'thinking_end':
          // Emit thinking_end event with complete thinking content
          this.eventEmitter.emit({
            type: 'thinking_end',
            sessionId: this.sessionId,
            timestamp: new Date().toISOString(),
            thinking: event.thinking,
          });
          break;

        case 'done':
          assistantMessage = event.message;
          stopReason = event.stopReason;

          // Check for any tool calls in the final message we might have missed
          for (const content of assistantMessage.content) {
            if (content.type === 'tool_use') {
              if (!toolCalls.some(tc => tc.id === content.id)) {
                toolCalls.push(content);
              }
            }
          }
          break;

        case 'error':
          throw event.error;

        case 'retry':
          logger.info('Retrying after rate limit', {
            attempt: event.attempt,
            maxRetries: event.maxRetries,
            delayMs: event.delayMs,
            category: event.error.category,
          });

          // Emit API retry event for TUI handling
          this.eventEmitter.emit({
            type: 'api_retry',
            sessionId: this.sessionId,
            timestamp: new Date().toISOString(),
            attempt: event.attempt,
            maxRetries: event.maxRetries,
            delayMs: event.delayMs,
            errorCategory: event.error.category,
            errorMessage: event.error.message,
          });

          callbacks?.onRetry?.(event);
          break;
      }
    }

    if (!assistantMessage) {
      throw new Error('No response received');
    }

    // Rebuild assistant message content if empty but we have accumulated data
    if (assistantMessage.content.length === 0 && (accumulatedText || toolCalls.length > 0 || this.accumulatedThinking)) {
      const rebuiltContent: (TextContent | ThinkingContent | ToolCall)[] = [];
      // Add thinking content first (follows Anthropic's response ordering)
      if (this.accumulatedThinking) {
        rebuiltContent.push({ type: 'thinking', thinking: this.accumulatedThinking });
      }
      if (accumulatedText) {
        rebuiltContent.push({ type: 'text', text: accumulatedText });
      }
      for (const tc of toolCalls) {
        rebuiltContent.push(tc);
      }
      assistantMessage = {
        ...assistantMessage,
        content: rebuiltContent,
        stopReason: stopReason as AssistantMessage['stopReason'],
      };
    }

    return {
      message: assistantMessage,
      toolCalls,
      accumulatedText,
      accumulatedThinking: this.accumulatedThinking || undefined,
      stopReason,
    };
  }
}

/**
 * Create a stream processor instance
 */
export function createStreamProcessor(deps: StreamProcessorDependencies): AgentStreamProcessor {
  return new AgentStreamProcessor(deps);
}
