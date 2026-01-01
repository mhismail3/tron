/**
 * @fileoverview Main Tron App Component
 *
 * The root React component for the Tron TUI.
 * Features:
 * - Streaming output from agent events
 * - Animated thinking indicator
 * - Proper initialization state to prevent double render
 * - NO emojis
 */
import React, { useReducer, useCallback, useEffect, useRef } from 'react';
import { Box, Text, useInput, useApp } from 'ink';
import { Header } from './components/Header.js';
import { MessageList } from './components/MessageList.js';
import { InputArea } from './components/InputArea.js';
import { StatusBar } from './components/StatusBar.js';
import type { CliConfig, AppState, AppAction, AnthropicAuth, DisplayMessage } from './types.js';
import {
  TronAgent,
  ReadTool,
  WriteTool,
  EditTool,
  BashTool,
  type AgentOptions,
  type TronEvent,
} from '@tron/core';

// =============================================================================
// State Management
// =============================================================================

const initialState: AppState = {
  isInitialized: false,
  input: '',
  isProcessing: false,
  sessionId: null,
  messages: [],
  status: 'Initializing',
  error: null,
  tokenUsage: { input: 0, output: 0 },
  activeTool: null,
  activeToolInput: null,
  streamingContent: '',
  isStreaming: false,
  thinkingText: '',
};

function reducer(state: AppState, action: AppAction): AppState {
  switch (action.type) {
    case 'SET_INITIALIZED':
      return { ...state, isInitialized: action.payload };
    case 'SET_INPUT':
      return { ...state, input: action.payload };
    case 'CLEAR_INPUT':
      return { ...state, input: '' };
    case 'SET_PROCESSING':
      return { ...state, isProcessing: action.payload };
    case 'SET_SESSION':
      return { ...state, sessionId: action.payload };
    case 'ADD_MESSAGE':
      return { ...state, messages: [...state.messages, action.payload] };
    case 'UPDATE_MESSAGE':
      return {
        ...state,
        messages: state.messages.map((m) =>
          m.id === action.payload.id ? { ...m, ...action.payload.updates } : m
        ),
      };
    case 'SET_STATUS':
      return { ...state, status: action.payload };
    case 'SET_ERROR':
      return { ...state, error: action.payload };
    case 'UPDATE_TOKEN_USAGE':
      return {
        ...state,
        tokenUsage: {
          input: state.tokenUsage.input + action.payload.input,
          output: state.tokenUsage.output + action.payload.output,
        },
      };
    case 'SET_ACTIVE_TOOL':
      return { ...state, activeTool: action.payload };
    case 'SET_ACTIVE_TOOL_INPUT':
      return { ...state, activeToolInput: action.payload };
    case 'APPEND_STREAMING_CONTENT':
      return { ...state, streamingContent: state.streamingContent + action.payload };
    case 'SET_STREAMING':
      return { ...state, isStreaming: action.payload };
    case 'CLEAR_STREAMING':
      return { ...state, streamingContent: '', isStreaming: false, thinkingText: '' };
    case 'SET_THINKING_TEXT':
      return { ...state, thinkingText: action.payload };
    case 'APPEND_THINKING_TEXT':
      return { ...state, thinkingText: state.thinkingText + action.payload };
    case 'RESET':
      return {
        ...initialState,
        isInitialized: true,
        sessionId: state.sessionId,
        status: 'Ready',
        activeToolInput: null,
      };
    default:
      return state;
  }
}

// =============================================================================
// App Component
// =============================================================================

interface AppProps {
  config: CliConfig;
  auth: AnthropicAuth;
}

/**
 * Extract a display-friendly string from tool arguments
 */
function formatToolInput(toolName: string, args: Record<string, unknown> | undefined): string {
  if (!args) return '';

  switch (toolName.toLowerCase()) {
    case 'bash':
      return typeof args.command === 'string' ? args.command : '';
    case 'read':
      return typeof args.file_path === 'string' ? args.file_path : '';
    case 'write':
      return typeof args.file_path === 'string' ? args.file_path : '';
    case 'edit':
      return typeof args.file_path === 'string' ? args.file_path : '';
    default:
      // For other tools, try common argument names
      if (typeof args.path === 'string') return args.path;
      if (typeof args.file === 'string') return args.file;
      if (typeof args.command === 'string') return args.command;
      if (typeof args.query === 'string') return args.query;
      return '';
  }
}

export function App({ config, auth }: AppProps): React.ReactElement {
  const [state, dispatch] = useReducer(reducer, initialState);
  const { exit } = useApp();
  const agentRef = useRef<TronAgent | null>(null);
  const messageIdRef = useRef(0);
  const currentAssistantIdRef = useRef<string | null>(null);
  const currentToolInputRef = useRef<string | null>(null);

  // Handle agent events for streaming
  const handleAgentEvent = useCallback((event: TronEvent) => {
    switch (event.type) {
      case 'turn_start':
        dispatch({ type: 'SET_STATUS', payload: 'Thinking' });
        dispatch({ type: 'SET_STREAMING', payload: true });
        break;

      case 'message_update':
        // Stream text deltas
        if ('content' in event && event.content) {
          dispatch({ type: 'APPEND_STREAMING_CONTENT', payload: event.content });
        }
        break;

      case 'tool_execution_start':
        if ('toolName' in event) {
          const toolInput = formatToolInput(
            event.toolName,
            'arguments' in event ? event.arguments as Record<string, unknown> : undefined
          );
          currentToolInputRef.current = toolInput;
          dispatch({ type: 'SET_ACTIVE_TOOL', payload: event.toolName });
          dispatch({ type: 'SET_ACTIVE_TOOL_INPUT', payload: toolInput });
          dispatch({ type: 'SET_STATUS', payload: `Running ${event.toolName}` });
        }
        break;

      case 'tool_execution_end':
        if ('toolName' in event) {
          // Add tool message to display with the captured tool input
          const toolMsg: DisplayMessage = {
            id: `msg_${messageIdRef.current++}`,
            role: 'tool',
            content: '',
            timestamp: new Date().toISOString(),
            toolName: event.toolName,
            toolStatus: event.isError ? 'error' : 'success',
            toolInput: currentToolInputRef.current ?? undefined,
            duration: 'duration' in event ? event.duration : undefined,
          };
          dispatch({ type: 'ADD_MESSAGE', payload: toolMsg });
          dispatch({ type: 'SET_ACTIVE_TOOL', payload: null });
          dispatch({ type: 'SET_ACTIVE_TOOL_INPUT', payload: null });
          currentToolInputRef.current = null;
          dispatch({ type: 'SET_STATUS', payload: 'Thinking' });
        }
        break;

      case 'turn_end':
        // Finalize the streaming content as a message
        break;

      case 'agent_end':
        dispatch({ type: 'SET_STREAMING', payload: false });
        if ('error' in event && event.error) {
          dispatch({ type: 'SET_ERROR', payload: event.error });
          dispatch({ type: 'SET_STATUS', payload: 'Error' });
        } else {
          dispatch({ type: 'SET_STATUS', payload: 'Ready' });
        }
        break;
    }
  }, []);

  // Initialize agent
  useEffect(() => {
    // Create tools
    const tools = [
      new ReadTool({ workingDirectory: config.workingDirectory }),
      new WriteTool({ workingDirectory: config.workingDirectory }),
      new EditTool({ workingDirectory: config.workingDirectory }),
      new BashTool({ workingDirectory: config.workingDirectory }),
    ];

    const agentOptions: AgentOptions = {
      workingDirectory: config.workingDirectory,
    };

    const agent = new TronAgent(
      {
        provider: {
          model: config.model ?? 'claude-sonnet-4-20250514',
          auth,
        },
        tools,
        maxTurns: 50,
      },
      agentOptions
    );

    // Subscribe to events for streaming
    agent.onEvent(handleAgentEvent);

    agentRef.current = agent;

    // Generate session ID
    const sessionId = `sess_${Date.now().toString(36)}`;
    dispatch({ type: 'SET_SESSION', payload: sessionId });

    // Welcome message
    dispatch({
      type: 'ADD_MESSAGE',
      payload: {
        id: `msg_${messageIdRef.current++}`,
        role: 'system',
        content: `Welcome to Tron! Working in: ${config.workingDirectory}`,
        timestamp: new Date().toISOString(),
      },
    });

    // Mark as initialized - this fixes the double prompt box
    dispatch({ type: 'SET_STATUS', payload: 'Ready' });
    dispatch({ type: 'SET_INITIALIZED', payload: true });

    return () => {
      agentRef.current = null;
    };
  }, [config, auth, handleAgentEvent]);

  // Handle input change
  const handleInputChange = useCallback((value: string) => {
    dispatch({ type: 'SET_INPUT', payload: value });
  }, []);

  // Handle submit
  const handleSubmit = useCallback(async () => {
    if (!state.input.trim() || state.isProcessing || !agentRef.current) {
      return;
    }

    const prompt = state.input.trim();
    dispatch({ type: 'CLEAR_INPUT' });
    dispatch({ type: 'SET_PROCESSING', payload: true });
    dispatch({ type: 'SET_ERROR', payload: null });
    dispatch({ type: 'CLEAR_STREAMING' });

    // Add user message
    dispatch({
      type: 'ADD_MESSAGE',
      payload: {
        id: `msg_${messageIdRef.current++}`,
        role: 'user',
        content: prompt,
        timestamp: new Date().toISOString(),
      },
    });

    try {
      dispatch({ type: 'SET_STATUS', payload: 'Thinking' });

      currentAssistantIdRef.current = `msg_${messageIdRef.current++}`;

      // Run agent (events are streamed via onEvent handler)
      const result = await agentRef.current.run(prompt);

      // Finalize: add the streamed content as an assistant message
      if (state.streamingContent || result.messages.length > 0) {
        // Find the final assistant response
        let finalContent = '';
        for (const message of result.messages) {
          if (message.role === 'assistant') {
            for (const block of message.content) {
              if ('text' in block && typeof block.text === 'string') {
                finalContent += block.text + '\n';
              }
            }
          }
        }

        dispatch({
          type: 'ADD_MESSAGE',
          payload: {
            id: currentAssistantIdRef.current,
            role: 'assistant',
            content: finalContent.trim(),
            timestamp: new Date().toISOString(),
          },
        });
      }

      // Update token usage
      dispatch({
        type: 'UPDATE_TOKEN_USAGE',
        payload: {
          input: result.totalTokenUsage.inputTokens,
          output: result.totalTokenUsage.outputTokens,
        },
      });

      // Clear streaming state
      dispatch({ type: 'CLEAR_STREAMING' });

      if (!result.success) {
        dispatch({ type: 'SET_ERROR', payload: result.error ?? 'Unknown error' });
        dispatch({ type: 'SET_STATUS', payload: 'Error' });
      } else {
        dispatch({ type: 'SET_STATUS', payload: 'Ready' });
      }
    } catch (error) {
      dispatch({
        type: 'SET_ERROR',
        payload: error instanceof Error ? error.message : 'Unknown error',
      });
      dispatch({ type: 'SET_STATUS', payload: 'Error' });
    } finally {
      dispatch({ type: 'SET_PROCESSING', payload: false });
      dispatch({ type: 'SET_ACTIVE_TOOL', payload: null });
      dispatch({ type: 'CLEAR_STREAMING' });
    }
  }, [state.input, state.isProcessing, state.streamingContent]);

  // Handle keyboard input
  useInput((input, key) => {
    // Ctrl+C to exit
    if (input === 'c' && key.ctrl) {
      exit();
    }

    // Ctrl+L to clear
    if (input === 'l' && key.ctrl) {
      dispatch({ type: 'RESET' });
    }
  });

  // Don't render the full UI until initialized - fixes double prompt box
  if (!state.isInitialized) {
    return (
      <Box flexDirection="column" padding={1}>
        <Text color="gray">Initializing...</Text>
      </Box>
    );
  }

  return (
    <Box flexDirection="column" height="100%">
      {/* Header */}
      <Header
        sessionId={state.sessionId}
        workingDirectory={config.workingDirectory}
        model={config.model ?? 'claude-sonnet-4-20250514'}
        tokenUsage={state.tokenUsage}
      />

      {/* Message List */}
      <Box flexDirection="column" flexGrow={1} paddingX={1} overflow="hidden">
        <MessageList
          messages={state.messages}
          isProcessing={state.isProcessing}
          activeTool={state.activeTool}
          activeToolInput={state.activeToolInput}
          streamingContent={state.streamingContent}
          isStreaming={state.isStreaming}
          thinkingText={state.thinkingText}
        />
      </Box>

      {/* Input Area */}
      <InputArea
        value={state.input}
        onChange={handleInputChange}
        onSubmit={handleSubmit}
        isProcessing={state.isProcessing}
      />

      {/* Status Bar */}
      <StatusBar status={state.status} error={state.error} />
    </Box>
  );
}
