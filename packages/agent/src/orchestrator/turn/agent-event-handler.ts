/**
 * @fileoverview Agent Event Handler - Slim Coordinator
 *
 * Routes agent events to focused handlers. This is a pure coordinator with
 * no business logic - all event handling is delegated to specialized handlers.
 *
 * ## Event Routing
 *
 * | Event Type            | Handler             |
 * |-----------------------|---------------------|
 * | turn_start/end        | TurnEventHandler    |
 * | response_complete     | TurnEventHandler    |
 * | message_update        | StreamingEventHandler |
 * | toolcall_delta        | StreamingEventHandler |
 * | thinking_*            | StreamingEventHandler |
 * | tool_use_batch        | ToolEventHandler    |
 * | tool_execution_*      | ToolEventHandler    |
 * | agent_start/end       | LifecycleEventHandler |
 * | agent_interrupted     | LifecycleEventHandler |
 * | api_retry             | LifecycleEventHandler |
 * | compaction_complete   | CompactionEventHandler |
 *
 * Subagent events are forwarded via SubagentForwarder before routing.
 */
import type { TronEvent } from '../../types/events.js';
import type {
  SessionId,
  EventType,
  SessionEvent as TronSessionEvent,
} from '../../events/types.js';
import type { ActiveSession } from '../types.js';
import { createUIRenderHandler, type UIRenderHandler } from '../ui-render-handler.js';
import {
  createTurnEventHandler,
  createToolEventHandler,
  createStreamingEventHandler,
  createLifecycleEventHandler,
  createCompactionEventHandler,
  createSubagentForwarder,
  type TurnEventHandler,
  type ToolEventHandler,
  type StreamingEventHandler,
  type LifecycleEventHandler,
  type CompactionEventHandler,
  type SubagentForwarder,
} from './handlers/index.js';

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
 * Coordinates agent event handling by delegating to focused handlers.
 * Extracted from EventStoreOrchestrator to improve modularity.
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

  constructor(config: AgentEventHandlerConfig) {
    this.config = config;
    this.uiRenderHandler = createUIRenderHandler(config.emit);

    // Create focused handlers
    this.turnHandler = createTurnEventHandler({
      getActiveSession: config.getActiveSession,
      appendEventLinearized: config.appendEventLinearized,
      emit: config.emit,
    });

    this.toolHandler = createToolEventHandler({
      getActiveSession: config.getActiveSession,
      appendEventLinearized: config.appendEventLinearized,
      emit: config.emit,
      uiRenderHandler: this.uiRenderHandler,
    });

    this.streamingHandler = createStreamingEventHandler({
      getActiveSession: config.getActiveSession,
      emit: config.emit,
      uiRenderHandler: this.uiRenderHandler,
    });

    this.lifecycleHandler = createLifecycleEventHandler({
      defaultProvider: config.defaultProvider,
      getActiveSession: config.getActiveSession,
      appendEventLinearized: config.appendEventLinearized,
      emit: config.emit,
      uiRenderHandler: this.uiRenderHandler,
    });

    this.compactionHandler = createCompactionEventHandler({
      appendEventLinearized: config.appendEventLinearized,
      emit: config.emit,
    });

    this.subagentForwarder = createSubagentForwarder({
      emit: config.emit,
    });
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
      this.subagentForwarder.forwardToParent(sessionId, active.parentSessionId, event, timestamp);
    }

    switch (event.type) {
      case 'turn_start':
        this.turnHandler.handleTurnStart(sessionId, event, timestamp);
        break;

      case 'turn_end':
        this.turnHandler.handleTurnEnd(sessionId, event, timestamp);
        break;

      case 'response_complete':
        this.turnHandler.handleResponseComplete(sessionId, event);
        break;

      case 'message_update':
        this.streamingHandler.handleMessageUpdate(sessionId, event, timestamp, active);
        break;

      case 'tool_use_batch':
        this.toolHandler.handleToolUseBatch(sessionId, event);
        break;

      case 'tool_execution_start':
        this.toolHandler.handleToolExecutionStart(sessionId, event, timestamp);
        break;

      case 'tool_execution_end':
        this.toolHandler.handleToolExecutionEnd(sessionId, event, timestamp);
        break;

      case 'api_retry':
        this.lifecycleHandler.handleApiRetry(sessionId, event);
        break;

      case 'agent_start':
        this.lifecycleHandler.handleAgentStart(sessionId, timestamp, active);
        break;

      case 'agent_end':
        this.lifecycleHandler.handleAgentEnd(active);
        break;

      case 'agent_interrupted':
        this.lifecycleHandler.handleAgentInterrupted(sessionId, event, timestamp);
        break;

      case 'compaction_complete':
        this.compactionHandler.handleCompactionComplete(sessionId, event, timestamp);
        break;

      case 'toolcall_delta':
        this.streamingHandler.handleToolCallDelta(sessionId, event, timestamp);
        break;

      case 'thinking_start':
        this.streamingHandler.handleThinkingStart(sessionId, timestamp);
        break;

      case 'thinking_delta':
        this.streamingHandler.handleThinkingDelta(sessionId, event, timestamp, active);
        break;

      case 'thinking_end':
        this.streamingHandler.handleThinkingEnd(sessionId, event, timestamp);
        break;
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
