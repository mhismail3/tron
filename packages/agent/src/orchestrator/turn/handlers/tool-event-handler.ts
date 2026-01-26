/**
 * @fileoverview Tool Event Handler
 *
 * Handles tool execution events:
 * - tool_use_batch: Batch of tool calls about to execute
 * - tool_execution_start: Individual tool execution starts
 * - tool_execution_end: Individual tool execution completes
 *
 * Extracted from AgentEventHandler to improve modularity and testability.
 */

import { createLogger } from '../../../logging/index.js';
import type { TronEvent } from '../../../types/events.js';
import type { SessionId, EventType, TronSessionEvent } from '../../../events/index.js';
import {
  normalizeContentBlocks,
  truncateString,
  MAX_TOOL_RESULT_SIZE,
} from '../../../utils/content-normalizer.js';
import type { ActiveSession } from '../../types.js';
import type { UIRenderHandler, ToolStartArgs, ToolEndDetails } from '../../ui-render-handler.js';

const logger = createLogger('tool-event-handler');

// =============================================================================
// Types
// =============================================================================

/**
 * Dependencies for ToolEventHandler
 */
export interface ToolEventHandlerDeps {
  /** Get active session by ID */
  getActiveSession: (sessionId: string) => ActiveSession | undefined;
  /** Append event to session (fire-and-forget) */
  appendEventLinearized: (
    sessionId: SessionId,
    type: EventType,
    payload: Record<string, unknown>,
    onCreated?: (event: TronSessionEvent) => void
  ) => void;
  /** Emit event to orchestrator */
  emit: (event: string, data: unknown) => void;
  /** UI render handler for RenderAppUI tool */
  uiRenderHandler: UIRenderHandler;
}

// =============================================================================
// ToolEventHandler
// =============================================================================

/**
 * Handles tool execution events.
 */
export class ToolEventHandler {
  constructor(private deps: ToolEventHandlerDeps) {}

  /**
   * Handle tool_use_batch event.
   * Registers all tool_use intents BEFORE any execution starts.
   * This enables linear event ordering by knowing all tools upfront.
   */
  handleToolUseBatch(
    sessionId: SessionId,
    event: TronEvent
  ): void {
    const active = this.deps.getActiveSession(sessionId);
    const batchEvent = event as {
      toolCalls?: Array<{
        name: string;
        id: string;
        input?: unknown;
        arguments?: Record<string, unknown>;
      }>;
    };

    if (active && batchEvent.toolCalls && Array.isArray(batchEvent.toolCalls)) {
      // Transform tool calls to expected format (input may come as input or arguments)
      const normalizedToolCalls = batchEvent.toolCalls.map((tc) => ({
        id: tc.id,
        name: tc.name,
        arguments: (tc.arguments ?? tc.input ?? {}) as Record<string, unknown>,
      }));
      active.sessionContext!.registerToolIntents(normalizedToolCalls);

      logger.debug('Registered tool_use batch', {
        sessionId,
        toolCount: batchEvent.toolCalls.length,
        toolNames: batchEvent.toolCalls.map((tc) => tc.name),
      });
    }
  }

  /**
   * Handle tool_execution_start event.
   * Tracks tool call for resume support and handles linear event ordering.
   */
  handleToolExecutionStart(
    sessionId: SessionId,
    event: TronEvent,
    timestamp: string
  ): void {
    const active = this.deps.getActiveSession(sessionId);
    const toolStartEvent = event as {
      toolCallId: string;
      toolName: string;
      arguments?: Record<string, unknown>;
    };

    // Track tool call for resume support (across ALL turns)
    if (active) {
      active.sessionContext!.startToolCall(
        toolStartEvent.toolCallId,
        toolStartEvent.toolName,
        toolStartEvent.arguments ?? {}
      );

      // LINEAR EVENT ORDERING: Flush accumulated content as message.assistant BEFORE tool.call
      // This ensures correct order: message.assistant (with tool_use) → tool.call → tool.result
      // The flush only happens once per turn (first tool_execution_start)
      this.flushPreToolContent(sessionId, active);
    }

    this.deps.emit('agent_event', {
      type: 'agent.tool_start',
      sessionId,
      timestamp,
      data: {
        toolCallId: toolStartEvent.toolCallId,
        toolName: toolStartEvent.toolName,
        arguments: toolStartEvent.arguments,
      },
    });

    // Delegate RenderAppUI handling to UIRenderHandler
    if (toolStartEvent.toolName === 'RenderAppUI' && toolStartEvent.arguments) {
      this.deps.uiRenderHandler.handleToolStart(
        sessionId,
        toolStartEvent.toolCallId,
        toolStartEvent.arguments as ToolStartArgs,
        timestamp
      );
    }

    // Store discrete tool.call event (linearized)
    this.deps.appendEventLinearized(
      sessionId,
      'tool.call' as EventType,
      {
        toolCallId: toolStartEvent.toolCallId,
        name: toolStartEvent.toolName,
        arguments: toolStartEvent.arguments ?? {},
        turn: active?.sessionContext?.getCurrentTurn() ?? 0,
      }
    );
  }

  /**
   * Handle tool_execution_end event.
   * Updates tool tracking and persists tool.result event.
   */
  handleToolExecutionEnd(
    sessionId: SessionId,
    event: TronEvent,
    timestamp: string
  ): void {
    const active = this.deps.getActiveSession(sessionId);
    const toolEndEvent = event as {
      toolCallId: string;
      toolName: string;
      result: unknown;
      isError?: boolean;
      duration?: number;
    };

    // Extract text content from TronToolResult
    const resultContent = this.extractResultContent(toolEndEvent.result);

    // Update tool call tracking for resume support (across ALL turns)
    if (active) {
      active.sessionContext!.endToolCall(
        toolEndEvent.toolCallId,
        resultContent,
        toolEndEvent.isError ?? false
      );
    }

    // Extract details from tool result (e.g., full screenshot data for iOS)
    const resultDetails =
      typeof toolEndEvent.result === 'object' && toolEndEvent.result !== null
        ? (toolEndEvent.result as { details?: unknown }).details
        : undefined;

    this.deps.emit('agent_event', {
      type: 'agent.tool_end',
      sessionId,
      timestamp,
      data: {
        toolCallId: toolEndEvent.toolCallId,
        toolName: toolEndEvent.toolName,
        success: !toolEndEvent.isError,
        output: toolEndEvent.isError ? undefined : resultContent,
        error: toolEndEvent.isError ? resultContent : undefined,
        duration: toolEndEvent.duration,
        // Include details for clients that need full binary data (e.g., iOS screenshots)
        // This is NOT persisted to event store to avoid bloating storage
        details: resultDetails,
      },
    });

    // Delegate RenderAppUI handling to UIRenderHandler
    if (toolEndEvent.toolName === 'RenderAppUI') {
      this.deps.uiRenderHandler.handleToolEnd(
        sessionId,
        toolEndEvent.toolCallId,
        resultContent,
        toolEndEvent.isError ?? false,
        resultDetails as ToolEndDetails | undefined,
        timestamp
      );
    }

    // Store discrete tool.result event (linearized)
    this.deps.appendEventLinearized(
      sessionId,
      'tool.result' as EventType,
      {
        toolCallId: toolEndEvent.toolCallId,
        content: truncateString(resultContent, MAX_TOOL_RESULT_SIZE),
        isError: toolEndEvent.isError ?? false,
        duration: toolEndEvent.duration,
        truncated: resultContent.length > MAX_TOOL_RESULT_SIZE,
      },
      (evt) => {
        // Track eventId for context manager message (tool result) via SessionContext
        const currentActive = this.deps.getActiveSession(sessionId);
        if (currentActive?.sessionContext) {
          currentActive.sessionContext.addMessageEventId(evt.id);
        }
      }
    );
  }

  // ===========================================================================
  // Private Helpers
  // ===========================================================================

  /**
   * Flush pre-tool content as message.assistant event.
   * Ensures correct linear event ordering.
   */
  private flushPreToolContent(sessionId: SessionId, active: ActiveSession): void {
    const preToolContent = active.sessionContext!.flushPreToolContent();
    if (!preToolContent || preToolContent.length === 0) {
      return;
    }

    const normalizedContent = normalizeContentBlocks(preToolContent);
    if (normalizedContent.length === 0) {
      return;
    }

    const turnStartTime = active.sessionContext!.getTurnStartTime();
    const turnLatency = turnStartTime ? Date.now() - turnStartTime : 0;

    // Detect if content has thinking blocks
    const hasThinking = normalizedContent.some(
      (b) => (b as Record<string, unknown>).type === 'thinking'
    );

    // Get token usage captured from response_complete
    const tokenUsage = active.sessionContext!.getLastTurnTokenUsage();
    const normalizedUsage = active.sessionContext!.getLastNormalizedUsage();

    this.deps.appendEventLinearized(
      sessionId,
      'message.assistant' as EventType,
      {
        content: normalizedContent,
        tokenUsage,
        normalizedUsage,
        turn: active.sessionContext!.getCurrentTurn(),
        model: active.model,
        stopReason: 'tool_use', // Indicates tools are being called
        latency: turnLatency,
        hasThinking,
      },
      (evt) => {
        // Track eventId for context manager message via SessionContext
        const currentActive = this.deps.getActiveSession(sessionId);
        if (currentActive?.sessionContext) {
          currentActive.sessionContext.addMessageEventId(evt.id);
        }
      }
    );

    logger.info('[TOKEN-FLOW] 3a. Pre-tool message.assistant created (tools case)', {
      sessionId,
      turn: active.sessionContext!.getCurrentTurn(),
      contentBlocks: normalizedContent.length,
      tokenUsage: tokenUsage
        ? {
            inputTokens: tokenUsage.inputTokens,
            outputTokens: tokenUsage.outputTokens,
            cacheRead: tokenUsage.cacheReadTokens ?? 0,
          }
        : 'MISSING',
      normalizedUsage: normalizedUsage
        ? {
            newInputTokens: normalizedUsage.newInputTokens,
            contextWindowTokens: normalizedUsage.contextWindowTokens,
            outputTokens: normalizedUsage.outputTokens,
          }
        : 'MISSING',
    });
  }

  /**
   * Extract text content from TronToolResult.
   * Content can be string OR array of { type: 'text', text } | { type: 'image', ... }
   */
  private extractResultContent(result: unknown): string {
    if (typeof result !== 'object' || result === null) {
      return String(result ?? '');
    }

    const typedResult = result as { content?: string | Array<{ type: string; text?: string }> };

    if (typeof typedResult.content === 'string') {
      return typedResult.content;
    }

    if (Array.isArray(typedResult.content)) {
      // Extract text from content blocks, join with newlines
      return typedResult.content
        .filter(
          (block): block is { type: 'text'; text: string } =>
            block.type === 'text' && typeof block.text === 'string'
        )
        .map((block) => block.text)
        .join('\n');
    }

    // Fallback: stringify the whole result
    return JSON.stringify(result);
  }
}

// =============================================================================
// Factory
// =============================================================================

/**
 * Create a ToolEventHandler instance.
 */
export function createToolEventHandler(deps: ToolEventHandlerDeps): ToolEventHandler {
  return new ToolEventHandler(deps);
}
