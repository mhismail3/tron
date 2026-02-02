/**
 * @fileoverview Content Block Builder
 *
 * Pure functions for building API-compatible content blocks.
 * Extracted from TurnContentTracker for better testability and separation of concerns.
 *
 * ## Key Responsibilities
 *
 * 1. **Pre-Tool Content Building** - Build content blocks for flushing before tool execution
 * 2. **Interrupted Content Building** - Build content blocks for persisting interrupted sessions
 * 3. **Individual Block Builders** - Helper functions for thinking, tool_use, and tool_result blocks
 *
 * ## Design Principles
 *
 * - **Pure Functions** - No side effects, same inputs always produce same outputs
 * - **API Compatibility** - Output matches Anthropic API content block format
 * - **Thinking First** - Thinking blocks always come before text and tool_use (API convention)
 */

// =============================================================================
// Types
// =============================================================================

/** Content sequence item - text, thinking, or a reference to a tool call */
export type ContentSequenceItem =
  | { type: 'text'; text: string }
  | { type: 'thinking'; thinking: string }
  | { type: 'tool_ref'; toolCallId: string };

/** Tool call data for tracking */
export interface ToolCallData {
  toolCallId: string;
  toolName: string;
  arguments: Record<string, unknown>;
  status: 'pending' | 'running' | 'completed' | 'error';
  result?: string;
  isError?: boolean;
  startedAt?: string;
  completedAt?: string;
}

/** Metadata for tool_use blocks in interrupted content */
export interface ToolUseMeta {
  status: 'pending' | 'running' | 'completed' | 'error';
  interrupted: boolean;
  durationMs?: number;
}

/** Metadata for tool_result blocks in interrupted content */
export interface ToolResultMeta {
  durationMs?: number;
  toolName: string;
  interrupted?: boolean;
}

/** Pre-tool content block (text, tool_use, or thinking) */
export interface PreToolContentBlock {
  type: 'text' | 'tool_use' | 'thinking';
  text?: string;
  thinking?: string;
  signature?: string;
  id?: string;
  name?: string;
  input?: Record<string, unknown>;
}

/** Interrupted content with assistant content and tool results */
export interface InterruptedContentBlocks {
  assistantContent: Array<{
    type: 'text' | 'tool_use' | 'thinking';
    text?: string;
    thinking?: string;
    signature?: string;
    id?: string;
    name?: string;
    input?: Record<string, unknown>;
    _meta?: ToolUseMeta;
  }>;
  toolResultContent: Array<{
    type: 'tool_result';
    tool_use_id: string;
    content: string;
    is_error: boolean;
    _meta?: ToolResultMeta;
  }>;
}

/** Thinking block */
export interface ThinkingBlock {
  type: 'thinking';
  thinking: string;
  signature?: string;
}

/** Tool use block */
export interface ToolUseBlock {
  type: 'tool_use';
  id: string;
  name: string;
  input: Record<string, unknown>;
  _meta?: ToolUseMeta;
}

/** Tool result block */
export interface ToolResultBlock {
  type: 'tool_result';
  tool_use_id: string;
  content: string;
  is_error: boolean;
  _meta?: ToolResultMeta;
}

// =============================================================================
// Helper Functions
// =============================================================================

/**
 * Calculate duration in milliseconds from tool call timestamps.
 */
function calculateDurationMs(toolCall: ToolCallData): number | undefined {
  if (toolCall.completedAt && toolCall.startedAt) {
    return new Date(toolCall.completedAt).getTime() - new Date(toolCall.startedAt).getTime();
  }
  return undefined;
}

/**
 * Check if a tool call is interrupted (running or pending status).
 */
function isToolInterrupted(toolCall: ToolCallData): boolean {
  return toolCall.status === 'running' || toolCall.status === 'pending';
}

// =============================================================================
// Block Builders
// =============================================================================

/**
 * Build a thinking block with optional signature.
 *
 * @param thinking - The thinking content
 * @param signature - Optional signature for API verification
 */
export function buildThinkingBlock(thinking: string, signature?: string): ThinkingBlock {
  const block: ThinkingBlock = {
    type: 'thinking',
    thinking,
  };

  if (signature) {
    block.signature = signature;
  }

  return block;
}

/**
 * Build a tool_use block with optional metadata.
 *
 * @param toolCall - Tool call data
 * @param includeMeta - Whether to include _meta for interrupted content
 */
export function buildToolUseBlock(toolCall: ToolCallData, includeMeta: boolean = false): ToolUseBlock {
  const block: ToolUseBlock = {
    type: 'tool_use',
    id: toolCall.toolCallId,
    name: toolCall.toolName,
    input: toolCall.arguments,
  };

  if (includeMeta) {
    block._meta = {
      status: toolCall.status,
      interrupted: isToolInterrupted(toolCall),
      durationMs: calculateDurationMs(toolCall),
    };
  }

  return block;
}

/**
 * Build a tool_result block with metadata.
 *
 * @param toolCall - Tool call data
 * @param interrupted - Whether this is for an interrupted session
 */
export function buildToolResultBlock(toolCall: ToolCallData, interrupted: boolean = false): ToolResultBlock {
  const durationMs = calculateDurationMs(toolCall);
  const isInterrupted = interrupted && isToolInterrupted(toolCall);

  // For interrupted tools, use special message
  if (isInterrupted) {
    return {
      type: 'tool_result',
      tool_use_id: toolCall.toolCallId,
      content: 'Command interrupted (no output captured)',
      is_error: false,
      _meta: {
        interrupted: true,
        durationMs,
        toolName: toolCall.toolName,
      },
    };
  }

  // For completed/error tools, use actual result
  const content = toolCall.result ?? (toolCall.isError ? 'Error' : '(no output)');

  return {
    type: 'tool_result',
    tool_use_id: toolCall.toolCallId,
    content,
    is_error: toolCall.isError ?? false,
    _meta: {
      durationMs,
      toolName: toolCall.toolName,
    },
  };
}

// =============================================================================
// Content Block Builders
// =============================================================================

/**
 * Build content blocks for pre-tool flush.
 *
 * Returns thinking (with signature) + text + tool_use blocks in proper order.
 * Thinking always comes first per Anthropic API convention.
 *
 * @param thinking - Accumulated thinking content
 * @param thinkingSignature - Signature for thinking block
 * @param sequence - Content sequence items
 * @param toolCalls - Map of tool call data
 * @param alreadyFlushed - Whether content was already flushed
 * @returns Content blocks or null if nothing to flush
 */
export function buildPreToolContentBlocks(
  thinking: string,
  thinkingSignature: string | undefined,
  sequence: ContentSequenceItem[],
  toolCalls: Map<string, ToolCallData>,
  alreadyFlushed: boolean = false
): PreToolContentBlock[] | null {
  // Already flushed - nothing to do
  if (alreadyFlushed) {
    return null;
  }

  // Check if we have any content (thinking OR sequence content)
  if (!thinking && sequence.length === 0) {
    return null;
  }

  const content: PreToolContentBlock[] = [];

  // CRITICAL: Include thinking block FIRST with signature - API requires it
  if (thinking) {
    const thinkingBlock: PreToolContentBlock = {
      type: 'thinking',
      thinking,
    };
    if (thinkingSignature) {
      thinkingBlock.signature = thinkingSignature;
    }
    content.push(thinkingBlock);
  }

  // Then add text and tool_use blocks from sequence
  for (const item of sequence) {
    if (item.type === 'text' && item.text) {
      content.push({ type: 'text', text: item.text });
    } else if (item.type === 'tool_ref') {
      const toolCall = toolCalls.get(item.toolCallId);
      if (toolCall) {
        content.push({
          type: 'tool_use',
          id: toolCall.toolCallId,
          name: toolCall.toolName,
          input: toolCall.arguments,
        });
      }
    }
  }

  if (content.length === 0) {
    return null;
  }

  return content;
}

/**
 * Build content blocks for persisting an interrupted session.
 *
 * Reconstructs assistant content and tool results with full _meta information.
 * Handles both completed and interrupted tools with proper status tracking.
 *
 * @param thinking - Accumulated thinking content
 * @param thinkingSignature - Signature for thinking block
 * @param sequence - Content sequence items
 * @param toolCalls - Array of tool call data
 * @param accumulatedText - Fallback text when sequence is empty
 * @returns Object with assistantContent and toolResultContent arrays
 */
export function buildInterruptedContentBlocks(
  thinking: string,
  thinkingSignature: string | undefined,
  sequence: ContentSequenceItem[],
  toolCalls: ToolCallData[],
  accumulatedText?: string
): InterruptedContentBlocks {
  const assistantContent: InterruptedContentBlocks['assistantContent'] = [];
  const toolResultContent: InterruptedContentBlocks['toolResultContent'] = [];

  // Build map of tool calls for quick lookup
  const toolCallMap = new Map<string, ToolCallData>();
  for (const tc of toolCalls) {
    toolCallMap.set(tc.toolCallId, tc);
  }

  /**
   * Helper to add tool_use and tool_result blocks for a tool call.
   */
  const addToolCallBlocks = (tc: ToolCallData): void => {
    // Add tool_use block with _meta
    assistantContent.push(buildToolUseBlock(tc, true));

    // Add tool_result
    toolResultContent.push(buildToolResultBlock(tc, true));
  };

  // Add thinking content first (Anthropic API puts thinking before text/tools)
  if (thinking) {
    const thinkingBlock: InterruptedContentBlocks['assistantContent'][0] = {
      type: 'thinking',
      thinking,
    };
    if (thinkingSignature) {
      thinkingBlock.signature = thinkingSignature;
    }
    assistantContent.push(thinkingBlock);
  }

  // Build content from sequence to preserve interleaving order
  if (sequence.length > 0) {
    for (const item of sequence) {
      if (item.type === 'text' && item.text) {
        assistantContent.push({ type: 'text', text: item.text });
      } else if (item.type === 'thinking' && item.thinking) {
        // Thinking from sequence (if tracked there)
        assistantContent.push({ type: 'thinking', thinking: item.thinking });
      } else if (item.type === 'tool_ref') {
        const tc = toolCallMap.get(item.toolCallId);
        if (tc) {
          addToolCallBlocks(tc);
        }
      }
    }
  } else {
    // Fallback: build from accumulated data without sequence tracking
    if (accumulatedText) {
      assistantContent.push({ type: 'text', text: accumulatedText });
    }

    for (const tc of toolCalls) {
      addToolCallBlocks(tc);
    }
  }

  return { assistantContent, toolResultContent };
}
