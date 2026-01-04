/**
 * @fileoverview Custom Test Render with Providers
 *
 * Provides a custom render function that wraps components with all
 * necessary providers for testing.
 */

import React, { type ReactElement, type ReactNode } from 'react';
import { render, type RenderOptions, type RenderResult } from '@testing-library/react';
import { ChatProvider } from '../../src/store/context.js';
import type { AppState } from '../../src/store/types.js';

// =============================================================================
// Types
// =============================================================================

export interface CustomRenderOptions extends Omit<RenderOptions, 'wrapper'> {
  /** Initial state overrides for ChatProvider */
  initialState?: Partial<AppState>;
  /** Additional wrapper components */
  wrapper?: React.ComponentType<{ children: ReactNode }>;
}

// =============================================================================
// Custom Render
// =============================================================================

/**
 * Custom render that wraps component with ChatProvider
 */
function customRender(
  ui: ReactElement,
  options: CustomRenderOptions = {},
): RenderResult {
  const { initialState, wrapper: Wrapper, ...renderOptions } = options;

  function AllProviders({ children }: { children: ReactNode }): ReactElement {
    const content = (
      <ChatProvider initialState={initialState}>
        {children}
      </ChatProvider>
    );

    return Wrapper ? <Wrapper>{content}</Wrapper> : content;
  }

  return render(ui, { wrapper: AllProviders, ...renderOptions });
}

// =============================================================================
// State Helpers
// =============================================================================

/**
 * Create a partial state with connected status
 */
export function createConnectedState(
  overrides: Partial<AppState> = {},
): Partial<AppState> {
  return {
    isInitialized: true,
    connection: {
      status: 'connected',
      error: null,
      reconnectAttempt: 0,
    },
    ...overrides,
  };
}

/**
 * Create a partial state with a session
 */
export function createSessionState(
  sessionId: string,
  overrides: Partial<AppState> = {},
): Partial<AppState> {
  return {
    ...createConnectedState(),
    sessionId,
    status: 'Ready',
    ...overrides,
  };
}

/**
 * Create a partial state with messages
 */
export function createMessagesState(
  sessionId: string,
  messages: AppState['messages'],
  overrides: Partial<AppState> = {},
): Partial<AppState> {
  return {
    ...createSessionState(sessionId),
    messages,
    ...overrides,
  };
}

/**
 * Create a partial state for processing
 */
export function createProcessingState(
  sessionId: string,
  overrides: Partial<AppState> = {},
): Partial<AppState> {
  return {
    ...createSessionState(sessionId),
    isProcessing: true,
    status: 'Processing',
    ...overrides,
  };
}

/**
 * Create a partial state for streaming
 */
export function createStreamingState(
  sessionId: string,
  streamingContent: string,
  overrides: Partial<AppState> = {},
): Partial<AppState> {
  return {
    ...createProcessingState(sessionId),
    isStreaming: true,
    streamingContent,
    ...overrides,
  };
}

// =============================================================================
// Message Factories
// =============================================================================

let messageIdCounter = 0;

/**
 * Create a user message
 */
export function createUserMessage(
  content: string,
  overrides: Partial<AppState['messages'][0]> = {},
): AppState['messages'][0] {
  return {
    id: `msg_user_${++messageIdCounter}`,
    role: 'user',
    content,
    timestamp: new Date().toISOString(),
    ...overrides,
  };
}

/**
 * Create an assistant message
 */
export function createAssistantMessage(
  content: string,
  overrides: Partial<AppState['messages'][0]> = {},
): AppState['messages'][0] {
  return {
    id: `msg_assistant_${++messageIdCounter}`,
    role: 'assistant',
    content,
    timestamp: new Date().toISOString(),
    ...overrides,
  };
}

/**
 * Create a tool message
 */
export function createToolMessage(
  toolName: string,
  content: string,
  status: 'running' | 'success' | 'error' = 'success',
  overrides: Partial<AppState['messages'][0]> = {},
): AppState['messages'][0] {
  return {
    id: `msg_tool_${++messageIdCounter}`,
    role: 'tool',
    content,
    toolName,
    toolStatus: status,
    timestamp: new Date().toISOString(),
    ...overrides,
  };
}

/**
 * Create a system message
 */
export function createSystemMessage(
  content: string,
  overrides: Partial<AppState['messages'][0]> = {},
): AppState['messages'][0] {
  return {
    id: `msg_system_${++messageIdCounter}`,
    role: 'system',
    content,
    timestamp: new Date().toISOString(),
    ...overrides,
  };
}

/**
 * Reset message ID counter (for test isolation)
 */
export function resetMessageIdCounter(): void {
  messageIdCounter = 0;
}

// =============================================================================
// Exports
// =============================================================================

// Re-export everything from @testing-library/react
export * from '@testing-library/react';

// Override render with custom render
export { customRender as render };
