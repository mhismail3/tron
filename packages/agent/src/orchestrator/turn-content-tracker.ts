/**
 * @fileoverview Turn Content Tracker
 *
 * Encapsulates dual content tracking for agent turns:
 * 1. Accumulated (across ALL turns) - for client catch-up when resuming into running session
 * 2. Per-turn (cleared after each message.assistant) - for building discrete message events
 *
 * This consolidates the duplicated tracking logic previously spread across forwardAgentEvent().
 *
 * ## Role in Streaming Architecture
 *
 * This class is the in-memory buffer for streaming content that is NOT persisted individually.
 * The lifecycle is:
 *
 * 1. Agent emits text_delta events during model response
 * 2. TurnContentTracker.addTextDelta() accumulates the text
 * 3. WebSocket broadcasts `agent.text_delta` for real-time UI
 * 4. At turn_end, accumulated content is consolidated into `message.assistant`
 * 5. Only the consolidated message.assistant is persisted to EventStore
 * 6. TurnContentTracker is cleared for the next turn
 *
 * This design keeps the EventStore efficient (no high-frequency delta spam) while
 * supporting both real-time streaming UI and session reconstruction.
 */
import { createLogger, type CurrentTurnToolCall } from '../index.js';

const logger = createLogger('turn-content-tracker');

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

/** Accumulated content for client catch-up */
export interface AccumulatedContent {
  text: string;
  thinking: string;
  thinkingSignature?: string; // Signature for thinking block verification (API requires this)
  toolCalls: CurrentTurnToolCall[];
  sequence: ContentSequenceItem[];
}

/** Per-turn content for building message.assistant */
export interface TurnContent {
  sequence: ContentSequenceItem[];
  toolCalls: Map<string, ToolCallData>;
  thinking: string;
  thinkingSignature?: string; // Signature for thinking block verification (API requires this)
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

/** Interrupted content for persistence */
export interface InterruptedContent {
  assistantContent: Array<{
    type: 'text' | 'tool_use' | 'thinking';
    text?: string;
    thinking?: string;
    signature?: string; // Signature for thinking blocks (API requires this)
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

// =============================================================================
// TurnContentTracker Implementation
// =============================================================================

/**
 * Encapsulates content tracking for agent turns.
 *
 * Maintains two parallel tracking structures:
 * 1. Accumulated - persists across ALL turns for client catch-up
 * 2. Per-turn - cleared after each message.assistant is created
 *
 * Single update methods ensure both structures stay in sync.
 */
export class TurnContentTracker {
  // =========================================================================
  // Accumulated state (across ALL turns for catch-up)
  // =========================================================================
  private accumulatedText: string = '';
  private accumulatedThinking: string = '';
  private accumulatedThinkingSignature?: string;
  private accumulatedToolCalls: ToolCallData[] = [];
  private accumulatedSequence: ContentSequenceItem[] = [];

  // =========================================================================
  // Per-turn state (cleared after each message.assistant)
  // =========================================================================
  private thisTurnSequence: ContentSequenceItem[] = [];
  private thisTurnToolCalls: Map<string, ToolCallData> = new Map();
  private thisTurnThinking: string = '';
  private thisTurnThinkingSignature?: string;

  // =========================================================================
  // Pre-tool flush tracking (for linear event ordering)
  // =========================================================================
  private preToolContentFlushed: boolean = false;

  // =========================================================================
  // Metadata
  // =========================================================================
  private currentTurn: number = 0;
  private currentTurnStartTime: number | undefined;
  private lastTurnTokenUsage: {
    inputTokens: number;
    outputTokens: number;
    cacheReadTokens?: number;
    cacheCreationTokens?: number;
  } | undefined;

  // =========================================================================
  // Update Methods (update BOTH tracking structures)
  // =========================================================================

  /**
   * Add a text delta to both accumulated and per-turn tracking.
   * Merges with previous text items if possible for clean sequences.
   */
  addTextDelta(text: string): void {
    // Update accumulated text
    this.accumulatedText += text;

    // Update accumulated sequence (merge with previous text if possible)
    const lastAccItem = this.accumulatedSequence[this.accumulatedSequence.length - 1];
    if (lastAccItem && lastAccItem.type === 'text') {
      lastAccItem.text += text;
    } else {
      this.accumulatedSequence.push({ type: 'text', text });
    }

    // Update per-turn sequence (merge with previous text if possible)
    const lastTurnItem = this.thisTurnSequence[this.thisTurnSequence.length - 1];
    if (lastTurnItem && lastTurnItem.type === 'text') {
      lastTurnItem.text += text;
    } else {
      this.thisTurnSequence.push({ type: 'text', text });
    }
  }

  /**
   * Add a thinking delta to both accumulated and per-turn tracking.
   * Thinking is accumulated separately from text for proper content block ordering.
   * Note: Thinking should appear FIRST in assistant messages (Anthropic API convention).
   */
  addThinkingDelta(thinking: string): void {
    // Update accumulated thinking
    this.accumulatedThinking += thinking;

    // Update per-turn thinking
    this.thisTurnThinking += thinking;

    // Note: We don't add to sequence here because thinking blocks should be
    // prepended to the content at turn end, not interleaved with text/tools.
    // This matches the Anthropic API response format where thinking comes first.
  }

  /**
   * Set the signature for the thinking block.
   * Called when thinking_end event is received with the complete signature.
   * The signature is required by the Anthropic API when sending thinking blocks back.
   */
  setThinkingSignature(signature: string): void {
    this.accumulatedThinkingSignature = signature;
    this.thisTurnThinkingSignature = signature;
  }

  /**
   * Register ALL tool intents from tool_use_batch event.
   * This registers tool_use blocks to tracking BEFORE any execution starts,
   * enabling linear event ordering: message.assistant → tool.call → tool.result.
   *
   * Called when tool_use_batch event arrives (before any tool_execution_start).
   */
  registerToolIntents(
    toolCalls: Array<{ id: string; name: string; arguments: Record<string, unknown> }>
  ): void {
    for (const tc of toolCalls) {
      // Skip if already registered (shouldn't happen, but be safe)
      if (this.thisTurnToolCalls.has(tc.id)) {
        continue;
      }

      const toolCallData: ToolCallData = {
        toolCallId: tc.id,
        toolName: tc.name,
        arguments: tc.arguments,
        status: 'pending', // Not yet running
        startedAt: undefined, // Will be set when execution actually starts
      };

      // Add to accumulated tracking
      this.accumulatedToolCalls.push(toolCallData);
      this.accumulatedSequence.push({ type: 'tool_ref', toolCallId: tc.id });

      // Add to per-turn tracking (clone to avoid shared mutations)
      this.thisTurnToolCalls.set(tc.id, { ...toolCallData });
      this.thisTurnSequence.push({ type: 'tool_ref', toolCallId: tc.id });
    }

    logger.debug('Registered tool intents', {
      turn: this.currentTurn,
      toolCount: toolCalls.length,
      toolNames: toolCalls.map(tc => tc.name),
    });
  }

  /**
   * Record a tool call starting.
   * Updates both accumulated and per-turn tracking.
   *
   * If tool was already registered via registerToolIntents(), just update status.
   * Otherwise, add to tracking (backward compatibility).
   */
  startToolCall(
    toolCallId: string,
    toolName: string,
    args: Record<string, unknown>,
    timestamp: string
  ): void {
    // Check if tool was already registered via tool_use_batch
    const existingTurnTool = this.thisTurnToolCalls.get(toolCallId);
    if (existingTurnTool) {
      // Tool already registered - just update status and start time
      existingTurnTool.status = 'running';
      existingTurnTool.startedAt = timestamp;

      // Also update in accumulated tracking
      const existingAccTool = this.accumulatedToolCalls.find(tc => tc.toolCallId === toolCallId);
      if (existingAccTool) {
        existingAccTool.status = 'running';
        existingAccTool.startedAt = timestamp;
      }

      logger.debug('Tool execution started (pre-registered)', {
        toolCallId,
        toolName,
        turn: this.currentTurn,
      });
      return;
    }

    // Tool not pre-registered - add it now (backward compatibility)
    const toolCallData: ToolCallData = {
      toolCallId,
      toolName,
      arguments: args,
      status: 'running',
      startedAt: timestamp,
    };

    // Add to accumulated tracking
    this.accumulatedToolCalls.push(toolCallData);
    this.accumulatedSequence.push({ type: 'tool_ref', toolCallId });

    // Add to per-turn tracking (clone to avoid shared mutations)
    this.thisTurnToolCalls.set(toolCallId, { ...toolCallData });
    this.thisTurnSequence.push({ type: 'tool_ref', toolCallId });

    logger.debug('Tool execution started (not pre-registered)', {
      toolCallId,
      toolName,
      turn: this.currentTurn,
    });
  }

  /**
   * Record a tool call completing.
   * Updates the tool in both accumulated and per-turn tracking.
   */
  endToolCall(
    toolCallId: string,
    result: string,
    isError: boolean,
    timestamp: string
  ): void {
    // Update in accumulated tracking
    const accToolCall = this.accumulatedToolCalls.find(tc => tc.toolCallId === toolCallId);
    if (accToolCall) {
      accToolCall.status = isError ? 'error' : 'completed';
      accToolCall.result = result;
      accToolCall.isError = isError;
      accToolCall.completedAt = timestamp;
    }

    // Update in per-turn tracking
    const turnToolCall = this.thisTurnToolCalls.get(toolCallId);
    if (turnToolCall) {
      turnToolCall.status = isError ? 'error' : 'completed';
      turnToolCall.result = result;
      turnToolCall.isError = isError;
      turnToolCall.completedAt = timestamp;
    }
  }

  // =========================================================================
  // Turn Lifecycle Methods
  // =========================================================================

  /**
   * Called at the start of each turn.
   * Clears per-turn state, adds separator to accumulated if needed.
   */
  onTurnStart(turn: number): void {
    this.currentTurn = turn;
    this.currentTurnStartTime = Date.now();

    // Clear per-turn tracking for the new turn
    this.thisTurnSequence = [];
    this.thisTurnToolCalls = new Map();
    this.thisTurnThinking = '';
    this.thisTurnThinkingSignature = '';

    // Reset pre-tool flush flag for new turn
    this.preToolContentFlushed = false;

    // Add separator between turns in accumulated text (if not first turn)
    // This ensures text from different turns doesn't run together
    if (turn > 1 && this.accumulatedText.length > 0) {
      this.accumulatedText += '\n';
    }

    logger.debug('Turn started', { turn });
  }

  /**
   * Called at the end of each turn.
   * Stores token usage and returns per-turn content for message.assistant creation.
   */
  onTurnEnd(tokenUsage?: {
    inputTokens: number;
    outputTokens: number;
    cacheReadTokens?: number;
    cacheCreationTokens?: number;
  }): TurnContent {
    // Store token usage
    if (tokenUsage) {
      this.lastTurnTokenUsage = tokenUsage;
    }

    // Capture per-turn content before clearing
    const content: TurnContent = {
      sequence: [...this.thisTurnSequence],
      toolCalls: new Map(this.thisTurnToolCalls),
      thinking: this.thisTurnThinking,
      thinkingSignature: this.thisTurnThinkingSignature || undefined,
    };

    // Clear per-turn tracking (accumulated persists for catch-up)
    this.thisTurnSequence = [];
    this.thisTurnToolCalls = new Map();
    this.thisTurnThinking = '';
    this.thisTurnThinkingSignature = undefined;

    logger.debug('Turn ended', {
      turn: this.currentTurn,
      sequenceLength: content.sequence.length,
      toolCallCount: content.toolCalls.size,
      hasThinking: !!content.thinking,
      hasThinkingSignature: !!content.thinkingSignature,
    });

    return content;
  }

  /**
   * Called when a new agent run starts.
   * Clears ALL state (both accumulated and per-turn).
   */
  onAgentStart(): void {
    // Clear accumulated state
    this.accumulatedText = '';
    this.accumulatedThinking = '';
    this.accumulatedThinkingSignature = undefined;
    this.accumulatedToolCalls = [];
    this.accumulatedSequence = [];
    this.lastTurnTokenUsage = undefined;

    // Clear per-turn state
    this.thisTurnSequence = [];
    this.thisTurnToolCalls = new Map();
    this.thisTurnThinking = '';
    this.thisTurnThinkingSignature = undefined;

    // Reset pre-tool flush flag
    this.preToolContentFlushed = false;

    // Reset metadata
    this.currentTurn = 0;
    this.currentTurnStartTime = undefined;

    logger.debug('Agent run started, all tracking cleared');
  }

  /**
   * Called when an agent run ends.
   * Clears ALL state (content is now persisted in EventStore).
   */
  onAgentEnd(): void {
    // Clear accumulated state
    this.accumulatedText = '';
    this.accumulatedThinking = '';
    this.accumulatedThinkingSignature = undefined;
    this.accumulatedToolCalls = [];
    this.accumulatedSequence = [];

    // Clear per-turn state
    this.thisTurnSequence = [];
    this.thisTurnToolCalls = new Map();
    this.thisTurnThinking = '';
    this.thisTurnThinkingSignature = undefined;

    logger.debug('Agent run ended, all tracking cleared');
  }

  // =========================================================================
  // Getters
  // =========================================================================

  /**
   * Get accumulated content for client catch-up.
   * Used when a client resumes into a running session.
   */
  getAccumulatedContent(): AccumulatedContent {
    return {
      text: this.accumulatedText,
      thinking: this.accumulatedThinking,
      thinkingSignature: this.accumulatedThinkingSignature || undefined,
      toolCalls: this.accumulatedToolCalls.map(tc => ({
        toolCallId: tc.toolCallId,
        toolName: tc.toolName,
        arguments: tc.arguments,
        status: tc.status,
        result: tc.result,
        isError: tc.isError,
        startedAt: tc.startedAt ?? new Date().toISOString(),
        completedAt: tc.completedAt,
      })),
      sequence: [...this.accumulatedSequence],
    };
  }

  /**
   * Get per-turn content for building message.assistant.
   */
  getThisTurnContent(): TurnContent {
    return {
      sequence: [...this.thisTurnSequence],
      toolCalls: new Map(this.thisTurnToolCalls),
      thinking: this.thisTurnThinking,
      thinkingSignature: this.thisTurnThinkingSignature || undefined,
    };
  }

  /**
   * Get current turn number.
   */
  getCurrentTurn(): number {
    return this.currentTurn;
  }

  /**
   * Get turn start time (for latency calculation).
   */
  getTurnStartTime(): number | undefined {
    return this.currentTurnStartTime;
  }

  /**
   * Get last turn's token usage.
   */
  getLastTurnTokenUsage(): typeof this.lastTurnTokenUsage {
    return this.lastTurnTokenUsage;
  }

  /**
   * Check if there's any accumulated content (for catch-up).
   */
  hasAccumulatedContent(): boolean {
    return this.accumulatedText.length > 0 || this.accumulatedThinking.length > 0 || this.accumulatedToolCalls.length > 0;
  }

  /**
   * Check if this turn has any content.
   */
  hasThisTurnContent(): boolean {
    return this.thisTurnSequence.length > 0 || this.thisTurnThinking.length > 0;
  }

  // =========================================================================
  // Pre-Tool Content Flush (for Linear Event Ordering)
  // =========================================================================

  /**
   * Check if pre-tool content has been flushed this turn.
   * Used to determine if turn_end should create message.assistant.
   */
  hasPreToolContentFlushed(): boolean {
    return this.preToolContentFlushed;
  }

  /**
   * Get content accumulated BEFORE first tool execution for flushing.
   * Called at first tool_execution_start to emit message.assistant BEFORE tool.call.
   *
   * This ensures linear event order:
   * message.assistant (with tool_use) → tool.call → tool.result
   *
   * Returns content blocks (text + tool_use) or null if nothing to flush.
   * Marks content as flushed to avoid duplicate emission at turn_end.
   */
  flushPreToolContent(): Array<{
    type: 'text' | 'tool_use' | 'thinking';
    text?: string;
    thinking?: string;
    signature?: string;
    id?: string;
    name?: string;
    input?: Record<string, unknown>;
  }> | null {
    // Already flushed this turn - nothing to do
    if (this.preToolContentFlushed) {
      return null;
    }

    // Check if we have any content to flush (thinking OR sequence content)
    if (!this.thisTurnThinking && this.thisTurnSequence.length === 0) {
      return null;
    }

    // Build content blocks from current turn sequence
    const content: Array<{
      type: 'text' | 'tool_use' | 'thinking';
      text?: string;
      thinking?: string;
      signature?: string;
      id?: string;
      name?: string;
      input?: Record<string, unknown>;
    }> = [];

    // CRITICAL: Include thinking block FIRST with signature - API requires it
    // Thinking blocks must be at the start of assistant content per Anthropic API convention
    if (this.thisTurnThinking) {
      content.push({
        type: 'thinking',
        thinking: this.thisTurnThinking,
        ...(this.thisTurnThinkingSignature && { signature: this.thisTurnThinkingSignature }),
      });
    }

    // Then add text and tool_use blocks
    for (const item of this.thisTurnSequence) {
      if (item.type === 'text' && item.text) {
        content.push({ type: 'text', text: item.text });
      } else if (item.type === 'tool_ref') {
        const toolCall = this.thisTurnToolCalls.get(item.toolCallId);
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

    // Mark as flushed even if no content (prevents multiple flush attempts)
    this.preToolContentFlushed = true;

    if (content.length === 0) {
      return null;
    }

    logger.debug('Flushed pre-tool content', {
      turn: this.currentTurn,
      contentBlocks: content.length,
      hasThinking: !!this.thisTurnThinking,
      hasSignature: !!this.thisTurnThinkingSignature,
    });

    return content;
  }

  // =========================================================================
  // Interrupted Content Building
  // =========================================================================

  /**
   * Build content blocks for persisting an interrupted session.
   * Reconstructs assistant content and tool results from accumulated state.
   * Includes full _meta information for UI display (status, interrupted, durationMs).
   *
   * Returns:
   * - assistantContent: Content blocks for message.assistant (text + tool_use with _meta)
   * - toolResultContent: Content blocks for tool.result events (with _meta)
   */
  buildInterruptedContent(): InterruptedContent {
    const assistantContent: InterruptedContent['assistantContent'] = [];
    const toolResultContent: InterruptedContent['toolResultContent'] = [];
    const toolCallMap = new Map<string, ToolCallData>();

    // Build map of all tool calls for quick lookup
    for (const tc of this.accumulatedToolCalls) {
      toolCallMap.set(tc.toolCallId, tc);
    }

    /**
     * Helper to calculate duration in milliseconds from timestamps.
     */
    const calculateDurationMs = (tc: ToolCallData): number | undefined => {
      if (tc.completedAt && tc.startedAt) {
        return new Date(tc.completedAt).getTime() - new Date(tc.startedAt).getTime();
      }
      return undefined;
    };

    /**
     * Helper to add tool_use and tool_result blocks for a tool call.
     * Handles both completed and interrupted tools with proper _meta.
     */
    const addToolCallBlocks = (tc: ToolCallData): void => {
      const durationMs = calculateDurationMs(tc);
      const isInterrupted = tc.status === 'running' || tc.status === 'pending';

      // Add tool_use block with status metadata
      // Mark interrupted tools so iOS can show red X
      assistantContent.push({
        type: 'tool_use',
        id: tc.toolCallId,
        name: tc.toolName,
        input: tc.arguments,
        _meta: {
          status: tc.status,
          interrupted: isInterrupted,
          durationMs,
        },
      });

      // Add tool_result for completed/error tools
      // This ensures results are visible when session is restored
      if (tc.status === 'completed' || tc.status === 'error') {
        toolResultContent.push({
          type: 'tool_result',
          tool_use_id: tc.toolCallId,
          content: tc.result ?? (tc.isError ? 'Error' : '(no output)'),
          is_error: tc.isError ?? false,
          _meta: {
            durationMs,
            toolName: tc.toolName,
          },
        });
      } else if (isInterrupted) {
        // Add interrupted tool_result so the UI shows "interrupted" message
        toolResultContent.push({
          type: 'tool_result',
          tool_use_id: tc.toolCallId,
          content: 'Command interrupted (no output captured)',
          is_error: false,
          _meta: {
            interrupted: true,
            durationMs,
            toolName: tc.toolName,
          },
        });
      }
    };

    // Add thinking content first (Anthropic API puts thinking before text/tools)
    // IMPORTANT: Must include signature - API requires it when sending thinking back
    if (this.accumulatedThinking) {
      assistantContent.push({
        type: 'thinking',
        thinking: this.accumulatedThinking,
        ...(this.accumulatedThinkingSignature && { signature: this.accumulatedThinkingSignature }),
      });
    }

    // Build content from sequence to preserve interleaving order
    if (this.accumulatedSequence.length > 0) {
      for (const item of this.accumulatedSequence) {
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
      // This handles edge cases where sequence wasn't populated
      if (this.accumulatedText) {
        assistantContent.push({ type: 'text', text: this.accumulatedText });
      }

      for (const tc of this.accumulatedToolCalls) {
        addToolCallBlocks(tc);
      }
    }

    logger.debug('Built interrupted content', {
      assistantBlocks: assistantContent.length,
      toolResultBlocks: toolResultContent.length,
      usedSequence: this.accumulatedSequence.length > 0,
    });

    return { assistantContent, toolResultContent };
  }
}
