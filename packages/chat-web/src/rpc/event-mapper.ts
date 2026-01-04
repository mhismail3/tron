/**
 * @fileoverview RPC Event to Action Mapper
 *
 * Maps RPC events from the server to state actions for the reducer.
 */

import type {
  RpcEvent,
  RpcEventType,
  AgentTextDeltaEvent,
  AgentThinkingDeltaEvent,
  AgentToolStartEvent,
  AgentToolEndEvent,
  AgentCompleteEvent,
} from '@tron/core/browser';
import type { AppAction, DisplayMessage } from '../store/types.js';

// =============================================================================
// Types
// =============================================================================

/**
 * Maps an RPC event to zero or more actions
 */
export type EventMapper = (event: RpcEvent) => AppAction[];

// =============================================================================
// Event Handlers
// =============================================================================

function handleTurnStart(_event: RpcEvent): AppAction[] {
  return [
    { type: 'SET_PROCESSING', payload: true },
    { type: 'SET_STREAMING', payload: true },
    { type: 'SET_STATUS', payload: 'Processing' },
    { type: 'CLEAR_STREAMING' },
  ];
}

function handleTurnEnd(_event: RpcEvent): AppAction[] {
  return [
    { type: 'SET_STREAMING', payload: false },
  ];
}

function handleTextDelta(event: RpcEvent): AppAction[] {
  const data = event.data as AgentTextDeltaEvent;
  return [
    { type: 'APPEND_STREAMING_CONTENT', payload: data.delta },
  ];
}

function handleThinkingDelta(event: RpcEvent): AppAction[] {
  const data = event.data as AgentThinkingDeltaEvent;
  return [
    { type: 'APPEND_THINKING_TEXT', payload: data.delta },
  ];
}

function handleToolStart(event: RpcEvent): AppAction[] {
  const data = event.data as AgentToolStartEvent;
  const { toolName, arguments: args, toolCallId } = data;

  // Create a tool message
  const message: DisplayMessage = {
    id: toolCallId,
    role: 'tool',
    content: '',
    timestamp: event.timestamp,
    toolName,
    toolStatus: 'running',
    toolInput: JSON.stringify(args, null, 2),
  };

  return [
    { type: 'SET_ACTIVE_TOOL', payload: toolName },
    { type: 'SET_ACTIVE_TOOL_INPUT', payload: JSON.stringify(args, null, 2) },
    { type: 'ADD_MESSAGE', payload: message },
  ];
}

function handleToolEnd(event: RpcEvent): AppAction[] {
  const data = event.data as AgentToolEndEvent;
  const { toolCallId, success, output, error, duration } = data;

  return [
    { type: 'SET_ACTIVE_TOOL', payload: null },
    { type: 'SET_ACTIVE_TOOL_INPUT', payload: null },
    {
      type: 'UPDATE_MESSAGE',
      payload: {
        id: toolCallId,
        updates: {
          toolStatus: success ? 'success' : 'error',
          content: output ?? error ?? '',
          duration,
        },
      },
    },
  ];
}

function handleAgentError(event: RpcEvent): AppAction[] {
  const message = (event.data as { message?: string }).message ?? 'An error occurred';

  return [
    { type: 'SET_ERROR', payload: message },
    { type: 'SET_PROCESSING', payload: false },
    { type: 'SET_STREAMING', payload: false },
    { type: 'SET_STATUS', payload: 'Error' },
  ];
}

function handleAgentComplete(event: RpcEvent): AppAction[] {
  const data = event.data as AgentCompleteEvent;
  const { tokenUsage, success, error } = data;

  const actions: AppAction[] = [
    { type: 'SET_PROCESSING', payload: false },
    { type: 'SET_STREAMING', payload: false },
    { type: 'SET_TOKEN_USAGE', payload: tokenUsage },
  ];

  if (success) {
    actions.push({ type: 'SET_STATUS', payload: 'Ready' });
    actions.push({ type: 'SET_ERROR', payload: null });
  } else {
    actions.push({ type: 'SET_STATUS', payload: 'Error' });
    if (error) {
      actions.push({ type: 'SET_ERROR', payload: error });
    }
  }

  return actions;
}

function handleSessionCreated(event: RpcEvent): AppAction[] {
  const { sessionId, model } = event.data as { sessionId: string; model?: string };

  const actions: AppAction[] = [
    { type: 'SET_SESSION', payload: sessionId },
    { type: 'SET_INITIALIZED', payload: true },
    { type: 'SET_STATUS', payload: 'Ready' },
  ];

  if (model) {
    actions.push({ type: 'SET_CURRENT_MODEL', payload: model });
  }

  return actions;
}

function handleSessionEnded(_event: RpcEvent): AppAction[] {
  return [
    { type: 'RESET' },
  ];
}

function handleSessionUpdated(event: RpcEvent): AppAction[] {
  const data = event.data as Record<string, unknown>;
  const actions: AppAction[] = [];

  if (typeof data.model === 'string') {
    actions.push({ type: 'SET_CURRENT_MODEL', payload: data.model });
  }

  return actions;
}

function handleSystemConnected(_event: RpcEvent): AppAction[] {
  return [
    { type: 'SET_CONNECTION_STATUS', payload: 'connected' },
    { type: 'SET_CONNECTION_ERROR', payload: null },
    { type: 'RESET_RECONNECT_ATTEMPT' },
  ];
}

function handleSystemDisconnected(_event: RpcEvent): AppAction[] {
  return [
    { type: 'SET_CONNECTION_STATUS', payload: 'disconnected' },
  ];
}

function handleSystemError(event: RpcEvent): AppAction[] {
  const { message } = event.data as { code?: string; message?: string };

  return [
    { type: 'SET_CONNECTION_STATUS', payload: 'error' },
    { type: 'SET_CONNECTION_ERROR', payload: message ?? 'Unknown error' },
  ];
}

// =============================================================================
// Event Type to Handler Map
// =============================================================================

const eventHandlers: Partial<Record<RpcEventType, EventMapper>> = {
  'agent.turn_start': handleTurnStart,
  'agent.turn_end': handleTurnEnd,
  'agent.text_delta': handleTextDelta,
  'agent.thinking_delta': handleThinkingDelta,
  'agent.tool_start': handleToolStart,
  'agent.tool_end': handleToolEnd,
  'agent.error': handleAgentError,
  'agent.complete': handleAgentComplete,
  'session.created': handleSessionCreated,
  'session.ended': handleSessionEnded,
  'session.updated': handleSessionUpdated,
  'system.connected': handleSystemConnected,
  'system.disconnected': handleSystemDisconnected,
  'system.error': handleSystemError,
};

// =============================================================================
// Main Mapper Function
// =============================================================================

/**
 * Map an RPC event to state actions
 */
export function mapEventToActions(event: RpcEvent): AppAction[] {
  const handler = eventHandlers[event.type as RpcEventType];
  if (handler) {
    return handler(event);
  }
  return [];
}

/**
 * Create a dispatch function that handles RPC events
 */
export function createEventDispatcher(
  dispatch: React.Dispatch<AppAction>,
): (event: RpcEvent) => void {
  return (event: RpcEvent) => {
    const actions = mapEventToActions(event);
    for (const action of actions) {
      dispatch(action);
    }
  };
}

/**
 * Finalize streaming content into a message
 */
export function finalizeStreamingMessage(
  streamingContent: string,
  _thinkingText?: string,
): DisplayMessage {
  return {
    id: `msg_assistant_${Date.now()}`,
    role: 'assistant',
    content: streamingContent,
    timestamp: new Date().toISOString(),
  };
}
