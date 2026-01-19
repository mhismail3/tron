/**
 * @fileoverview Agent Event Handler
 *
 * Extracted from EventStoreOrchestrator as part of modular refactoring.
 * Handles forwarding and processing of agent events during turn execution.
 *
 * ## Event Types Handled
 *
 * - **turn_start/turn_end**: Turn lifecycle events
 * - **message_update**: Streaming text deltas
 * - **tool_use_batch**: Batch of tool calls about to execute
 * - **tool_execution_start/end**: Individual tool execution events
 * - **api_retry**: Provider retry events
 * - **agent_start/end**: Agent lifecycle events
 * - **agent_interrupted**: Interruption events
 * - **compaction_complete**: Context compaction events
 *
 * ## Design
 *
 * - Stateless module that operates on provided dependencies
 * - Uses callbacks for event emission and persistence
 * - Normalizes content blocks before persistence
 * - Handles cost calculation for turn events
 */
import {
  createLogger,
  calculateCost,
  type TronEvent,
  type SessionId,
  type EventType,
  type TronSessionEvent,
} from '@tron/core';
import {
  normalizeContentBlocks,
  truncateString,
  MAX_TOOL_RESULT_SIZE,
} from '../utils/content-normalizer.js';
import type { ActiveSession } from './types.js';

const logger = createLogger('agent-event-handler');

// =============================================================================
// Types
// =============================================================================

/**
 * Configuration for AgentEventHandler
 */
export interface AgentEventHandlerConfig {
  /** Default provider for error events */
  defaultProvider: string;
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
}

// =============================================================================
// AgentEventHandler Class
// =============================================================================

/**
 * Handles forwarding and processing of agent events.
 * Extracted from EventStoreOrchestrator to improve modularity.
 */
export class AgentEventHandler {
  private config: AgentEventHandlerConfig;

  constructor(config: AgentEventHandlerConfig) {
    this.config = config;
  }

  /**
   * Forward an agent event for processing.
   * Handles turn lifecycle, streaming, tool execution, and other event types.
   */
  forwardEvent(sessionId: SessionId, event: TronEvent): void {
    const timestamp = new Date().toISOString();
    const active = this.config.getActiveSession(sessionId);

    // If this is a subagent session, forward streaming events to parent
    if (active?.parentSessionId) {
      this.forwardToParent(sessionId, active.parentSessionId, event, timestamp);
    }

    switch (event.type) {
      case 'turn_start':
        this.handleTurnStart(sessionId, event, timestamp, active);
        break;

      case 'turn_end':
        this.handleTurnEnd(sessionId, event, timestamp, active);
        break;

      case 'message_update':
        this.handleMessageUpdate(sessionId, event, timestamp, active);
        break;

      case 'tool_use_batch':
        this.handleToolUseBatch(sessionId, event, active);
        break;

      case 'tool_execution_start':
        this.handleToolExecutionStart(sessionId, event, timestamp, active);
        break;

      case 'tool_execution_end':
        this.handleToolExecutionEnd(sessionId, event, timestamp, active);
        break;

      case 'api_retry':
        this.handleApiRetry(sessionId, event);
        break;

      case 'agent_start':
        this.handleAgentStart(sessionId, timestamp, active);
        break;

      case 'agent_end':
        this.handleAgentEnd(active);
        break;

      case 'agent_interrupted':
        this.handleAgentInterrupted(sessionId, event, timestamp);
        break;

      case 'compaction_complete':
        this.handleCompactionComplete(sessionId, event, timestamp);
        break;
    }
  }

  // ===========================================================================
  // Private Event Handlers
  // ===========================================================================

  private handleTurnStart(
    sessionId: SessionId,
    event: TronEvent,
    timestamp: string,
    active: ActiveSession | undefined
  ): void {
    // Cast to access turn_start specific properties
    const turnStartEvent = event as { turn?: number };

    // Update current turn for tool event tracking
    if (active && turnStartEvent.turn !== undefined) {
      active.sessionContext!.startTurn(turnStartEvent.turn);
    }

    this.config.emit('agent_event', {
      type: 'agent.turn_start',
      sessionId,
      timestamp,
      data: { turn: turnStartEvent.turn },
    });

    // Store turn start event (linearized to prevent spurious branches)
    this.config.appendEventLinearized(sessionId, 'stream.turn_start' as EventType, { turn: turnStartEvent.turn });
  }

  private handleTurnEnd(
    sessionId: SessionId,
    event: TronEvent,
    timestamp: string,
    active: ActiveSession | undefined
  ): void {
    // Cast to access turn_end specific properties
    const turnEndEvent = event as {
      turn?: number;
      duration?: number;
      cost?: number;
      tokenUsage?: {
        inputTokens: number;
        outputTokens: number;
        cacheReadTokens?: number;
        cacheCreationTokens?: number;
      };
    };

    // NOTE: We do NOT clear accumulated content here anymore!
    // Accumulated content is kept so that if user resumes during a later turn,
    // they get ALL content from Turn 1, Turn 2, etc.
    // Accumulation is cleared at agent_start/agent_end instead.

    // CREATE MESSAGE.ASSISTANT FOR THIS TURN - BUT ONLY IF NOT ALREADY FLUSHED
    // Linear event ordering means content with tool_use is flushed at first tool_execution_start.
    // Only create message.assistant here if:
    // 1. No pre-tool content was flushed (no tools in this turn), OR
    // 2. This is a simple text-only response (no tools)
    if (active) {
      // Check if pre-tool content was already flushed (tools were called this turn)
      const wasPreToolFlushed = active.sessionContext!.hasPreToolContentFlushed();

      // Use SessionContext for turn end
      // This returns built content blocks and clears per-turn tracking
      const turnStartTime = active.sessionContext!.getTurnStartTime();
      const turnResult = active.sessionContext!.endTurn(turnEndEvent.tokenUsage);

      // Only create message.assistant if we didn't already flush content for tools
      // If wasPreToolFlushed is true, the content was already emitted at tool_execution_start
      if (!wasPreToolFlushed && turnResult.content.length > 0) {
        // Calculate latency for this turn
        const turnLatency = turnStartTime
          ? Date.now() - turnStartTime
          : turnEndEvent.duration ?? 0;

        // Detect if content has thinking blocks
        const hasThinking = turnResult.content.some((b) => (b as unknown as Record<string, unknown>).type === 'thinking');

        // Normalize content blocks
        const normalizedContent = normalizeContentBlocks(turnResult.content);

        // Create message.assistant event for this turn (no tools case)
        if (normalizedContent.length > 0) {
          this.config.appendEventLinearized(sessionId, 'message.assistant' as EventType, {
            content: normalizedContent,
            tokenUsage: turnResult.tokenUsage,
            turn: turnResult.turn,
            model: active.model,
            stopReason: 'end_turn',
            latency: turnLatency,
            hasThinking,
          }, (evt) => {
            // Track eventId for context manager message
            // Re-fetch active session since callback is async
            const currentActive = this.config.getActiveSession(sessionId);
            if (currentActive) {
              currentActive.messageEventIds.push(evt.id);
            }
          });

          logger.debug('Created message.assistant for turn (no tools)', {
            sessionId,
            turn: turnResult.turn,
            contentBlocks: normalizedContent.length,
            tokenUsage: turnResult.tokenUsage,
            latency: turnLatency,
          });
        }
      } else if (wasPreToolFlushed) {
        logger.debug('Skipped message.assistant at turn_end (content already flushed for tools)', {
          sessionId,
          turn: turnResult.turn,
        });
      }
    }

    // Calculate cost if not provided by agent (or is 0) but tokenUsage is available
    // The agent may send cost: 0 if usage data was incomplete, so always recalculate
    let turnCost = turnEndEvent.cost;
    if (turnEndEvent.tokenUsage && active) {
      const costResult = calculateCost(active.model, {
        inputTokens: turnEndEvent.tokenUsage.inputTokens,
        outputTokens: turnEndEvent.tokenUsage.outputTokens,
        cacheReadTokens: turnEndEvent.tokenUsage.cacheReadTokens,
        cacheCreationTokens: turnEndEvent.tokenUsage.cacheCreationTokens,
      });
      // Use calculated cost if agent didn't provide one or provided 0
      if (turnCost === undefined || turnCost === 0) {
        turnCost = costResult.total;
      }
    }

    this.config.emit('agent_event', {
      type: 'agent.turn_end',
      sessionId,
      timestamp,
      data: {
        turn: turnEndEvent.turn,
        duration: turnEndEvent.duration,
        tokenUsage: turnEndEvent.tokenUsage,
        cost: turnCost,
      },
    });

    // Store turn end event with token usage and cost (linearized)
    this.config.appendEventLinearized(sessionId, 'stream.turn_end' as EventType, {
      turn: turnEndEvent.turn,
      tokenUsage: turnEndEvent.tokenUsage ?? { inputTokens: 0, outputTokens: 0 },
      cost: turnCost,
    });
  }

  private handleMessageUpdate(
    sessionId: SessionId,
    event: TronEvent,
    timestamp: string,
    active: ActiveSession | undefined
  ): void {
    // Cast to access message_update specific properties
    const msgEvent = event as { content?: string };

    // STREAMING ONLY - NOT PERSISTED TO EVENT STORE
    // Text deltas are accumulated in TurnContentTracker for:
    // 1. Real-time WebSocket emission (agent.text_delta below)
    // 2. Client catch-up when resuming into running session
    // 3. Building consolidated message.assistant at turn_end (which IS persisted)
    //
    // Individual deltas are ephemeral by design - high frequency, low reconstruction value.
    // The source of truth is the message.assistant event created at turn_end.
    if (active && typeof msgEvent.content === 'string') {
      // Use SessionContext for text delta
      active.sessionContext!.addTextDelta(msgEvent.content);
    }

    this.config.emit('agent_event', {
      type: 'agent.text_delta',
      sessionId,
      timestamp,
      data: { delta: msgEvent.content },
    });
  }

  private handleToolUseBatch(
    sessionId: SessionId,
    event: TronEvent,
    active: ActiveSession | undefined
  ): void {
    // Cast to access tool_use_batch specific properties
    const batchEvent = event as { toolCalls?: Array<{ name: string; id: string; input?: unknown; arguments?: Record<string, unknown> }> };

    // Register ALL tool_use intents BEFORE any execution starts
    // This enables linear event ordering by knowing all tools upfront
    if (active && batchEvent.toolCalls && Array.isArray(batchEvent.toolCalls)) {
      // Transform tool calls to expected format (input may come as input or arguments)
      const normalizedToolCalls = batchEvent.toolCalls.map(tc => ({
        id: tc.id,
        name: tc.name,
        arguments: (tc.arguments ?? tc.input ?? {}) as Record<string, unknown>,
      }));
      active.sessionContext!.registerToolIntents(normalizedToolCalls);

      logger.debug('Registered tool_use batch', {
        sessionId,
        toolCount: batchEvent.toolCalls.length,
        toolNames: batchEvent.toolCalls.map((tc: { name: string }) => tc.name),
      });
    }
  }

  private handleToolExecutionStart(
    sessionId: SessionId,
    event: TronEvent,
    timestamp: string,
    active: ActiveSession | undefined
  ): void {
    // Cast to access tool_execution_start specific properties
    const toolStartEvent = event as {
      toolCallId: string;
      toolName: string;
      arguments?: Record<string, unknown>;
    };

    // Track tool call for resume support (across ALL turns)
    if (active) {
      // Use SessionContext for tool start
      active.sessionContext!.startToolCall(
        toolStartEvent.toolCallId,
        toolStartEvent.toolName,
        toolStartEvent.arguments ?? {}
      );

      // LINEAR EVENT ORDERING: Flush accumulated content as message.assistant BEFORE tool.call
      // This ensures correct order: message.assistant (with tool_use) → tool.call → tool.result
      // The flush only happens once per turn (first tool_execution_start)
      const preToolContent = active.sessionContext!.flushPreToolContent();
      if (preToolContent && preToolContent.length > 0) {
        const normalizedContent = normalizeContentBlocks(preToolContent);
        if (normalizedContent.length > 0) {
          const turnStartTime = active.sessionContext!.getTurnStartTime();
          const turnLatency = turnStartTime ? Date.now() - turnStartTime : 0;

          // Detect if content has thinking blocks
          const hasThinking = normalizedContent.some((b) => (b as Record<string, unknown>).type === 'thinking');

          this.config.appendEventLinearized(sessionId, 'message.assistant' as EventType, {
            content: normalizedContent,
            turn: active.sessionContext!.getCurrentTurn(),
            model: active.model,
            stopReason: 'tool_use', // Indicates tools are being called
            latency: turnLatency,
            hasThinking,
          }, (evt) => {
            // Track eventId for context manager message
            const currentActive = this.config.getActiveSession(sessionId);
            if (currentActive) {
              currentActive.messageEventIds.push(evt.id);
            }
          });

          logger.debug('Created pre-tool message.assistant for linear ordering', {
            sessionId,
            turn: active.sessionContext!.getCurrentTurn(),
            contentBlocks: normalizedContent.length,
          });
        }
      }
    }

    this.config.emit('agent_event', {
      type: 'agent.tool_start',
      sessionId,
      timestamp,
      data: {
        toolCallId: toolStartEvent.toolCallId,
        toolName: toolStartEvent.toolName,
        arguments: toolStartEvent.arguments,
      },
    });

    // Store discrete tool.call event (linearized)
    this.config.appendEventLinearized(sessionId, 'tool.call' as EventType, {
      toolCallId: toolStartEvent.toolCallId,
      name: toolStartEvent.toolName,
      arguments: toolStartEvent.arguments ?? {},
      turn: active?.sessionContext?.getCurrentTurn() ?? 0,
    });
  }

  private handleToolExecutionEnd(
    sessionId: SessionId,
    event: TronEvent,
    timestamp: string,
    active: ActiveSession | undefined
  ): void {
    // Cast to access tool_execution_end specific properties
    const toolEndEvent = event as {
      toolCallId: string;
      toolName: string;
      result: unknown;
      isError?: boolean;
      duration?: number;
    };

    // Extract text content from TronToolResult
    // content can be string OR array of { type: 'text', text } | { type: 'image', ... }
    const resultContent = (() => {
      if (typeof toolEndEvent.result !== 'object' || toolEndEvent.result === null) {
        return String(toolEndEvent.result ?? '');
      }
      const result = toolEndEvent.result as { content?: string | Array<{ type: string; text?: string }> };
      if (typeof result.content === 'string') {
        return result.content;
      }
      if (Array.isArray(result.content)) {
        // Extract text from content blocks, join with newlines
        return result.content
          .filter((block): block is { type: 'text'; text: string } =>
            block.type === 'text' && typeof block.text === 'string')
          .map(block => block.text)
          .join('\n');
      }
      // Fallback: stringify the whole result
      return JSON.stringify(toolEndEvent.result);
    })();

    // Update tool call tracking for resume support (across ALL turns)
    if (active) {
      // Use SessionContext for tool end
      active.sessionContext!.endToolCall(
        toolEndEvent.toolCallId,
        resultContent,
        toolEndEvent.isError ?? false
      );
    }

    // Extract details from tool result (e.g., full screenshot data for iOS)
    const resultDetails = typeof toolEndEvent.result === 'object' && toolEndEvent.result !== null
      ? (toolEndEvent.result as { details?: unknown }).details
      : undefined;

    this.config.emit('agent_event', {
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

    // Store discrete tool.result event (linearized)
    this.config.appendEventLinearized(sessionId, 'tool.result' as EventType, {
      toolCallId: toolEndEvent.toolCallId,
      content: truncateString(resultContent, MAX_TOOL_RESULT_SIZE),
      isError: toolEndEvent.isError ?? false,
      duration: toolEndEvent.duration,
      truncated: resultContent.length > MAX_TOOL_RESULT_SIZE,
    }, (evt) => {
      // Track eventId for context manager message (tool result)
      // Re-fetch active session since callback is async
      const currentActive = this.config.getActiveSession(sessionId);
      if (currentActive) {
        currentActive.messageEventIds.push(evt.id);
      }
    });
  }

  private handleApiRetry(sessionId: SessionId, event: TronEvent): void {
    // Store provider error event for API retries (linearized)
    // Cast to access api_retry specific properties
    const retryEvent = event as { errorMessage?: string; errorCategory?: string; delayMs?: number };
    this.config.appendEventLinearized(sessionId, 'error.provider' as EventType, {
      provider: this.config.defaultProvider,
      error: retryEvent.errorMessage,
      code: retryEvent.errorCategory,
      retryable: true,
      retryAfter: retryEvent.delayMs,
    });
  }

  private handleAgentStart(
    sessionId: SessionId,
    timestamp: string,
    active: ActiveSession | undefined
  ): void {
    // Clear accumulation at the start of a new agent run
    // This ensures fresh tracking for the new runAgent call
    if (active) {
      // Use SessionContext for agent lifecycle
      active.sessionContext!.onAgentStart();
    }

    this.config.emit('agent_event', {
      type: 'agent.turn_start',
      sessionId,
      timestamp,
      data: {},
    });
  }

  private handleAgentEnd(active: ActiveSession | undefined): void {
    // Clear accumulation when agent run completes
    // Content is now persisted in EventStore, no need for catch-up tracking
    if (active) {
      // Use SessionContext for agent lifecycle
      active.sessionContext!.onAgentEnd();
    }

    // NOTE: agent.complete is now emitted in runAgent() AFTER all events are persisted
    // This ensures linearized events (message.assistant, tool.call, tool.result)
    // are in the database before iOS syncs on receiving agent.complete
  }

  private handleAgentInterrupted(
    sessionId: SessionId,
    event: TronEvent,
    timestamp: string
  ): void {
    // Cast to access agent_interrupted specific properties
    const interruptedEvent = event as { partialContent?: unknown };
    this.config.emit('agent_event', {
      type: 'agent.complete',
      sessionId,
      timestamp,
      data: {
        success: false,
        interrupted: true,
        partialContent: interruptedEvent.partialContent,
      },
    });
  }

  /**
   * Forward streaming events from a subagent to its parent session.
   * This enables real-time updates in the iOS detail sheet.
   */
  private forwardToParent(
    subagentSessionId: SessionId,
    parentSessionId: SessionId,
    event: TronEvent,
    timestamp: string
  ): void {
    // Only forward events useful for real-time detail sheet display
    const forwardableTypes = [
      'message_update',       // Text deltas
      'tool_execution_start', // Tool start
      'tool_execution_end',   // Tool end
      'turn_start',           // Turn lifecycle
      'turn_end',
    ];

    if (!forwardableTypes.includes(event.type)) {
      return;
    }

    // Map event type to iOS-friendly format
    let eventType: string;
    let eventData: unknown;

    switch (event.type) {
      case 'message_update': {
        const msgEvent = event as { content?: string };
        eventType = 'text_delta';
        eventData = { delta: msgEvent.content };
        break;
      }
      case 'tool_execution_start': {
        const toolEvent = event as { toolCallId: string; toolName: string; arguments?: unknown };
        eventType = 'tool_start';
        eventData = {
          toolCallId: toolEvent.toolCallId,
          toolName: toolEvent.toolName,
          arguments: toolEvent.arguments,
        };
        break;
      }
      case 'tool_execution_end': {
        const toolEvent = event as { toolCallId: string; toolName: string; result: unknown; isError?: boolean; duration?: number };
        eventType = 'tool_end';
        eventData = {
          toolCallId: toolEvent.toolCallId,
          toolName: toolEvent.toolName,
          success: !toolEvent.isError,
          result: typeof toolEvent.result === 'string' ? toolEvent.result : JSON.stringify(toolEvent.result),
          duration: toolEvent.duration,
        };
        break;
      }
      case 'turn_start': {
        const turnEvent = event as { turn?: number };
        eventType = 'turn_start';
        eventData = { turn: turnEvent.turn };

        // Also emit a status update to parent
        this.config.emit('agent_event', {
          type: 'agent.subagent_status',
          sessionId: parentSessionId,
          timestamp,
          data: {
            subagentSessionId,
            status: 'running',
            currentTurn: turnEvent.turn ?? 1,
          },
        });
        break;
      }
      case 'turn_end': {
        const turnEvent = event as { turn?: number };
        eventType = 'turn_end';
        eventData = { turn: turnEvent.turn };
        break;
      }
      default:
        return;
    }

    // Emit the forwarded event to parent session
    this.config.emit('agent_event', {
      type: 'agent.subagent_event',
      sessionId: parentSessionId,
      timestamp,
      data: {
        subagentSessionId,
        event: {
          type: eventType,
          data: eventData,
          timestamp,
        },
      },
    });
  }

  private handleCompactionComplete(
    sessionId: SessionId,
    event: TronEvent,
    timestamp: string
  ): void {
    // Cast to access compaction_complete specific properties
    const compactionEvent = event as {
      tokensBefore?: number;
      tokensAfter?: number;
      compressionRatio?: number;
      reason?: string;
      success?: boolean;
      summary?: string;
    };

    const reason = compactionEvent.reason || 'auto';

    // Broadcast streaming event for live clients
    this.config.emit('agent_event', {
      type: 'agent.compaction',
      sessionId,
      timestamp,
      data: {
        tokensBefore: compactionEvent.tokensBefore,
        tokensAfter: compactionEvent.tokensAfter,
        compressionRatio: compactionEvent.compressionRatio,
        reason,
        summary: compactionEvent.summary,
      },
    });

    // Persist compact.boundary event so it shows up on session resume
    // Only persist successful compactions
    if (compactionEvent.success !== false) {
      this.config.appendEventLinearized(sessionId, 'compact.boundary', {
        originalTokens: compactionEvent.tokensBefore,
        compactedTokens: compactionEvent.tokensAfter,
        compressionRatio: compactionEvent.compressionRatio,
        reason,
        summary: compactionEvent.summary,
      });

      logger.debug('Persisted compact.boundary event', {
        sessionId,
        tokensBefore: compactionEvent.tokensBefore,
        tokensAfter: compactionEvent.tokensAfter,
        reason,
      });
    }
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create an AgentEventHandler instance
 */
export function createAgentEventHandler(
  config: AgentEventHandlerConfig
): AgentEventHandler {
  return new AgentEventHandler(config);
}
