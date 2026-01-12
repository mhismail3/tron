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
import { createLogger, type CurrentTurnToolCall } from '@tron/core';

const logger = createLogger('turn-content-tracker');

// =============================================================================
// Types
// =============================================================================

/** Content sequence item - either text or a reference to a tool call */
export type ContentSequenceItem =
  | { type: 'text'; text: string }
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
  toolCalls: CurrentTurnToolCall[];
  sequence: ContentSequenceItem[];
}

/** Per-turn content for building message.assistant */
export interface TurnContent {
  sequence: ContentSequenceItem[];
  toolCalls: Map<string, ToolCallData>;
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
    type: 'text' | 'tool_use';
    text?: string;
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
  private accumulatedToolCalls: ToolCallData[] = [];
  private accumulatedSequence: ContentSequenceItem[] = [];

  // =========================================================================
  // Per-turn state (cleared after each message.assistant)
  // =========================================================================
  private thisTurnSequence: ContentSequenceItem[] = [];
  private thisTurnToolCalls: Map<string, ToolCallData> = new Map();

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
   * Record a tool call starting.
   * Updates both accumulated and per-turn tracking.
   */
  startToolCall(
    toolCallId: string,
    toolName: string,
    args: Record<string, unknown>,
    timestamp: string
  ): void {
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
    };

    // Clear per-turn tracking (accumulated persists for catch-up)
    this.thisTurnSequence = [];
    this.thisTurnToolCalls = new Map();

    logger.debug('Turn ended', {
      turn: this.currentTurn,
      sequenceLength: content.sequence.length,
      toolCallCount: content.toolCalls.size,
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
    this.accumulatedToolCalls = [];
    this.accumulatedSequence = [];
    this.lastTurnTokenUsage = undefined;

    // Clear per-turn state
    this.thisTurnSequence = [];
    this.thisTurnToolCalls = new Map();

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
    this.accumulatedToolCalls = [];
    this.accumulatedSequence = [];

    // Clear per-turn state
    this.thisTurnSequence = [];
    this.thisTurnToolCalls = new Map();

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
    return this.accumulatedText.length > 0 || this.accumulatedToolCalls.length > 0;
  }

  /**
   * Check if this turn has any content.
   */
  hasThisTurnContent(): boolean {
    return this.thisTurnSequence.length > 0;
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

    // Build content from sequence to preserve interleaving order
    if (this.accumulatedSequence.length > 0) {
      for (const item of this.accumulatedSequence) {
        if (item.type === 'text' && item.text) {
          assistantContent.push({ type: 'text', text: item.text });
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
