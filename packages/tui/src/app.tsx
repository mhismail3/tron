/**
 * @fileoverview Main Tron App Component
 *
 * The root React component for the Tron TUI.
 */
import React, { useReducer, useCallback, useEffect, useRef } from 'react';
import { Box, useInput, useApp } from 'ink';
import { Header } from './components/Header.js';
import { MessageList } from './components/MessageList.js';
import { InputArea } from './components/InputArea.js';
import { StatusBar } from './components/StatusBar.js';
import type { CliConfig, AppState, AppAction, AnthropicAuth } from './types.js';
import {
  TronAgent,
  ReadTool,
  WriteTool,
  EditTool,
  BashTool,
  type AgentOptions,
} from '@tron/core';

// =============================================================================
// State Management
// =============================================================================

const initialState: AppState = {
  input: '',
  isProcessing: false,
  sessionId: null,
  messages: [],
  status: 'Ready',
  error: null,
  tokenUsage: { input: 0, output: 0 },
  activeTool: null,
};

function reducer(state: AppState, action: AppAction): AppState {
  switch (action.type) {
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
    case 'RESET':
      return { ...initialState, sessionId: state.sessionId };
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

export function App({ config, auth }: AppProps): React.ReactElement {
  const [state, dispatch] = useReducer(reducer, initialState);
  const { exit } = useApp();
  const agentRef = useRef<TronAgent | null>(null);
  const messageIdRef = useRef(0);

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

    agentRef.current = new TronAgent({
      provider: {
        model: config.model ?? 'claude-sonnet-4-20250514',
        auth,
      },
      tools,
      maxTurns: 50,
    }, agentOptions);

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

    return () => {
      agentRef.current = null;
    };
  }, [config, auth]);

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
      dispatch({ type: 'SET_STATUS', payload: 'Thinking...' });

      const currentAssistantId = `msg_${messageIdRef.current++}`;

      // Add placeholder for assistant response
      dispatch({
        type: 'ADD_MESSAGE',
        payload: {
          id: currentAssistantId,
          role: 'assistant',
          content: '',
          timestamp: new Date().toISOString(),
        },
      });

      // Run agent
      const result = await agentRef.current.run(prompt);

      // Update token usage
      dispatch({
        type: 'UPDATE_TOKEN_USAGE',
        payload: {
          input: result.totalTokenUsage.inputTokens,
          output: result.totalTokenUsage.outputTokens,
        },
      });

      // Build assistant content from messages
      let assistantContent = '';
      for (const message of result.messages) {
        if (message.role === 'assistant') {
          for (const block of message.content) {
            if ('text' in block && typeof block.text === 'string') {
              assistantContent += block.text + '\n';
            }
          }
        }
      }

      dispatch({
        type: 'UPDATE_MESSAGE',
        payload: {
          id: currentAssistantId,
          updates: { content: assistantContent.trim() },
        },
      });

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
    }
  }, [state.input, state.isProcessing]);

  // Handle keyboard input
  useInput((input, key) => {
    // Ctrl+C to exit
    if (input === 'c' && key.ctrl) {
      exit();
    }

    // Ctrl+L to clear (could reset messages)
    if (input === 'l' && key.ctrl) {
      dispatch({ type: 'RESET' });
    }
  });

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
      <Box flexDirection="column" flexGrow={1} paddingX={1}>
        <MessageList
          messages={state.messages}
          isProcessing={state.isProcessing}
          activeTool={state.activeTool}
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
