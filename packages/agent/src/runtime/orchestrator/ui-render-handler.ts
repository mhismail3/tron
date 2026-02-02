/**
 * @fileoverview UI Render Handler
 *
 * Encapsulates all RenderAppUI tool handling logic extracted from AgentEventHandler.
 * This consolidates the scattered special handling for progressive UI streaming,
 * canvas artifact persistence, and retry/error flows.
 *
 * ## Responsibilities
 *
 * - Track active RenderAppUI tool calls for progressive streaming
 * - Emit ui_render_start, ui_render_chunk, ui_render_complete, ui_render_error, ui_render_retry events
 * - Handle streaming of tool call arguments (toolcall_delta)
 * - Persist canvas artifacts to disk on successful completion
 * - Clean up tracking state when agent ends
 *
 * ## Event Flow
 *
 * 1. toolcall_delta (RenderAppUI) → Extract canvasId → Emit ui_render_start, ui_render_chunk
 * 2. tool_execution_start (RenderAppUI) → Emit ui_render_start (fallback if streaming missed it)
 * 3. tool_execution_end (RenderAppUI) → Emit ui_render_complete/error/retry, persist artifact
 */

import { createLogger } from '@infrastructure/logging/index.js';
import { saveCanvasArtifact } from '@platform/productivity/canvas-store.js';
import type { SessionId } from '@infrastructure/events/types.js';

const logger = createLogger('ui-render-handler');

// =============================================================================
// Types
// =============================================================================

/**
 * Tracking state for an active RenderAppUI tool call.
 */
interface UIRenderState {
  canvasId: string | null;
  accumulatedJson: string;
  startEmitted: boolean;
  runId?: string;
}

/**
 * Event emitter function type.
 */
export type UIRenderEventEmitter = (event: string, data: unknown) => void;

/**
 * Tool arguments from tool_execution_start.
 */
export interface ToolStartArgs {
  canvasId?: string;
  title?: string;
  [key: string]: unknown;
}

/**
 * Tool result details from tool_execution_end.
 */
export interface ToolEndDetails {
  canvasId?: string;
  title?: string;
  ui?: unknown;
  state?: unknown;
  needsRetry?: boolean;
  attempt?: number;
}

// =============================================================================
// UIRenderHandler Class
// =============================================================================

/**
 * Handles all RenderAppUI tool-specific event processing.
 * Extracts this concern from AgentEventHandler to improve maintainability.
 */
export class UIRenderHandler {
  /**
   * Track active RenderAppUI tool calls for progressive streaming.
   * Maps toolCallId to streaming state.
   */
  private activeRenders: Map<string, UIRenderState> = new Map();
  private emit: UIRenderEventEmitter;

  constructor(emit: UIRenderEventEmitter) {
    this.emit = emit;
  }

  /**
   * Handle tool_execution_start for RenderAppUI.
   * Emits ui_render_start if not already emitted from streaming.
   *
   * @param sessionId - The session ID
   * @param toolCallId - The tool call ID
   * @param args - The tool arguments
   * @param timestamp - Event timestamp
   * @param runId - The run ID for event correlation
   */
  handleToolStart(
    sessionId: SessionId,
    toolCallId: string,
    args: ToolStartArgs,
    timestamp: string,
    runId?: string
  ): void {
    const existingRender = this.activeRenders.get(toolCallId);

    // Only emit ui_render_start if streaming didn't already emit it
    if (!existingRender?.startEmitted) {
      this.emit('agent_event', {
        type: 'agent.ui_render_start',
        sessionId,
        timestamp,
        runId,
        data: {
          canvasId: args.canvasId,
          title: args.title,
          toolCallId,
        },
      });

      logger.debug('Emitted ui_render_start (fallback)', {
        sessionId,
        canvasId: args.canvasId,
        toolCallId,
      });
    } else {
      logger.debug('Skipped ui_render_start (already emitted from streaming)', {
        sessionId,
        canvasId: args.canvasId,
        toolCallId,
      });
    }
  }

  /**
   * Handle tool_execution_end for RenderAppUI.
   * Emits ui_render_complete, ui_render_error, or ui_render_retry based on result.
   *
   * @param sessionId - The session ID
   * @param toolCallId - The tool call ID
   * @param resultContent - The result content string
   * @param isError - Whether the tool execution failed
   * @param details - The result details object
   * @param timestamp - Event timestamp
   * @param runId - The run ID for event correlation
   */
  handleToolEnd(
    sessionId: SessionId,
    toolCallId: string,
    resultContent: string,
    isError: boolean,
    details: ToolEndDetails | undefined,
    timestamp: string,
    runId?: string
  ): void {
    // Get tracking state before cleanup (may have canvasId from streaming)
    const renderState = this.activeRenders.get(toolCallId);
    const canvasIdFromStreaming = renderState?.canvasId;

    // Clean up streaming state
    this.activeRenders.delete(toolCallId);

    const canvasId = details?.canvasId ?? canvasIdFromStreaming;

    // Check if this is a retry case (validation failed, turn continues)
    if (details?.needsRetry && canvasId) {
      this.emitRetry(sessionId, canvasId, details.attempt ?? 1, resultContent, timestamp, runId);
      // Don't emit complete or error - turn continues for retry
      return;
    }

    if (isError) {
      this.emitError(sessionId, canvasId, resultContent, timestamp, runId);
      return;
    }

    // Success case
    if (canvasId && details?.ui) {
      this.emitComplete(sessionId, canvasId, details, timestamp, runId);
    }
  }

  /**
   * Handle toolcall_delta for RenderAppUI progressive streaming.
   * Accumulates JSON chunks and emits ui_render_chunk events.
   *
   * @param sessionId - The session ID
   * @param toolCallId - The tool call ID
   * @param toolName - The tool name (may be undefined for early deltas)
   * @param argumentsDelta - The JSON chunk
   * @param timestamp - Event timestamp
   * @param runId - The run ID for event correlation
   * @returns true if this was a RenderAppUI delta that was handled
   */
  handleToolCallDelta(
    sessionId: SessionId,
    toolCallId: string,
    toolName: string | undefined,
    argumentsDelta: string,
    timestamp: string,
    runId?: string
  ): boolean {
    logger.debug('Received toolcall_delta', {
      sessionId,
      toolCallId,
      toolName,
      deltaLength: argumentsDelta.length,
    });

    // Check if we're already tracking this tool call
    const existingRender = this.activeRenders.get(toolCallId);

    // If not tracking and we know the tool name, check if it's RenderAppUI
    if (!existingRender) {
      // Only start tracking RenderAppUI calls
      if (toolName !== 'RenderAppUI') {
        logger.debug('Skipping non-RenderAppUI delta', {
          sessionId,
          toolCallId,
          toolName,
        });
        return false;
      }

      // Initialize tracking for this RenderAppUI call
      logger.info('Started tracking RenderAppUI streaming', {
        sessionId,
        toolCallId,
      });
      this.activeRenders.set(toolCallId, {
        canvasId: null,
        accumulatedJson: '',
        startEmitted: false,
        runId,
      });
    }

    // Get tracking state (now guaranteed to exist for RenderAppUI calls)
    const render = this.activeRenders.get(toolCallId);
    if (!render) {
      return false; // Safety check
    }

    // Accumulate the JSON chunk
    render.accumulatedJson += argumentsDelta;

    // Try to extract canvasId if we don't have it yet
    if (!render.canvasId) {
      const match = render.accumulatedJson.match(/"canvasId"\s*:\s*"([^"]+)"/);
      if (match && match[1]) {
        render.canvasId = match[1];

        // Emit ui_render_start now that we have canvasId
        this.emit('agent_event', {
          type: 'agent.ui_render_start',
          sessionId,
          timestamp,
          runId: render.runId,
          data: {
            canvasId: render.canvasId,
            toolCallId,
          },
        });
        render.startEmitted = true;

        logger.debug('Emitted ui_render_start from streaming', {
          sessionId,
          canvasId: render.canvasId,
          toolCallId,
        });
      }
    }

    // Emit chunk if we have canvasId (can progressively render)
    if (render.canvasId) {
      logger.debug('Emitting ui_render_chunk', {
        sessionId,
        canvasId: render.canvasId,
        chunkLength: argumentsDelta.length,
        accumulatedLength: render.accumulatedJson.length,
      });
      this.emit('agent_event', {
        type: 'agent.ui_render_chunk',
        sessionId,
        timestamp,
        runId: render.runId,
        data: {
          canvasId: render.canvasId,
          chunk: argumentsDelta,
          accumulated: render.accumulatedJson,
        },
      });
    } else {
      logger.debug('Waiting for canvasId before emitting chunks', {
        sessionId,
        toolCallId,
        accumulatedLength: render.accumulatedJson.length,
      });
    }

    return true;
  }

  /**
   * Clean up any orphaned UI render tracking state.
   * Called when agent ends or errors to prevent memory leaks.
   */
  cleanup(): void {
    if (this.activeRenders.size > 0) {
      logger.debug('Cleaning up orphaned UI renders', {
        count: this.activeRenders.size,
        toolCallIds: Array.from(this.activeRenders.keys()),
      });
      this.activeRenders.clear();
    }
  }

  /**
   * Check if a tool call is being tracked for RenderAppUI streaming.
   */
  isTracking(toolCallId: string): boolean {
    return this.activeRenders.has(toolCallId);
  }

  // ===========================================================================
  // Private Helpers
  // ===========================================================================

  private emitRetry(
    sessionId: SessionId,
    canvasId: string,
    attempt: number,
    errors: string,
    timestamp: string,
    runId?: string
  ): void {
    this.emit('agent_event', {
      type: 'agent.ui_render_retry',
      sessionId,
      timestamp,
      runId,
      data: {
        canvasId,
        attempt,
        errors,
      },
    });

    logger.debug('Emitted ui_render_retry', {
      sessionId,
      canvasId,
      attempt,
    });
  }

  private emitError(
    sessionId: SessionId,
    canvasId: string | null | undefined,
    error: string,
    timestamp: string,
    runId?: string
  ): void {
    if (!canvasId) return;

    this.emit('agent_event', {
      type: 'agent.ui_render_error',
      sessionId,
      timestamp,
      runId,
      data: {
        canvasId,
        error,
      },
    });

    logger.debug('Emitted ui_render_error', {
      sessionId,
      canvasId,
      error: error.substring(0, 200),
    });
  }

  private emitComplete(
    sessionId: SessionId,
    canvasId: string,
    details: ToolEndDetails,
    timestamp: string,
    runId?: string
  ): void {
    this.emit('agent_event', {
      type: 'agent.ui_render_complete',
      sessionId,
      timestamp,
      runId,
      data: {
        canvasId,
        ui: details.ui,
        state: details.state,
      },
    });

    // Persist canvas artifact to disk for session resumption
    saveCanvasArtifact({
      canvasId,
      sessionId,
      title: details.title,
      ui: details.ui as Record<string, unknown>,
      state: details.state as Record<string, unknown> | undefined,
      savedAt: timestamp,
    }).catch(err => {
      logger.error('Failed to persist canvas artifact', {
        canvasId,
        sessionId,
        error: err instanceof Error ? err.message : String(err),
      });
    });

    logger.debug('Emitted ui_render_complete', {
      sessionId,
      canvasId,
    });
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a UIRenderHandler instance.
 */
export function createUIRenderHandler(emit: UIRenderEventEmitter): UIRenderHandler {
  return new UIRenderHandler(emit);
}
