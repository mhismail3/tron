/**
 * @fileoverview Agent Event Handler - Slim Coordinator
 *
 * Routes agent events to focused handlers. This is a pure coordinator with
 * no business logic - all event handling is delegated to specialized handlers.
 *
 * ## EventContext Pattern
 *
 * The coordinator creates an EventContext at the start of each event dispatch.
 * This context is passed to all handlers and provides:
 * - sessionId: The session this event belongs to
 * - timestamp: Consistent timestamp across all related events
 * - runId: Current run ID for correlation
 * - active: Active session for state updates
 * - emit(): Emit WebSocket events with automatic metadata
 * - persist(): Persist events with automatic metadata
 *
 * This eliminates "shotgun surgery" when adding cross-cutting concerns.
 *
 * ## Event Routing
 *
 * | Event Type            | Handler             |
 * |-----------------------|---------------------|
 * | turn_start/end        | TurnEventHandler    |
 * | response_complete     | TurnEventHandler    |
 * | message_update        | StreamingEventHandler |
 * | toolcall_generating   | StreamingEventHandler |
 * | toolcall_delta        | StreamingEventHandler |
 * | thinking_*            | StreamingEventHandler |
 * | tool_use_batch        | ToolEventHandler    |
 * | tool_execution_*      | ToolEventHandler    |
 * | agent_start/end       | LifecycleEventHandler |
 * | agent_interrupted     | LifecycleEventHandler |
 * | api_retry             | LifecycleEventHandler |
 * | compaction_start      | CompactionEventHandler |
 * | compaction_complete   | CompactionEventHandler |
 * | hook_triggered        | HookEventHandler       |
 * | hook_completed        | HookEventHandler       |
 *
 * Subagent events are forwarded via SubagentForwarder before routing.
 */
import type { TronEvent } from '@core/types/events.js';
import type {
  SessionId,
  EventType,
  SessionEvent as TronSessionEvent,
} from '@infrastructure/events/types.js';
import type { ActiveSessionStore } from '../session/active-session-store.js';
import { createUIRenderHandler, type UIRenderHandler } from '../ui-render-handler.js';
import {
  createTurnEventHandler,
  createToolEventHandler,
  createStreamingEventHandler,
  createLifecycleEventHandler,
  createCompactionEventHandler,
  createSubagentForwarder,
  createHookEventHandler,
  type TurnEventHandler,
  type ToolEventHandler,
  type StreamingEventHandler,
  type LifecycleEventHandler,
  type CompactionEventHandler,
  type SubagentForwarder,
  type HookEventHandler,
  type InternalHookTriggeredEvent,
  type InternalHookCompletedEvent,
  type BlobStore,
} from './handlers/index.js';
import { createEventContext, type EventContext } from './event-context.js';

// =============================================================================
// Types
// =============================================================================

/**
 * Configuration for AgentEventHandler
 */
export interface AgentEventHandlerConfig {
  /** Default provider for error events */
  defaultProvider: string;
  /** Active session store */
  sessionStore: ActiveSessionStore;
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
 * Coordinates agent event handling by delegating to focused handlers.
 * Extracted from EventStoreOrchestrator to improve modularity.
 *
 * Uses EventContext to provide scoped context for each event dispatch,
 * eliminating the need for handlers to manually include metadata.
 */
export class AgentEventHandler {
  private config: AgentEventHandlerConfig;

  /**
   * Handles all RenderAppUI tool-specific event processing.
   * Extracted to UIRenderHandler to consolidate special handling.
   */
  private uiRenderHandler: UIRenderHandler;

  /**
   * Handles turn lifecycle events (turn_start, turn_end, response_complete).
   */
  private turnHandler: TurnEventHandler;

  /**
   * Handles tool execution events (tool_use_batch, tool_execution_start/end).
   */
  private toolHandler: ToolEventHandler;

  /**
   * Handles streaming events (message_update, toolcall_delta, thinking_*).
   */
  private streamingHandler: StreamingEventHandler;

  /**
   * Handles lifecycle events (agent_start/end, api_retry, interrupted).
   */
  private lifecycleHandler: LifecycleEventHandler;

  /**
   * Handles compaction events (compaction_complete).
   */
  private compactionHandler: CompactionEventHandler;

  /**
   * Forwards streaming events from subagent sessions to parent sessions.
   */
  private subagentForwarder: SubagentForwarder;

  /**
   * Handles hook lifecycle events (hook_triggered, hook_completed).
   */
  private hookHandler: HookEventHandler;

  constructor(config: AgentEventHandlerConfig) {
    this.config = config;
    this.uiRenderHandler = createUIRenderHandler(config.emit);

    // Create focused handlers with simplified dependencies
    this.turnHandler = createTurnEventHandler({});

    this.toolHandler = createToolEventHandler({
      uiRenderHandler: this.uiRenderHandler,
    });

    this.streamingHandler = createStreamingEventHandler({
      uiRenderHandler: this.uiRenderHandler,
    });

    this.lifecycleHandler = createLifecycleEventHandler({
      defaultProvider: config.defaultProvider,
      uiRenderHandler: this.uiRenderHandler,
    });

    this.compactionHandler = createCompactionEventHandler({});

    this.subagentForwarder = createSubagentForwarder({});

    this.hookHandler = createHookEventHandler({});
  }

  /**
   * Set the blob store for large content storage.
   * Call after EventStore is initialized to enable content storage.
   */
  setBlobStore(blobStore: BlobStore): void {
    this.toolHandler.setBlobStore(blobStore);
  }

  /**
   * Forward an agent event for processing.
   * Handles turn lifecycle, streaming, tool execution, and other event types.
   *
   * Creates an EventContext scoped to this event dispatch, which provides:
   * - Automatic sessionId, timestamp, runId inclusion
   * - Access to active session
   * - Simplified emit/persist API
   */
  forwardEvent(sessionId: SessionId, event: TronEvent): void {
    // Create EventContext ONCE at the start of event dispatch
    const ctx = this.createEventContext(sessionId);

    // If this is a subagent session, forward streaming events to parent
    if (ctx.active?.parentSessionId) {
      const parentCtx = this.createEventContext(ctx.active.parentSessionId);
      this.subagentForwarder.forwardToParent(parentCtx, sessionId, event);
    }

    switch (event.type) {
      case 'turn_start':
        this.turnHandler.handleTurnStart(ctx, event);
        break;

      case 'turn_end':
        this.turnHandler.handleTurnEnd(ctx, event);
        break;

      case 'response_complete':
        this.turnHandler.handleResponseComplete(ctx, event);
        break;

      case 'message_update':
        this.streamingHandler.handleMessageUpdate(ctx, event);
        break;

      case 'tool_use_batch':
        this.toolHandler.handleToolUseBatch(ctx, event);
        break;

      case 'tool_execution_start':
        this.toolHandler.handleToolExecutionStart(ctx, event);
        break;

      case 'tool_execution_end':
        this.toolHandler.handleToolExecutionEnd(ctx, event);
        break;

      case 'api_retry':
        this.lifecycleHandler.handleApiRetry(ctx, event);
        break;

      case 'agent_start':
        this.lifecycleHandler.handleAgentStart(ctx);
        break;

      case 'agent_end':
        this.lifecycleHandler.handleAgentEnd(ctx);
        break;

      case 'agent_ready':
        this.lifecycleHandler.handleAgentReady(ctx);
        break;

      case 'agent_interrupted':
        this.lifecycleHandler.handleAgentInterrupted(ctx, event);
        break;

      case 'compaction_start':
        this.compactionHandler.handleCompactionStarted(ctx, event);
        break;

      case 'compaction_complete':
        this.compactionHandler.handleCompactionComplete(ctx, event);
        break;

      case 'toolcall_generating':
        this.streamingHandler.handleToolCallGenerating(ctx, event);
        break;

      case 'toolcall_delta':
        this.streamingHandler.handleToolCallDelta(ctx, event);
        break;

      case 'thinking_start':
        this.streamingHandler.handleThinkingStart(ctx);
        break;

      case 'thinking_delta':
        this.streamingHandler.handleThinkingDelta(ctx, event);
        break;

      case 'thinking_end':
        this.streamingHandler.handleThinkingEnd(ctx, event);
        break;

      case 'hook_triggered':
        this.hookHandler.handleHookTriggered(ctx, event as unknown as InternalHookTriggeredEvent);
        break;

      case 'hook_completed':
        this.hookHandler.handleHookCompleted(ctx, event as unknown as InternalHookCompletedEvent);
        break;
    }
  }

  /**
   * Create an EventContext for a session.
   */
  private createEventContext(sessionId: SessionId): EventContext {
    return createEventContext(sessionId, {
      sessionStore: this.config.sessionStore,
      appendEventLinearized: this.config.appendEventLinearized,
      emit: this.config.emit,
    });
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
