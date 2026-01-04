/**
 * @fileoverview RPC Test Fixtures
 *
 * Factory functions for creating RPC responses and events for testing.
 */

import type {
  RpcResponse,
  RpcEvent,
  SessionCreateResult,
  SessionResumeResult,
  SessionListResult,
  SessionDeleteResult,
  SessionForkResult,
  SessionRewindResult,
  AgentPromptResult,
  AgentAbortResult,
  AgentGetStateResult,
  ModelSwitchResult,
  ModelListResult,
  SystemPingResult,
  SystemGetInfoResult,
  AgentTextDeltaEvent,
  AgentThinkingDeltaEvent,
  AgentToolStartEvent,
  AgentToolEndEvent,
  AgentCompleteEvent,
} from '@tron/core';

// =============================================================================
// Response Factories
// =============================================================================

export function createResponse<T>(
  id: string,
  result: T,
  success = true,
): RpcResponse<T> {
  return { id, success, result };
}

export function createErrorResponse(
  id: string,
  code: string,
  message: string,
): RpcResponse {
  return {
    id,
    success: false,
    error: { code, message },
  };
}

// =============================================================================
// Session Response Factories
// =============================================================================

export function createSessionCreateResponse(
  id: string,
  overrides: Partial<SessionCreateResult> = {},
): RpcResponse<SessionCreateResult> {
  return createResponse(id, {
    sessionId: `session_${Date.now()}`,
    model: 'claude-sonnet-4-20250514',
    createdAt: new Date().toISOString(),
    ...overrides,
  });
}

export function createSessionResumeResponse(
  id: string,
  overrides: Partial<SessionResumeResult> = {},
): RpcResponse<SessionResumeResult> {
  return createResponse(id, {
    sessionId: `session_${Date.now()}`,
    model: 'claude-sonnet-4-20250514',
    messageCount: 5,
    lastActivity: new Date().toISOString(),
    ...overrides,
  });
}

export function createSessionListResponse(
  id: string,
  sessions: SessionListResult['sessions'] = [],
): RpcResponse<SessionListResult> {
  return createResponse(id, { sessions });
}

export function createSessionDeleteResponse(
  id: string,
  deleted = true,
): RpcResponse<SessionDeleteResult> {
  return createResponse(id, { deleted });
}

export function createSessionForkResponse(
  id: string,
  overrides: Partial<SessionForkResult> = {},
): RpcResponse<SessionForkResult> {
  return createResponse(id, {
    newSessionId: `session_fork_${Date.now()}`,
    forkedFrom: 'session_original',
    messageCount: 3,
    ...overrides,
  });
}

export function createSessionRewindResponse(
  id: string,
  overrides: Partial<SessionRewindResult> = {},
): RpcResponse<SessionRewindResult> {
  return createResponse(id, {
    sessionId: 'session_123',
    newMessageCount: 5,
    removedCount: 3,
    ...overrides,
  });
}

// =============================================================================
// Agent Response Factories
// =============================================================================

export function createAgentPromptResponse(
  id: string,
  acknowledged = true,
): RpcResponse<AgentPromptResult> {
  return createResponse(id, { acknowledged });
}

export function createAgentAbortResponse(
  id: string,
  aborted = true,
): RpcResponse<AgentAbortResult> {
  return createResponse(id, { aborted });
}

export function createAgentGetStateResponse(
  id: string,
  overrides: Partial<AgentGetStateResult> = {},
): RpcResponse<AgentGetStateResult> {
  return createResponse(id, {
    isRunning: false,
    currentTurn: 1,
    messageCount: 10,
    tokenUsage: { input: 1000, output: 500 },
    model: 'claude-sonnet-4-20250514',
    tools: ['Read', 'Write', 'Bash'],
    ...overrides,
  });
}

// =============================================================================
// Model Response Factories
// =============================================================================

export function createModelSwitchResponse(
  id: string,
  previousModel: string,
  newModel: string,
): RpcResponse<ModelSwitchResult> {
  return createResponse(id, { previousModel, newModel });
}

export function createModelListResponse(
  id: string,
  models: ModelListResult['models'] = [],
): RpcResponse<ModelListResult> {
  const defaultModels: ModelListResult['models'] = [
    {
      id: 'claude-sonnet-4-20250514',
      name: 'Claude Sonnet 4',
      provider: 'anthropic',
      contextWindow: 200000,
      supportsThinking: true,
      supportsImages: true,
    },
    {
      id: 'claude-opus-4-20250514',
      name: 'Claude Opus 4',
      provider: 'anthropic',
      contextWindow: 200000,
      supportsThinking: true,
      supportsImages: true,
    },
    {
      id: 'claude-haiku-3-5',
      name: 'Claude Haiku 3.5',
      provider: 'anthropic',
      contextWindow: 200000,
      supportsThinking: false,
      supportsImages: true,
    },
  ];

  return createResponse(id, { models: models.length > 0 ? models : defaultModels });
}

// =============================================================================
// System Response Factories
// =============================================================================

export function createSystemPingResponse(id: string): RpcResponse<SystemPingResult> {
  return createResponse(id, {
    pong: true as const,
    timestamp: new Date().toISOString(),
  });
}

export function createSystemGetInfoResponse(
  id: string,
  overrides: Partial<SystemGetInfoResult> = {},
): RpcResponse<SystemGetInfoResult> {
  return createResponse(id, {
    version: '1.0.0',
    uptime: 3600000,
    activeSessions: 1,
    memoryUsage: {
      heapUsed: 50 * 1024 * 1024,
      heapTotal: 100 * 1024 * 1024,
    },
    ...overrides,
  });
}

// =============================================================================
// Event Factories
// =============================================================================

export function createEvent<T>(
  type: string,
  data: T,
  sessionId?: string,
): RpcEvent<string, T> {
  return {
    type,
    sessionId,
    timestamp: new Date().toISOString(),
    data,
  };
}

// =============================================================================
// Agent Event Factories
// =============================================================================

export function createTurnStartEvent(sessionId: string): RpcEvent {
  return createEvent('agent.turn_start', { turn: 1 }, sessionId);
}

export function createTurnEndEvent(sessionId: string): RpcEvent {
  return createEvent('agent.turn_end', { turn: 1 }, sessionId);
}

export function createTextDeltaEvent(
  sessionId: string,
  delta: string,
  accumulated?: string,
): RpcEvent<string, AgentTextDeltaEvent> {
  return createEvent('agent.text_delta', { delta, accumulated }, sessionId);
}

export function createThinkingDeltaEvent(
  sessionId: string,
  delta: string,
): RpcEvent<string, AgentThinkingDeltaEvent> {
  return createEvent('agent.thinking_delta', { delta }, sessionId);
}

export function createToolStartEvent(
  sessionId: string,
  overrides: Partial<AgentToolStartEvent> = {},
): RpcEvent<string, AgentToolStartEvent> {
  return createEvent(
    'agent.tool_start',
    {
      toolCallId: `tool_${Date.now()}`,
      toolName: 'Read',
      arguments: { file_path: '/test/file.ts' },
      ...overrides,
    },
    sessionId,
  );
}

export function createToolEndEvent(
  sessionId: string,
  overrides: Partial<AgentToolEndEvent> = {},
): RpcEvent<string, AgentToolEndEvent> {
  return createEvent(
    'agent.tool_end',
    {
      toolCallId: `tool_${Date.now()}`,
      toolName: 'Read',
      duration: 150,
      success: true,
      output: 'File contents here',
      ...overrides,
    },
    sessionId,
  );
}

export function createAgentErrorEvent(
  sessionId: string,
  message: string,
): RpcEvent {
  return createEvent('agent.error', { message }, sessionId);
}

export function createAgentCompleteEvent(
  sessionId: string,
  overrides: Partial<AgentCompleteEvent> = {},
): RpcEvent<string, AgentCompleteEvent> {
  return createEvent(
    'agent.complete',
    {
      turns: 1,
      tokenUsage: { input: 500, output: 250 },
      success: true,
      ...overrides,
    },
    sessionId,
  );
}

// =============================================================================
// Session Event Factories
// =============================================================================

export function createSessionCreatedEvent(
  sessionId: string,
  model = 'claude-sonnet-4-20250514',
): RpcEvent {
  return createEvent('session.created', { sessionId, model }, sessionId);
}

export function createSessionEndedEvent(sessionId: string): RpcEvent {
  return createEvent('session.ended', { sessionId }, sessionId);
}

export function createSessionUpdatedEvent(
  sessionId: string,
  updates: Record<string, unknown>,
): RpcEvent {
  return createEvent('session.updated', { sessionId, ...updates }, sessionId);
}

// =============================================================================
// System Event Factories
// =============================================================================

export function createSystemConnectedEvent(clientId: string): RpcEvent {
  return createEvent('system.connected', { clientId });
}

export function createSystemDisconnectedEvent(reason?: string): RpcEvent {
  return createEvent('system.disconnected', { reason });
}

export function createSystemErrorEvent(code: string, message: string): RpcEvent {
  return createEvent('system.error', { code, message });
}

// =============================================================================
// Streaming Simulation
// =============================================================================

/**
 * Simulate streaming text in chunks
 */
export function createTextStream(
  sessionId: string,
  text: string,
  chunkSize = 10,
): RpcEvent<string, AgentTextDeltaEvent>[] {
  const events: RpcEvent<string, AgentTextDeltaEvent>[] = [];
  let accumulated = '';

  for (let i = 0; i < text.length; i += chunkSize) {
    const delta = text.slice(i, i + chunkSize);
    accumulated += delta;
    events.push(createTextDeltaEvent(sessionId, delta, accumulated));
  }

  return events;
}

/**
 * Create a complete agent turn sequence
 */
export function createAgentTurnSequence(
  sessionId: string,
  text: string,
  options: {
    withThinking?: boolean;
    thinkingText?: string;
    withTool?: boolean;
    toolName?: string;
  } = {},
): RpcEvent[] {
  const events: RpcEvent[] = [];

  // Turn start
  events.push(createTurnStartEvent(sessionId));

  // Thinking (optional)
  if (options.withThinking) {
    const thinkingText = options.thinkingText ?? 'Analyzing the request...';
    events.push(createThinkingDeltaEvent(sessionId, thinkingText));
  }

  // Tool call (optional)
  if (options.withTool) {
    const toolName = options.toolName ?? 'Read';
    events.push(createToolStartEvent(sessionId, { toolName }));
    events.push(createToolEndEvent(sessionId, { toolName, success: true }));
  }

  // Text streaming
  events.push(...createTextStream(sessionId, text));

  // Turn end
  events.push(createTurnEndEvent(sessionId));

  // Complete
  events.push(createAgentCompleteEvent(sessionId));

  return events;
}
