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
import { createLogger } from '@infrastructure/logging/index.js';
import type { CurrentTurnToolCall } from '@interface/rpc/types.js';
import type { ProviderType } from '@core/types/messages.js';
import {
  normalizeTokens,
  type TokenSource,
  type TokenRecord,
  type TokenMeta,
  type ProviderType as TokenProviderType,
} from '@infrastructure/tokens/index.js';
import {
  buildPreToolContentBlocks,
  buildInterruptedContentBlocks,
  buildToolResultBlock,
  type ContentSequenceItem,
  type ToolCallData,
  type ToolUseMeta,
  type ToolResultMeta,
} from './content-block-builder.js';

const logger = createLogger('turn-content-tracker');

// Export TokenRecord as the canonical token type (replaces NormalizedTokenUsage)
export type { TokenRecord } from '@infrastructure/tokens/index.js';

// Re-export types from content-block-builder
export type { ContentSequenceItem, ToolCallData, ToolUseMeta, ToolResultMeta } from './content-block-builder.js';

// =============================================================================
// Types
// =============================================================================

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

  // =========================================================================
  // Token Tracking State
  //
  // Uses the unified token module from @infrastructure/tokens for normalization.
  // Maintains provider type and context baseline for accurate delta calculation.
  // =========================================================================
  private currentProviderType: TokenProviderType = 'anthropic';
  private previousContextBaseline: number = 0;
  private lastTokenRecord: TokenRecord | undefined;
  private lastRawTokenUsage: {
    inputTokens: number;
    outputTokens: number;
    cacheReadTokens?: number;
    cacheCreationTokens?: number;
  } | undefined;

  // =========================================================================
  // Provider Type Management
  // =========================================================================

  /**
   * Set the current provider type (called when model changes).
   * Different providers report inputTokens differently and require
   * different normalization strategies.
   *
   * IMPORTANT: Changing provider resets the context baseline because
   * different providers interpret inputTokens differently.
   *
   * @param type - The provider type ('anthropic' | 'openai' | 'openai-codex' | 'google')
   */
  setProviderType(type: ProviderType): void {
    if (this.currentProviderType !== type) {
      logger.debug('Provider type changed', {
        from: this.currentProviderType,
        to: type,
      });
      this.currentProviderType = type as TokenProviderType;
      // Reset baseline when provider changes (context interpretation changes)
      this.previousContextBaseline = 0;
    }
  }

  /**
   * Get the current provider type.
   */
  getProviderType(): ProviderType {
    return this.currentProviderType;
  }

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

    // Clear per-turn token data (baseline persists for delta calculation)
    this.lastTokenRecord = undefined;
    this.lastRawTokenUsage = undefined;

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
   * Set token usage from API response EARLY (before tool execution).
   *
   * This is called when the response_complete event fires, which happens
   * immediately after LLM streaming completes but BEFORE any tools execute.
   * This allows token data to be included on message.assistant events even
   * for tool-using turns.
   *
   * ## Why This Exists
   *
   * Previously, token usage was only processed in onTurnEnd(), which happens
   * AFTER all tools complete. This meant pre-tool message.assistant events
   * (created for tool-using turns) didn't have token data.
   *
   * Now, token data is captured immediately when available, enabling:
   * - message.assistant events to ALWAYS include tokenRecord
   * - iOS to read token data directly without correlating with stream.turn_end
   * - Consistent token display for both tool and non-tool turns
   *
   * @param tokenUsage - Raw token usage from the provider API response
   * @param sessionId - Session ID for the token record metadata
   */
  setResponseTokenUsage(
    tokenUsage: {
      inputTokens: number;
      outputTokens: number;
      cacheReadTokens?: number;
      cacheCreationTokens?: number;
      cacheCreation5mTokens?: number;
      cacheCreation1hTokens?: number;
    },
    sessionId: string = ''
  ): void {
    // Store raw usage
    this.lastRawTokenUsage = tokenUsage;

    // Create TokenSource from raw usage
    const timestamp = new Date().toISOString();
    const source: TokenSource = {
      provider: this.currentProviderType,
      timestamp,
      rawInputTokens: tokenUsage.inputTokens,
      rawOutputTokens: tokenUsage.outputTokens,
      rawCacheReadTokens: tokenUsage.cacheReadTokens ?? 0,
      rawCacheCreationTokens: tokenUsage.cacheCreationTokens ?? 0,
      rawCacheCreation5mTokens: tokenUsage.cacheCreation5mTokens ?? 0,
      rawCacheCreation1hTokens: tokenUsage.cacheCreation1hTokens ?? 0,
    };

    // Create metadata
    const meta: TokenMeta = {
      turn: this.currentTurn,
      sessionId,
      extractedAt: timestamp,
      normalizedAt: '', // Will be set by normalizeTokens
    };

    // Normalize using the unified token module
    this.lastTokenRecord = normalizeTokens(source, this.previousContextBaseline, meta);

    // Update baseline for next recording
    this.previousContextBaseline = this.lastTokenRecord.computed.contextWindowTokens;

    logger.debug('Token usage set from response_complete', {
      turn: this.currentTurn,
      providerType: this.currentProviderType,
      rawInputTokens: tokenUsage.inputTokens,
      rawOutputTokens: tokenUsage.outputTokens,
      rawCacheReadTokens: tokenUsage.cacheReadTokens,
      rawCacheCreationTokens: tokenUsage.cacheCreationTokens,
      rawCacheCreation5mTokens: tokenUsage.cacheCreation5mTokens,
      rawCacheCreation1hTokens: tokenUsage.cacheCreation1hTokens,
      newInputTokens: this.lastTokenRecord.computed.newInputTokens,
      contextWindowTokens: this.lastTokenRecord.computed.contextWindowTokens,
      baseline: this.previousContextBaseline,
    });
  }

  /**
   * Called at the end of each turn.
   * Returns per-turn content for message.assistant creation.
   *
   * REQUIRES: setResponseTokenUsage() must be called before this method
   * to ensure normalizedUsage is available for message.assistant events.
   *
   * @returns Per-turn content for message.assistant creation
   */
  onTurnEnd(): TurnContent {
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
   * Clears content tracking state (both accumulated and per-turn).
   *
   * IMPORTANT: Does NOT reset previousContextBaseline!
   * The token baseline persists across agent runs within a session to maintain
   * accurate delta calculations. It only resets when:
   * 1. Provider type changes (handled by setProviderType())
   * 2. Session first starts (initialized to 0 in constructor)
   */
  onAgentStart(): void {
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

    // Reset pre-tool flush flag
    this.preToolContentFlushed = false;

    // Reset metadata
    this.currentTurn = 0;
    this.currentTurnStartTime = undefined;

    // Clear per-turn token data (baseline persists for delta calculation)
    this.lastTokenRecord = undefined;
    this.lastRawTokenUsage = undefined;
    // NOTE: previousContextBaseline is intentionally NOT reset
    // NOTE: currentProviderType is intentionally NOT reset

    logger.debug('Agent run started, content tracking cleared', {
      contextBaseline: this.previousContextBaseline,
      providerType: this.currentProviderType,
    });
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
   * Get last turn's raw token usage.
   */
  getLastTurnTokenUsage(): {
    inputTokens: number;
    outputTokens: number;
    cacheReadTokens?: number;
    cacheCreationTokens?: number;
  } | undefined {
    return this.lastRawTokenUsage;
  }

  /**
   * Get last turn's token record.
   * Contains source (raw provider values), computed (normalized values), and metadata.
   */
  getLastTokenRecord(): TokenRecord | undefined {
    return this.lastTokenRecord;
  }

  /**
   * Get the current context baseline size.
   * Used for debugging and verification.
   */
  getContextBaseline(): number {
    return this.previousContextBaseline;
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
    const result = buildPreToolContentBlocks(
      this.thisTurnThinking,
      this.thisTurnThinkingSignature,
      this.thisTurnSequence,
      this.thisTurnToolCalls,
      this.preToolContentFlushed
    );

    // Mark as flushed (even if no content - prevents multiple flush attempts)
    this.preToolContentFlushed = true;

    if (result) {
      logger.debug('Flushed pre-tool content', {
        turn: this.currentTurn,
        contentBlocks: result.length,
        hasThinking: !!this.thisTurnThinking,
        hasSignature: !!this.thisTurnThinkingSignature,
      });
    }

    return result;
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
    // Delegate to extracted builder function
    const result = buildInterruptedContentBlocks(
      this.accumulatedThinking,
      this.accumulatedThinkingSignature,
      this.accumulatedSequence,
      this.accumulatedToolCalls,
      this.accumulatedText
    );

    logger.debug('Built interrupted content', {
      assistantBlocks: result.assistantContent.length,
      toolResultBlocks: result.toolResultContent.length,
      usedSequence: this.accumulatedSequence.length > 0,
    });

    return result;
  }

  /**
   * Build content blocks for persisting an interrupted session using ONLY the current turn.
   *
   * Unlike buildInterruptedContent() which uses accumulated state across ALL turns,
   * this method only persists content from the current turn that hasn't already been
   * persisted by the normal event handlers. This prevents duplicate events when
   * a session is interrupted after multiple agentic turns.
   *
   * Logic:
   * - If preToolContentFlushed: message.assistant was already persisted → assistantContent is empty
   * - If !preToolContentFlushed: build assistantContent from per-turn state
   * - toolResultContent: only include tools with status !== 'completed' && status !== 'error'
   *   (completed/error tools already have tool.result events from the normal handler)
   */
  buildCurrentTurnInterruptedContent(): InterruptedContent {
    if (this.preToolContentFlushed) {
      // message.assistant already persisted — only persist tool results for incomplete tools
      const incompleteResults: InterruptedContent['toolResultContent'] = [];
      for (const [, tc] of this.thisTurnToolCalls) {
        if (tc.status !== 'completed' && tc.status !== 'error') {
          incompleteResults.push(buildToolResultBlock(tc, true));
        }
      }
      return { assistantContent: [], toolResultContent: incompleteResults };
    }

    // Pre-tool content NOT flushed — need to persist both message.assistant and tool results
    const toolCallsArray = Array.from(this.thisTurnToolCalls.values());
    const result = buildInterruptedContentBlocks(
      this.thisTurnThinking,
      this.thisTurnThinkingSignature,
      this.thisTurnSequence,
      toolCallsArray
    );

    // Filter out tool results for completed/error tools (they already have tool.result events)
    result.toolResultContent = result.toolResultContent.filter(tr => {
      const tc = this.thisTurnToolCalls.get(tr.tool_use_id);
      return tc && tc.status !== 'completed' && tc.status !== 'error';
    });

    logger.debug('Built current-turn interrupted content', {
      assistantBlocks: result.assistantContent.length,
      toolResultBlocks: result.toolResultContent.length,
      turn: this.currentTurn,
      preToolFlushed: this.preToolContentFlushed,
    });

    return result;
  }
}
