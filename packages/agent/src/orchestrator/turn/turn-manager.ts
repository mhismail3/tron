/**
 * @fileoverview TurnManager - Turn Lifecycle Management
 *
 * Provides a clean interface for managing agent turn lifecycle.
 * Wraps TurnContentTracker and adds content block building for message.assistant.
 *
 * ## Key Responsibilities
 *
 * 1. Turn lifecycle management (startTurn, endTurn)
 * 2. Content accumulation (text deltas, tool calls)
 * 3. Building message.assistant content blocks at turn end
 * 4. Building interrupted content for persistence
 * 5. Client catch-up via accumulated content
 *
 * ## Usage
 *
 * ```typescript
 * const turnManager = createTurnManager();
 *
 * turnManager.onAgentStart();
 *
 * turnManager.startTurn(1);
 * turnManager.addTextDelta('Let me help');
 * turnManager.startToolCall('tc_1', 'Read', { file_path: '/test.ts' });
 * turnManager.endToolCall('tc_1', 'file contents', false);
 * turnManager.addTextDelta('I see the file');
 *
 * const result = turnManager.endTurn();
 * // result.content = [text, tool_use, text]
 * // result.toolResults = [tool_result]
 *
 * turnManager.onAgentEnd();
 * ```
 */
// Direct imports to avoid circular dependencies through index.js
import { createLogger } from '../../logging/index.js';
import type { TextContent, ThinkingContent } from '../../types/content.js';
import type {
  ApiToolUseBlock,
  ApiToolResultBlock,
  TokenUsage as CoreTokenUsage,
} from '../../types/messages.js';
import type { ProviderType } from '../../types/messages.js';
import {
  TurnContentTracker,
  type AccumulatedContent,
  type InterruptedContent,
  type TurnContent,
  type NormalizedTokenUsage,
} from './turn-content-tracker.js';

const logger = createLogger('turn-manager');

// =============================================================================
// Types (re-exported from @tron/core with aliases for backward compatibility)
// =============================================================================

/**
 * Token usage information.
 * Re-exported from @tron/core for backward compatibility.
 */
export type TokenUsage = CoreTokenUsage;

/**
 * Text content block for message.assistant.
 * Alias to TextContent from @tron/core.
 */
export type TextContentBlock = TextContent;

/**
 * Thinking content block for message.assistant.
 * Alias to ThinkingContent from @tron/core.
 */
export type ThinkingContentBlock = ThinkingContent;

/**
 * Tool use content block in API format (uses 'input' not 'arguments').
 * Alias to ApiToolUseBlock from @tron/core.
 */
export type ToolUseContentBlock = ApiToolUseBlock;

/**
 * Union of all assistant content block types.
 */
export type AssistantContentBlock = TextContentBlock | ThinkingContentBlock | ToolUseContentBlock;

/**
 * Tool result block in API format.
 * Extends ApiToolResultBlock to require is_error (not optional).
 */
export interface ToolResultBlock extends Omit<ApiToolResultBlock, 'is_error'> {
  is_error: boolean;
}

/** Result from ending a turn */
export interface EndTurnResult {
  /** Turn number */
  turn: number;
  /** Content blocks for message.assistant */
  content: AssistantContentBlock[];
  /** Tool results for persisting */
  toolResults: ToolResultBlock[];
  /** Token usage if provided */
  tokenUsage?: TokenUsage;
  /**
   * Normalized token usage with semantic clarity for different UI components.
   * Handles provider semantic differences (Anthropic vs OpenAI/Codex/Gemini).
   */
  normalizedUsage?: NormalizedTokenUsage;
}

// =============================================================================
// TurnManager Class
// =============================================================================

/**
 * Manages turn lifecycle and content accumulation.
 *
 * Each session should have its own TurnManager instance.
 */
export class TurnManager {
  private readonly tracker: TurnContentTracker;

  constructor() {
    this.tracker = new TurnContentTracker();
  }

  // ===========================================================================
  // Provider Type Management
  // ===========================================================================

  /**
   * Set the current provider type for token normalization.
   * Different providers report inputTokens differently and require
   * different normalization strategies.
   *
   * @param type - The provider type ('anthropic' | 'openai' | 'openai-codex' | 'google')
   */
  setProviderType(type: ProviderType): void {
    this.tracker.setProviderType(type);
  }

  /**
   * Get the current provider type.
   */
  getProviderType(): ProviderType {
    return this.tracker.getProviderType();
  }

  // ===========================================================================
  // Turn Lifecycle
  // ===========================================================================

  /**
   * Start a new turn.
   * Clears per-turn content from previous turn.
   */
  startTurn(turn: number): void {
    this.tracker.onTurnStart(turn);
  }

  /**
   * Set token usage from API response EARLY (before tool execution).
   *
   * This should be called when the response_complete event fires, which happens
   * immediately after LLM streaming completes but BEFORE any tools execute.
   * This allows token data to be included on message.assistant events even
   * for tool-using turns.
   *
   * @param tokenUsage - Raw token usage from the provider API response
   */
  setResponseTokenUsage(tokenUsage: TokenUsage): void {
    this.tracker.setResponseTokenUsage(tokenUsage);
  }

  /**
   * Get the last turn's raw token usage.
   * Available after setResponseTokenUsage() or endTurn() is called.
   */
  getLastTurnTokenUsage(): TokenUsage | undefined {
    return this.tracker.getLastTurnTokenUsage();
  }

  /**
   * Get the last turn's normalized token usage.
   * Provides semantic clarity for UI display.
   */
  getLastNormalizedUsage(): NormalizedTokenUsage | undefined {
    return this.tracker.getLastNormalizedUsage();
  }

  /**
   * End the current turn and get content blocks.
   *
   * REQUIRES: setResponseTokenUsage() must be called before this method.
   *
   * @returns Content blocks, tool results, and normalized usage for persistence
   */
  endTurn(): EndTurnResult {
    const turn = this.tracker.getCurrentTurn();
    const turnContent = this.tracker.onTurnEnd();

    // Get token usage and normalized usage (set by setResponseTokenUsage)
    const tokenUsage = this.tracker.getLastTurnTokenUsage();
    const normalizedUsage = this.tracker.getLastNormalizedUsage();

    // Build content blocks from turn content
    const { content, toolResults } = this.buildContentBlocks(turnContent);

    logger.debug('Turn ended', {
      turn,
      contentBlocks: content.length,
      toolResults: toolResults.length,
      hasNormalizedUsage: !!normalizedUsage,
    });

    return {
      turn,
      content,
      toolResults,
      tokenUsage,
      normalizedUsage,
    };
  }

  /**
   * Get current turn number.
   */
  getCurrentTurn(): number {
    return this.tracker.getCurrentTurn();
  }

  /**
   * Get turn start time (for latency calculation).
   */
  getTurnStartTime(): number | undefined {
    return this.tracker.getTurnStartTime();
  }

  // ===========================================================================
  // Content Accumulation
  // ===========================================================================

  /**
   * Add a text delta to the current turn.
   */
  addTextDelta(text: string): void {
    this.tracker.addTextDelta(text);
  }

  /**
   * Add a thinking delta to the current turn.
   * Thinking content is accumulated separately and prepended to the message.
   */
  addThinkingDelta(thinking: string): void {
    this.tracker.addThinkingDelta(thinking);
  }

  /**
   * Set the signature for the current thinking block.
   * Called when thinking_end event is received.
   * IMPORTANT: API requires signature when sending thinking blocks back.
   */
  setThinkingSignature(signature: string): void {
    this.tracker.setThinkingSignature(signature);
  }

  /**
   * Register ALL tool intents from tool_use_batch event.
   * Called BEFORE any tool execution starts to enable linear event ordering.
   */
  registerToolIntents(
    toolCalls: Array<{ id: string; name: string; arguments: Record<string, unknown> }>
  ): void {
    this.tracker.registerToolIntents(toolCalls);
  }

  /**
   * Start tracking a tool call.
   */
  startToolCall(
    toolCallId: string,
    toolName: string,
    args: Record<string, unknown>
  ): void {
    this.tracker.startToolCall(
      toolCallId,
      toolName,
      args,
      new Date().toISOString()
    );
  }

  /**
   * End tracking a tool call with its result.
   */
  endToolCall(toolCallId: string, result: string, isError: boolean): void {
    this.tracker.endToolCall(
      toolCallId,
      result,
      isError,
      new Date().toISOString()
    );
  }

  // ===========================================================================
  // Interrupted Content
  // ===========================================================================

  /**
   * Build content blocks for an interrupted session.
   * Used when persisting state before deactivation.
   */
  buildInterruptedContent(): InterruptedContent {
    return this.tracker.buildInterruptedContent();
  }

  // ===========================================================================
  // Pre-Tool Content Flush (for Linear Event Ordering)
  // ===========================================================================

  /**
   * Check if pre-tool content has been flushed this turn.
   * Used to determine if turn_end should create message.assistant.
   */
  hasPreToolContentFlushed(): boolean {
    return this.tracker.hasPreToolContentFlushed();
  }

  /**
   * Flush accumulated content BEFORE first tool execution.
   * Called at first tool_execution_start to emit message.assistant before tool.call.
   *
   * Returns content blocks (text + tool_use) or null if nothing to flush.
   */
  flushPreToolContent(): AssistantContentBlock[] | null {
    const content = this.tracker.flushPreToolContent();
    if (!content) {
      return null;
    }

    // Convert to AssistantContentBlock type
    return content.map((block) => {
      if (block.type === 'text') {
        return { type: 'text' as const, text: block.text! };
      } else if (block.type === 'thinking') {
        // CRITICAL: Include signature when flushing thinking blocks
        // The signature is required by Anthropic API when sending thinking back
        return {
          type: 'thinking' as const,
          thinking: block.thinking!,
          ...(block.signature && { signature: block.signature }),
        };
      } else {
        return {
          type: 'tool_use' as const,
          id: block.id!,
          name: block.name!,
          input: block.input!,
        };
      }
    });
  }

  // ===========================================================================
  // Accumulated Content (for client catch-up)
  // ===========================================================================

  /**
   * Get accumulated content for client catch-up.
   * Used when a client resumes into a running session.
   */
  getAccumulatedContent(): AccumulatedContent {
    return this.tracker.getAccumulatedContent();
  }

  /**
   * Check if there's accumulated content for catch-up.
   */
  hasAccumulatedContent(): boolean {
    return this.tracker.hasAccumulatedContent();
  }

  // ===========================================================================
  // Agent Lifecycle
  // ===========================================================================

  /**
   * Called when a new agent run starts.
   * Clears all state.
   */
  onAgentStart(): void {
    this.tracker.onAgentStart();
  }

  /**
   * Called when an agent run ends.
   * Clears all state (content is now persisted).
   */
  onAgentEnd(): void {
    this.tracker.onAgentEnd();
  }

  // ===========================================================================
  // Private Helpers
  // ===========================================================================

  /**
   * Build assistant content blocks and tool results from turn content.
   */
  private buildContentBlocks(turnContent: TurnContent): {
    content: AssistantContentBlock[];
    toolResults: ToolResultBlock[];
  } {
    const content: AssistantContentBlock[] = [];
    const toolResults: ToolResultBlock[] = [];

    // Thinking content comes first (Anthropic API convention)
    // This ensures proper ordering in persisted message.assistant events
    // IMPORTANT: Must include signature - API requires it when sending thinking back
    if (turnContent.thinking) {
      content.push({
        type: 'thinking',
        thinking: turnContent.thinking,
        ...(turnContent.thinkingSignature && { signature: turnContent.thinkingSignature }),
      });
    }

    // Build content from sequence to preserve interleaving
    for (const item of turnContent.sequence) {
      if (item.type === 'text' && item.text) {
        content.push({ type: 'text', text: item.text });
      } else if (item.type === 'thinking' && item.thinking) {
        // Thinking from sequence (shouldn't happen with current design, but handle it)
        content.push({ type: 'thinking', thinking: item.thinking });
      } else if (item.type === 'tool_ref') {
        const toolCall = turnContent.toolCalls.get(item.toolCallId);
        if (toolCall) {
          // Add tool_use content block
          content.push({
            type: 'tool_use',
            id: toolCall.toolCallId,
            name: toolCall.toolName,
            input: toolCall.arguments,
          });

          // Add tool_result if completed
          if (toolCall.status === 'completed' || toolCall.status === 'error') {
            toolResults.push({
              type: 'tool_result',
              tool_use_id: toolCall.toolCallId,
              content: toolCall.result ?? '',
              is_error: toolCall.isError ?? false,
            });
          }
        }
      }
    }

    return { content, toolResults };
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a TurnManager instance.
 */
export function createTurnManager(): TurnManager {
  return new TurnManager();
}

// =============================================================================
// Re-exports
// =============================================================================

export type { AccumulatedContent, InterruptedContent, NormalizedTokenUsage } from './turn-content-tracker.js';
