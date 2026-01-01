/**
 * @fileoverview Main Tron App Component
 *
 * The root React component for the Tron TUI.
 * Features:
 * - Full session lifecycle management via TuiSession
 * - Context loading from AGENTS.md files
 * - Memory/handoff integration for cross-session learning
 * - Ledger management for continuity
 * - Streaming output from agent events
 * - Animated thinking indicator
 * - Proper session end with handoff creation
 */
import React, { useReducer, useCallback, useEffect, useRef } from 'react';
import { Box, Text, useInput, useApp } from 'ink';
import { Header } from './components/Header.js';
import { MessageList } from './components/MessageList.js';
import { InputArea } from './components/InputArea.js';
import { StatusBar } from './components/StatusBar.js';
import { TuiSession } from './session/tui-session.js';
import type { CliConfig, AppState, AppAction, AnthropicAuth, DisplayMessage } from './types.js';
import * as os from 'os';
import * as path from 'path';
import {
  TronAgent,
  ReadTool,
  WriteTool,
  EditTool,
  BashTool,
  DEFAULT_MODEL,
  type AgentOptions,
  type TronEvent,
  type Message,
} from '@tron/core';
import { debugLog } from './debug/index.js';

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
  const tuiSessionRef = useRef<TuiSession | null>(null);
  const messageIdRef = useRef(0);
  const currentToolInputRef = useRef<string | null>(null);
  // Track streaming content in a ref for synchronous access in event handler
  const streamingContentRef = useRef<string>('');
  // Track if we're exiting to prevent double-end
  const isExitingRef = useRef(false);

  /**
   * Finalize any pending streaming content as an assistant message.
   * This ensures text appears before tool calls in the correct order.
   */
  const finalizeStreamingContent = useCallback(() => {
    if (streamingContentRef.current.trim()) {
      dispatch({
        type: 'ADD_MESSAGE',
        payload: {
          id: `msg_${messageIdRef.current++}`,
          role: 'assistant',
          content: streamingContentRef.current.trim(),
          timestamp: new Date().toISOString(),
        },
      });
      streamingContentRef.current = '';
      dispatch({ type: 'CLEAR_STREAMING' });
    }
  }, []);

  // Handle agent events for streaming
  const handleAgentEvent = useCallback((event: TronEvent) => {
    switch (event.type) {
      case 'turn_start':
        dispatch({ type: 'SET_STATUS', payload: 'Thinking' });
        dispatch({ type: 'SET_STREAMING', payload: true });
        break;

      case 'message_update':
        // Stream text deltas - track in both ref (for sync access) and state (for display)
        if ('content' in event && event.content) {
          streamingContentRef.current += event.content;
          dispatch({ type: 'APPEND_STREAMING_CONTENT', payload: event.content });
        }
        break;

      case 'tool_execution_start':
        if ('toolName' in event) {
          // CRITICAL: Finalize any pending streaming content BEFORE showing the tool
          // This ensures text appears in chronological order (text first, then tool)
          finalizeStreamingContent();

          const toolInput = formatToolInput(
            event.toolName,
            'arguments' in event ? event.arguments as Record<string, unknown> : undefined
          );
          currentToolInputRef.current = toolInput;
          dispatch({ type: 'SET_ACTIVE_TOOL', payload: event.toolName });
          dispatch({ type: 'SET_ACTIVE_TOOL_INPUT', payload: toolInput });
          dispatch({ type: 'SET_STATUS', payload: `Running ${event.toolName}` });

          // Track working files in ledger
          if (tuiSessionRef.current && event.toolName.toLowerCase() !== 'bash') {
            const filePath = toolInput;
            if (filePath) {
              tuiSessionRef.current.addWorkingFile(filePath).catch(() => {});
            }
          }
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
        // Finalize any remaining streaming content at end of turn
        // This handles cases where text comes after tool calls
        finalizeStreamingContent();
        break;

      case 'agent_end':
        // Finalize any remaining streaming content before ending
        finalizeStreamingContent();
        dispatch({ type: 'SET_STREAMING', payload: false });
        if ('error' in event && event.error) {
          dispatch({ type: 'SET_ERROR', payload: event.error });
          dispatch({ type: 'SET_STATUS', payload: 'Error' });
        } else {
          dispatch({ type: 'SET_STATUS', payload: 'Ready' });
        }
        break;
    }
  }, [finalizeStreamingContent]);

  // Initialize session and agent
  useEffect(() => {
    const initializeSession = async () => {
      // Create TuiSession for unified session management
      const globalTronDir = path.join(os.homedir(), '.tron');

      const tuiSession = new TuiSession({
        workingDirectory: config.workingDirectory,
        tronDir: globalTronDir,
        model: config.model ?? DEFAULT_MODEL,
        provider: config.provider ?? 'anthropic',
      });

      debugLog.session('init', {
        workingDirectory: config.workingDirectory,
        model: config.model ?? DEFAULT_MODEL,
        tronDir: globalTronDir,
      });

      tuiSessionRef.current = tuiSession;

      // Initialize session (loads context, ledger, handoffs)
      const initResult = await tuiSession.initialize();

      // Create tools
      const tools = [
        new ReadTool({ workingDirectory: config.workingDirectory }),
        new WriteTool({ workingDirectory: config.workingDirectory }),
        new EditTool({ workingDirectory: config.workingDirectory }),
        new BashTool({ workingDirectory: config.workingDirectory }),
      ];

      const agentOptions: AgentOptions = {
        workingDirectory: config.workingDirectory,
        sessionId: initResult.sessionId,
      };

      // Build system prompt with all context sources
      const systemPrompt = tuiSession.buildSystemPrompt();

      const agent = new TronAgent(
        {
          provider: {
            model: config.model ?? DEFAULT_MODEL,
            auth,
          },
          tools,
          maxTurns: 50,
          systemPrompt: systemPrompt || undefined,
        },
        agentOptions
      );

      debugLog.agent('created', {
        sessionId: initResult.sessionId,
        model: config.model ?? DEFAULT_MODEL,
        toolCount: tools.length,
        hasSystemPrompt: !!systemPrompt,
      });

      // Subscribe to events for streaming
      agent.onEvent(handleAgentEvent);

      agentRef.current = agent;

      dispatch({ type: 'SET_SESSION', payload: initResult.sessionId });

      // Welcome message with context info
      let welcomeMsg = `Welcome to Tron! Working in: ${config.workingDirectory}`;

      if (initResult.context?.files.length) {
        welcomeMsg += `\nLoaded context from ${initResult.context.files.length} file(s)`;
      }

      if (initResult.ledger?.goal) {
        welcomeMsg += `\nGoal: ${initResult.ledger.goal}`;
      }

      if (initResult.handoffs?.length) {
        welcomeMsg += `\n${initResult.handoffs.length} previous session(s) available for context`;
      }

      dispatch({
        type: 'ADD_MESSAGE',
        payload: {
          id: `msg_${messageIdRef.current++}`,
          role: 'system',
          content: welcomeMsg,
          timestamp: new Date().toISOString(),
        },
      });

      // Mark as initialized
      dispatch({ type: 'SET_STATUS', payload: 'Ready' });
      dispatch({ type: 'SET_INITIALIZED', payload: true });
    };

    initializeSession().catch((err) => {
      dispatch({ type: 'SET_ERROR', payload: `Failed to initialize: ${err.message}` });
      dispatch({ type: 'SET_STATUS', payload: 'Error' });
    });

    return () => {
      agentRef.current = null;
    };
  }, [config, auth, handleAgentEvent]);

  // Handle graceful exit with session end
  const handleExit = useCallback(async () => {
    if (isExitingRef.current) return;
    isExitingRef.current = true;

    dispatch({ type: 'SET_STATUS', payload: 'Ending session...' });

    if (tuiSessionRef.current) {
      try {
        const endResult = await tuiSessionRef.current.end();
        if (endResult.handoffCreated) {
          console.log(`\nSession handoff created: ${endResult.handoffId}`);
        }
      } catch (error) {
        console.error('\nFailed to end session properly:', error);
      }
    }

    exit();
  }, [exit]);

  // Handle input change
  const handleInputChange = useCallback((value: string) => {
    dispatch({ type: 'SET_INPUT', payload: value });
  }, []);

  // Handle submit
  const handleSubmit = useCallback(async () => {
    if (!state.input.trim() || state.isProcessing || !agentRef.current || !tuiSessionRef.current) {
      return;
    }

    const prompt = state.input.trim();
    dispatch({ type: 'CLEAR_INPUT' });
    dispatch({ type: 'SET_PROCESSING', payload: true });
    dispatch({ type: 'SET_ERROR', payload: null });
    dispatch({ type: 'CLEAR_STREAMING' });
    streamingContentRef.current = '';

    // Create user message
    const userMessage: Message = {
      role: 'user',
      content: prompt,
    };

    // Add user message to UI
    dispatch({
      type: 'ADD_MESSAGE',
      payload: {
        id: `msg_${messageIdRef.current++}`,
        role: 'user',
        content: prompt,
        timestamp: new Date().toISOString(),
      },
    });

    // Persist user message to session file
    await tuiSessionRef.current.addMessage(userMessage);

    // Update ledger with current work
    await tuiSessionRef.current.updateLedger({
      now: `Processing: ${prompt.slice(0, 50)}${prompt.length > 50 ? '...' : ''}`,
    });

    try {
      dispatch({ type: 'SET_STATUS', payload: 'Thinking' });

      // Run agent
      const result = await agentRef.current.run(prompt);

      // Persist all messages from the agent result to session file
      for (const msg of result.messages) {
        if (msg.role === 'user') continue;
        await tuiSessionRef.current.addMessage(msg, result.totalTokenUsage);
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
      streamingContentRef.current = '';

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
      streamingContentRef.current = '';
    }
  }, [state.input, state.isProcessing]);

  // Handle keyboard input
  useInput((input, key) => {
    // Ctrl+C to exit (with proper session end)
    if (input === 'c' && key.ctrl) {
      handleExit();
    }

    // Ctrl+L to clear display
    if (input === 'l' && key.ctrl) {
      dispatch({ type: 'RESET' });
    }
  });

  // Don't render the full UI until initialized
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
        model={config.model ?? DEFAULT_MODEL}
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
