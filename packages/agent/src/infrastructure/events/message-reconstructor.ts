/**
 * @fileoverview Message Reconstruction from Event Ancestry
 *
 * Extracts the complex message reconstruction logic from EventStore to enable
 * code reuse between getMessagesAt() and getStateAt(). Both methods need to:
 * - Build messages from message.user/message.assistant events
 * - Handle message deletion (message.deleted events)
 * - Handle compaction boundaries (compact.summary events)
 * - Handle context clearing (context.cleared events)
 * - Inject tool results as user messages for API compliance
 * - Restore truncated tool arguments from tool.call events
 */

import type { EventId, SessionEvent, Message, MessageWithEventId, TokenUsage } from './types.js';

// =============================================================================
// Types
// =============================================================================

export interface ReconstructionResult {
  /** Messages with their associated event IDs (unified, no parallel arrays) */
  messagesWithEventIds: MessageWithEventId[];
  tokenUsage: {
    inputTokens: number;
    outputTokens: number;
    cacheReadTokens: number;
    cacheCreationTokens: number;
  };
  turnCount: number;
  reasoningLevel?: 'low' | 'medium' | 'high' | 'xhigh';
  systemPrompt?: string;
}

// =============================================================================
// Helper Functions
// =============================================================================

/**
 * Normalize user message content to array format for consistent merging.
 * User content can be string or UserContent[].
 */
function normalizeUserContent(
  content: Message['content']
): Array<{ type: string; text?: string; [key: string]: unknown }> {
  if (typeof content === 'string') {
    return [{ type: 'text', text: content }];
  }
  return content as Array<{ type: string; text?: string; [key: string]: unknown }>;
}

/**
 * Merge content from a new message into an existing message.
 * Handles both user (string | content[]) and assistant (content[]) formats.
 */
function mergeMessageContent(
  existing: Message['content'],
  incoming: Message['content'],
  role: 'user' | 'assistant'
): Message['content'] {
  if (role === 'user') {
    const existingBlocks = normalizeUserContent(existing);
    const incomingBlocks = normalizeUserContent(incoming);
    const merged = [...existingBlocks, ...incomingBlocks];
    return merged as Message['content'];
  } else {
    const existingArr = existing as unknown[];
    const incomingArr = incoming as unknown[];
    return [...existingArr, ...incomingArr] as Message['content'];
  }
}

// =============================================================================
// Main Reconstruction Function
// =============================================================================

/**
 * Reconstruct messages and state from an ordered list of ancestor events.
 *
 * This implements the complex two-pass reconstruction algorithm:
 * 1. First pass: Collect deleted event IDs, tool.call arguments, and config state
 * 2. Second pass: Build messages while handling deletions, compaction, and tool results
 *
 * @param ancestors - Ordered list of events from session.start to target event
 * @returns Reconstruction result with messages, event IDs, token usage, and config state
 */
export function reconstructFromEvents(ancestors: SessionEvent[]): ReconstructionResult {
  // First pass: Collect deleted event IDs, tool.call arguments, and config state
  const deletedEventIds = new Set<EventId>();
  const toolCallArgsMap = new Map<string, Record<string, unknown>>();
  let reasoningLevel: 'low' | 'medium' | 'high' | 'xhigh' | undefined;
  let systemPrompt: string | undefined;

  for (const event of ancestors) {
    if (event.type === 'message.deleted') {
      const payload = event.payload as { targetEventId: EventId };
      deletedEventIds.add(payload.targetEventId);
    } else if (event.type === 'tool.call') {
      const payload = event.payload as { toolCallId: string; arguments: Record<string, unknown> };
      if (payload.toolCallId && payload.arguments) {
        toolCallArgsMap.set(payload.toolCallId, payload.arguments);
      }
    } else if (event.type === 'config.reasoning_level') {
      const payload = event.payload as { newLevel?: 'low' | 'medium' | 'high' | 'xhigh' };
      reasoningLevel = payload.newLevel;
    } else if (event.type === 'session.start') {
      const payload = event.payload as { systemPrompt?: string };
      if (payload.systemPrompt) {
        systemPrompt = payload.systemPrompt;
      }
    } else if (event.type === 'config.prompt_update') {
      const payload = event.payload as { newHash: string; contentBlobId?: string };
      if (payload.contentBlobId) {
        systemPrompt = `[Updated prompt - hash: ${payload.newHash}]`;
      }
    }
  }

  // Second pass: Build messages using combined MessageWithEventId array
  // This ensures messages and their event IDs stay in sync during all operations
  let combined: MessageWithEventId[] = [];
  let inputTokens = 0;
  let outputTokens = 0;
  let cacheReadTokens = 0;
  let cacheCreationTokens = 0;
  let turnCount = 0;
  let currentTurn = 0;

  // Accumulate tool results to inject as user messages when needed for agentic loops
  let pendingToolResults: Array<{ toolCallId: string; content: string; isError?: boolean }> = [];

  // Helper to get the last message entry (if any)
  const getLastEntry = (): MessageWithEventId | undefined => combined[combined.length - 1];

  // Helper to flush pending tool results as proper ToolResultMessage objects
  // This outputs the canonical internal format (role: 'toolResult', toolCallId, isError)
  // instead of the legacy format (role: 'user' with tool_result content blocks)
  const flushToolResults = () => {
    if (pendingToolResults.length > 0) {
      for (const tr of pendingToolResults) {
        combined.push({
          message: {
            role: 'toolResult',
            toolCallId: tr.toolCallId,
            content: tr.content,
            isError: tr.isError ?? false,
          },
          eventIds: [undefined], // Synthetic message from tool results
        });
      }
      pendingToolResults = [];
    }
  };

  for (const event of ancestors) {
    // Skip deleted messages
    if (deletedEventIds.has(event.id)) {
      continue;
    }

    // Handle compaction boundary - clear pre-compaction messages and inject summary
    if (event.type === 'compact.summary') {
      const payload = event.payload as { summary: string };
      combined = []; // Atomic clear
      pendingToolResults = [];
      combined.push({
        message: {
          role: 'user',
          content: `[Context from earlier in this conversation]\n\n${payload.summary}`,
        },
        eventIds: [undefined],
      });
      combined.push({
        message: {
          role: 'assistant',
          content: [
            {
              type: 'text',
              text: 'I understand the previous context. Let me continue helping you.',
            },
          ],
        },
        eventIds: [undefined],
      });
      continue;
    }

    // Handle context cleared - discard all messages before this point
    if (event.type === 'context.cleared') {
      combined = []; // Atomic clear
      pendingToolResults = [];
      continue;
    }

    // Accumulate tool.result events
    if (event.type === 'tool.result') {
      const payload = event.payload as { toolCallId: string; content: string; isError?: boolean };
      pendingToolResults.push({
        toolCallId: payload.toolCallId,
        content: payload.content,
        isError: payload.isError,
      });
      continue;
    }

    if (event.type === 'message.user') {
      // When a real user message follows tool results, discard pending tool results
      pendingToolResults = [];

      const payload = event.payload as { content: Message['content']; tokenUsage?: TokenUsage };
      const lastEntry = getLastEntry();

      // Merge consecutive user messages to ensure valid alternating structure
      if (lastEntry && lastEntry.message.role === 'user') {
        lastEntry.message.content = mergeMessageContent(lastEntry.message.content, payload.content, 'user');
        // Track ALL eventIds from merged messages for potential deletion
        lastEntry.eventIds.push(event.id);
      } else {
        combined.push({
          message: {
            role: 'user',
            content: payload.content,
          },
          eventIds: [event.id],
        });
      }

      if (payload.tokenUsage) {
        inputTokens += payload.tokenUsage.inputTokens;
        outputTokens += payload.tokenUsage.outputTokens;
        cacheReadTokens += payload.tokenUsage.cacheReadTokens ?? 0;
        cacheCreationTokens += payload.tokenUsage.cacheCreationTokens ?? 0;
      }
    } else if (event.type === 'message.assistant') {
      const payload = event.payload as {
        content: Message['content'];
        turn?: number;
        tokenUsage?: TokenUsage;
      };

      // Restore truncated tool_use inputs from tool.call events
      let restoredContent: Message['content'];
      if (Array.isArray(payload.content)) {
        restoredContent = payload.content.map(
          (block: { type: string; id?: string; input?: { _truncated?: boolean } }) => {
            if (block.type === 'tool_use' && block.input?._truncated && block.id) {
              const fullArgs = toolCallArgsMap.get(block.id);
              if (fullArgs) {
                return { ...block, input: fullArgs };
              }
            }
            return block;
          }
        ) as Message['content'];
      } else {
        restoredContent = payload.content;
      }

      // Check if this assistant message contains tool_use blocks
      const contentArray = Array.isArray(restoredContent) ? restoredContent : [];
      const hasToolUse = contentArray.some((block: { type: string }) => block.type === 'tool_use');

      // Check if the last message was an assistant (for agentic continuation)
      const lastEntry = getLastEntry();
      const lastWasAssistant = lastEntry && lastEntry.message.role === 'assistant';

      // CASE 1: Last message was assistant with tool_use, we have pending results
      if (lastWasAssistant && pendingToolResults.length > 0) {
        flushToolResults();
      }

      // Re-check last entry after potential flush
      const lastEntryAfterFlush = getLastEntry();

      // Merge consecutive assistant messages for robustness
      if (lastEntryAfterFlush && lastEntryAfterFlush.message.role === 'assistant') {
        lastEntryAfterFlush.message.content = mergeMessageContent(
          lastEntryAfterFlush.message.content,
          restoredContent,
          'assistant'
        );
        // Track ALL eventIds from merged messages for potential deletion
        lastEntryAfterFlush.eventIds.push(event.id);
      } else {
        combined.push({
          message: {
            role: 'assistant',
            content: restoredContent,
          },
          eventIds: [event.id],
        });
      }

      // CASE 2: This assistant message has tool_use, and we have pending tool results
      if (hasToolUse && pendingToolResults.length > 0) {
        flushToolResults();
      }

      if (payload.tokenUsage) {
        inputTokens += payload.tokenUsage.inputTokens;
        outputTokens += payload.tokenUsage.outputTokens;
        cacheReadTokens += payload.tokenUsage.cacheReadTokens ?? 0;
        cacheCreationTokens += payload.tokenUsage.cacheCreationTokens ?? 0;
      }
      if (payload.turn && payload.turn > currentTurn) {
        currentTurn = payload.turn;
        turnCount = payload.turn;
      }
    }
  }

  // Flush remaining tool results at the end IF the last message is an assistant with tool_use
  if (pendingToolResults.length > 0) {
    const lastEntry = getLastEntry();
    if (lastEntry && lastEntry.message.role === 'assistant') {
      const contentArray = Array.isArray(lastEntry.message.content) ? lastEntry.message.content : [];
      const hasToolUse = contentArray.some((block: { type: string }) => block.type === 'tool_use');
      if (hasToolUse) {
        flushToolResults();
      }
    }
  }

  return {
    messagesWithEventIds: combined,
    tokenUsage: { inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens },
    turnCount,
    reasoningLevel,
    systemPrompt,
  };
}
