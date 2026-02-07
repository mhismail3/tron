/**
 * @fileoverview Tool Event Handler
 *
 * Handles tool execution events:
 * - tool_use_batch: Batch of tool calls about to execute
 * - tool_execution_start: Individual tool execution starts
 * - tool_execution_end: Individual tool execution completes
 *
 * Uses EventContext for automatic metadata injection (sessionId, timestamp, runId).
 *
 * ## Content Storage
 *
 * Large tool results are stored in blob storage before truncation.
 * The truncation message includes the blob ID so the agent can
 * retrieve full content via the Introspect tool if needed.
 */

import { createLogger } from '@infrastructure/logging/index.js';
import type { TronEvent } from '@core/types/index.js';
import type { EventType } from '@infrastructure/events/index.js';
import { normalizeContentBlocks } from '@core/utils/index.js';
import type { UIRenderHandler, ToolStartArgs, ToolEndDetails } from '../../ui-render-handler.js';
import type { EventContext } from '../event-context.js';
import { BLOB_STORAGE_THRESHOLD, MAX_TOOL_RESULT_SIZE } from '../constants.js';

const logger = createLogger('tool-event-handler');

// =============================================================================
// Types
// =============================================================================

/**
 * Simple blob store interface - just store and get content.
 */
export interface BlobStore {
  store(content: string | Buffer, mimeType?: string): string;
  getContent(blobId: string): string | null;
}

/**
 * Dependencies for ToolEventHandler.
 */
export interface ToolEventHandlerDeps {
  /** UI render handler for RenderAppUI tool */
  uiRenderHandler: UIRenderHandler;
}

// =============================================================================
// Helpers
// =============================================================================

/**
 * Truncate a string with a notice about where to find full content.
 */
function truncateWithBlobRef(content: string, maxLength: number, blobId: string): string {
  if (content.length <= maxLength) return content;

  const truncated = content.slice(0, maxLength);
  const remaining = content.length - maxLength;

  return `${truncated}\n\n... [truncated ${remaining.toLocaleString()} bytes → ${blobId}]\n[Use Remember tool with action "read_blob" and blob_id "${blobId}" to retrieve full content]`;
}

/**
 * Simple truncation without blob reference.
 */
function truncateString(str: string, maxLength: number): string {
  if (str.length <= maxLength) return str;
  const truncated = str.slice(0, maxLength);
  const remaining = str.length - maxLength;
  return `${truncated}\n\n... [truncated ${remaining.toLocaleString()} bytes]`;
}

// =============================================================================
// ToolEventHandler
// =============================================================================

/**
 * Handles tool execution events.
 */
export class ToolEventHandler {
  private blobStore?: BlobStore;

  constructor(private deps: ToolEventHandlerDeps) {}

  /**
   * Set the blob store for large content storage.
   * Call after EventStore is initialized.
   */
  setBlobStore(blobStore: BlobStore): void {
    this.blobStore = blobStore;
  }

  /**
   * Handle tool_use_batch event.
   * Registers all tool_use intents BEFORE any execution starts.
   */
  handleToolUseBatch(ctx: EventContext, event: TronEvent): void {
    const batchEvent = event as {
      toolCalls?: Array<{
        name: string;
        id: string;
        input?: unknown;
        arguments?: Record<string, unknown>;
      }>;
    };

    if (ctx.active && batchEvent.toolCalls && Array.isArray(batchEvent.toolCalls)) {
      const normalizedToolCalls = batchEvent.toolCalls.map((tc) => ({
        id: tc.id,
        name: tc.name,
        arguments: (tc.arguments ?? tc.input ?? {}) as Record<string, unknown>,
      }));
      ctx.active.sessionContext!.registerToolIntents(normalizedToolCalls);

      logger.debug('Registered tool_use batch', {
        sessionId: ctx.sessionId,
        toolCount: batchEvent.toolCalls.length,
        toolNames: batchEvent.toolCalls.map((tc) => tc.name),
      });
    }
  }

  /**
   * Handle tool_execution_start event.
   * Tracks tool call for resume support and handles linear event ordering.
   */
  handleToolExecutionStart(ctx: EventContext, event: TronEvent): void {
    const toolStartEvent = event as {
      toolCallId: string;
      toolName: string;
      arguments?: Record<string, unknown>;
    };

    if (ctx.active) {
      ctx.active.sessionContext!.startToolCall(
        toolStartEvent.toolCallId,
        toolStartEvent.toolName,
        toolStartEvent.arguments ?? {}
      );

      // Flush accumulated content as message.assistant BEFORE tool.call
      this.flushPreToolContent(ctx);
    }

    ctx.emit('agent.tool_start', {
      toolCallId: toolStartEvent.toolCallId,
      toolName: toolStartEvent.toolName,
      arguments: toolStartEvent.arguments,
    });

    // Delegate RenderAppUI handling
    if (toolStartEvent.toolName === 'RenderAppUI' && toolStartEvent.arguments) {
      this.deps.uiRenderHandler.handleToolStart(
        ctx.sessionId,
        toolStartEvent.toolCallId,
        toolStartEvent.arguments as ToolStartArgs,
        ctx.timestamp,
        ctx.runId
      );
    }

    // Store tool.call event
    ctx.persist('tool.call' as EventType, {
      toolCallId: toolStartEvent.toolCallId,
      name: toolStartEvent.toolName,
      arguments: toolStartEvent.arguments ?? {},
      turn: ctx.active?.sessionContext?.getCurrentTurn() ?? 0,
    });
  }

  /**
   * Handle tool_execution_end event.
   * Updates tool tracking and persists tool.result event.
   */
  handleToolExecutionEnd(ctx: EventContext, event: TronEvent): void {
    const toolEndEvent = event as {
      toolCallId: string;
      toolName: string;
      result: unknown;
      isError?: boolean;
      duration?: number;
    };

    const resultContent = this.extractResultContent(toolEndEvent.result);

    // Update tool call tracking
    if (ctx.active) {
      ctx.active.sessionContext!.endToolCall(
        toolEndEvent.toolCallId,
        resultContent,
        toolEndEvent.isError ?? false
      );
    }

    // Extract details for iOS screenshots etc.
    const resultDetails =
      typeof toolEndEvent.result === 'object' && toolEndEvent.result !== null
        ? (toolEndEvent.result as { details?: unknown }).details
        : undefined;

    ctx.emit('agent.tool_end', {
      toolCallId: toolEndEvent.toolCallId,
      toolName: toolEndEvent.toolName,
      success: !toolEndEvent.isError,
      output: toolEndEvent.isError ? undefined : resultContent,
      error: toolEndEvent.isError ? resultContent : undefined,
      duration: toolEndEvent.duration,
      details: resultDetails,
    });

    // Delegate RenderAppUI handling
    if (toolEndEvent.toolName === 'RenderAppUI') {
      this.deps.uiRenderHandler.handleToolEnd(
        ctx.sessionId,
        toolEndEvent.toolCallId,
        resultContent,
        toolEndEvent.isError ?? false,
        resultDetails as ToolEndDetails | undefined,
        ctx.timestamp,
        ctx.runId
      );
    }

    // Store large results in blob, then truncate with blob reference
    let contentToStore = resultContent;
    let blobId: string | undefined;
    let truncated = false;

    const contentSize = Buffer.byteLength(resultContent, 'utf-8');

    if (contentSize > BLOB_STORAGE_THRESHOLD && this.blobStore) {
      // Store full content in blob
      blobId = this.blobStore.store(resultContent, 'text/plain');

      logger.debug('Stored large tool result in blob', {
        toolCallId: toolEndEvent.toolCallId,
        toolName: toolEndEvent.toolName,
        originalSize: contentSize,
        blobId,
      });

      // Truncate with blob reference
      if (contentSize > MAX_TOOL_RESULT_SIZE) {
        contentToStore = truncateWithBlobRef(resultContent, MAX_TOOL_RESULT_SIZE, blobId);
        truncated = true;
      }
    } else if (contentSize > MAX_TOOL_RESULT_SIZE) {
      // No blob store available, just truncate
      contentToStore = truncateString(resultContent, MAX_TOOL_RESULT_SIZE);
      truncated = true;
    }

    // Persist tool.result event
    ctx.persist(
      'tool.result' as EventType,
      {
        toolCallId: toolEndEvent.toolCallId,
        content: contentToStore,
        isError: toolEndEvent.isError ?? false,
        duration: toolEndEvent.duration,
        truncated,
        blobId,
      },
      (evt) => {
        if (ctx.active?.sessionContext) {
          ctx.active.sessionContext.addMessageEventId(evt.id);
        }
      }
    );
  }

  // ===========================================================================
  // Private Helpers
  // ===========================================================================

  private flushPreToolContent(ctx: EventContext): void {
    if (!ctx.active) return;

    const preToolContent = ctx.active.sessionContext!.flushPreToolContent();
    if (!preToolContent || preToolContent.length === 0) return;

    const normalizedContent = normalizeContentBlocks(preToolContent);
    if (normalizedContent.length === 0) return;

    const turnStartTime = ctx.active.sessionContext!.getTurnStartTime();
    const turnLatency = turnStartTime ? Date.now() - turnStartTime : 0;

    const hasThinking = normalizedContent.some(
      (b) => (b as Record<string, unknown>).type === 'thinking'
    );

    const tokenUsage = ctx.active.sessionContext!.getLastTurnTokenUsage();
    const tokenRecord = ctx.active.sessionContext!.getLastTokenRecord();

    ctx.persist(
      'message.assistant' as EventType,
      {
        content: normalizedContent,
        tokenUsage,
        tokenRecord,
        turn: ctx.active.sessionContext!.getCurrentTurn(),
        model: ctx.active.model,
        stopReason: 'tool_use',
        latency: turnLatency,
        hasThinking,
      },
      (evt) => {
        if (ctx.active?.sessionContext) {
          ctx.active.sessionContext.addMessageEventId(evt.id);
        }
      }
    );

    logger.info('[TOKEN-FLOW] 3a. Pre-tool message.assistant created (tools case)', {
      sessionId: ctx.sessionId,
      turn: ctx.active.sessionContext!.getCurrentTurn(),
      contentBlocks: normalizedContent.length,
      tokenRecord: tokenRecord
        ? {
            source: {
              rawInputTokens: tokenRecord.source.rawInputTokens,
              rawOutputTokens: tokenRecord.source.rawOutputTokens,
              rawCacheReadTokens: tokenRecord.source.rawCacheReadTokens,
            },
            computed: {
              newInputTokens: tokenRecord.computed.newInputTokens,
              contextWindowTokens: tokenRecord.computed.contextWindowTokens,
            },
          }
        : 'MISSING',
    });
  }

  private extractResultContent(result: unknown): string {
    if (typeof result !== 'object' || result === null) {
      return String(result ?? '');
    }

    const typedResult = result as { content?: string | Array<{ type: string; text?: string }> };

    if (typeof typedResult.content === 'string') {
      return typedResult.content;
    }

    if (Array.isArray(typedResult.content)) {
      return typedResult.content
        .filter(
          (block): block is { type: 'text'; text: string } =>
            block.type === 'text' && typeof block.text === 'string'
        )
        .map((block) => block.text)
        .join('\n');
    }

    return JSON.stringify(result);
  }
}

// =============================================================================
// Factory
// =============================================================================

export function createToolEventHandler(deps: ToolEventHandlerDeps): ToolEventHandler {
  return new ToolEventHandler(deps);
}
