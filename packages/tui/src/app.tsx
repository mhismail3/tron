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
import { SlashCommandMenu } from './components/SlashCommandMenu.js';
import {
  BUILT_IN_COMMANDS,
  isSlashCommandInput,
  parseSlashCommand,
  filterCommands,
  type SlashCommand,
} from './commands/slash-commands.js';
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
  formatError,
  parseError,
  type AgentOptions,
  type TronEvent,
  type Message,
} from '@tron/core';
import { debugLog } from './debug/index.js';

// =============================================================================
// State Management
// =============================================================================

const MAX_HISTORY = 100;

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
  showSlashMenu: false,
  slashMenuIndex: 0,
  promptHistory: [],
  historyIndex: -1,
  temporaryInput: '',
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
    case 'SHOW_SLASH_MENU':
      return { ...state, showSlashMenu: action.payload, slashMenuIndex: 0 };
    case 'SET_SLASH_MENU_INDEX':
      return { ...state, slashMenuIndex: action.payload };
    case 'ADD_TO_HISTORY': {
      const trimmed = action.payload.trim();
      if (!trimmed) return state;
      // Don't add consecutive duplicates
      if (state.promptHistory.length > 0 &&
          state.promptHistory[state.promptHistory.length - 1] === trimmed) {
        return { ...state, historyIndex: -1, temporaryInput: '' };
      }
      const newHistory = [...state.promptHistory, trimmed];
      // Enforce max limit
      const limitedHistory = newHistory.length > MAX_HISTORY
        ? newHistory.slice(-MAX_HISTORY)
        : newHistory;
      return {
        ...state,
        promptHistory: limitedHistory,
        historyIndex: -1,
        temporaryInput: '',
      };
    }
    case 'HISTORY_UP': {
      if (state.promptHistory.length === 0) return state;
      if (state.historyIndex === -1) {
        // Start navigating from most recent
        const newIndex = state.promptHistory.length - 1;
        return {
          ...state,
          historyIndex: newIndex,
          input: state.promptHistory[newIndex] ?? '',
        };
      } else if (state.historyIndex > 0) {
        // Move to older entry
        const newIndex = state.historyIndex - 1;
        return {
          ...state,
          historyIndex: newIndex,
          input: state.promptHistory[newIndex] ?? '',
        };
      }
      return state; // Already at beginning
    }
    case 'HISTORY_DOWN': {
      if (state.promptHistory.length === 0 || state.historyIndex === -1) {
        return state;
      }
      if (state.historyIndex < state.promptHistory.length - 1) {
        // Move to newer entry
        const newIndex = state.historyIndex + 1;
        return {
          ...state,
          historyIndex: newIndex,
          input: state.promptHistory[newIndex] ?? '',
        };
      } else {
        // Past end - restore temporary input
        return {
          ...state,
          historyIndex: -1,
          input: state.temporaryInput,
        };
      }
    }
    case 'SET_TEMPORARY_INPUT':
      return { ...state, temporaryInput: action.payload };
    case 'RESET_HISTORY_NAVIGATION':
      return { ...state, historyIndex: -1 };
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
        ephemeral: config.ephemeral,
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

  // Handle input change - detect slash commands
  const handleInputChange = useCallback((value: string) => {
    dispatch({ type: 'SET_INPUT', payload: value });

    // Reset history navigation when user types
    if (state.historyIndex !== -1) {
      dispatch({ type: 'RESET_HISTORY_NAVIGATION' });
    }

    // Save current input as temporary (for restoring after history navigation)
    dispatch({ type: 'SET_TEMPORARY_INPUT', payload: value });

    // Show/hide slash menu based on input
    if (isSlashCommandInput(value)) {
      dispatch({ type: 'SHOW_SLASH_MENU', payload: true });
    } else {
      dispatch({ type: 'SHOW_SLASH_MENU', payload: false });
    }
  }, [state.historyIndex]);

  // Handle submit
  const handleSubmit = useCallback(async () => {
    // Don't submit if slash menu is open - the useInput hook handles Enter for that
    if (state.showSlashMenu) {
      return;
    }

    if (!state.input.trim() || state.isProcessing || !agentRef.current || !tuiSessionRef.current) {
      return;
    }

    const prompt = state.input.trim();
    dispatch({ type: 'CLEAR_INPUT' });
    dispatch({ type: 'ADD_TO_HISTORY', payload: prompt }); // Add to history
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
        // Parse error for user-friendly message
        const parsed = parseError(result.error ?? 'Unknown error');
        const errorMessage = formatError(result.error ?? 'Unknown error');

        // Add error message to chat for visibility
        dispatch({
          type: 'ADD_MESSAGE',
          payload: {
            id: `msg_${messageIdRef.current++}`,
            role: 'system',
            content: `❌ Error: ${errorMessage}${parsed.isRetryable ? '\n(This error may be temporary - try again)' : ''}`,
            timestamp: new Date().toISOString(),
          },
        });

        dispatch({ type: 'SET_ERROR', payload: errorMessage });
        // Set status back to Ready so user can continue
        dispatch({ type: 'SET_STATUS', payload: 'Ready' });
      } else {
        dispatch({ type: 'SET_ERROR', payload: null }); // Clear any previous error
        dispatch({ type: 'SET_STATUS', payload: 'Ready' });
      }
    } catch (error) {
      // Parse error for user-friendly message
      const parsed = parseError(error);
      const errorMessage = formatError(error);

      // Add error message to chat for visibility
      dispatch({
        type: 'ADD_MESSAGE',
        payload: {
          id: `msg_${messageIdRef.current++}`,
          role: 'system',
          content: `❌ Error: ${errorMessage}${parsed.isRetryable ? '\n(This error may be temporary - try again)' : ''}`,
          timestamp: new Date().toISOString(),
        },
      });

      dispatch({ type: 'SET_ERROR', payload: errorMessage });
      // Set status back to Ready so user can continue
      dispatch({ type: 'SET_STATUS', payload: 'Ready' });
    } finally {
      // Always clean up state so user can continue
      dispatch({ type: 'SET_PROCESSING', payload: false });
      dispatch({ type: 'SET_ACTIVE_TOOL', payload: null });
      dispatch({ type: 'CLEAR_STREAMING' });
      streamingContentRef.current = '';
    }
  }, [state.input, state.isProcessing, state.showSlashMenu]);

  // Execute a slash command
  const executeSlashCommand = useCallback((command: SlashCommand) => {
    dispatch({ type: 'SHOW_SLASH_MENU', payload: false });
    dispatch({ type: 'CLEAR_INPUT' });

    switch (command.name) {
      case 'help':
        dispatch({
          type: 'ADD_MESSAGE',
          payload: {
            id: `msg_${messageIdRef.current++}`,
            role: 'system',
            content: `Available commands:\n${BUILT_IN_COMMANDS.map(c =>
              `  /${c.name}${c.shortcut ? ` (${c.shortcut})` : ''} - ${c.description}`
            ).join('\n')}\n\nKeyboard shortcuts:\n  Ctrl+C - Exit\n  Ctrl+L - Clear screen\n  ↑/↓ - Navigate command menu\n  Enter - Select command\n  Esc - Cancel`,
            timestamp: new Date().toISOString(),
          },
        });
        break;

      case 'clear':
        dispatch({ type: 'RESET' });
        break;

      case 'model': {
        const agent = agentRef.current;
        const currentModel = agent?.getModel() ?? config.model ?? DEFAULT_MODEL;
        const currentProvider = agent?.getProviderType() ?? 'anthropic';
        dispatch({
          type: 'ADD_MESSAGE',
          payload: {
            id: `msg_${messageIdRef.current++}`,
            role: 'system',
            content: `Current model: ${currentModel}\nProvider: ${currentProvider}\n\nTo switch models, use: /model <model-id>\nExamples:\n  /model gpt-4o (OpenAI)\n  /model gemini-2.5-flash (Google)\n  /model claude-sonnet-4-20250514 (Anthropic)`,
            timestamp: new Date().toISOString(),
          },
        });
        break;
      }

      case 'context': {
        const contextMarkdown = tuiSessionRef.current?.getContextAuditMarkdown() ?? 'No context audit available';
        dispatch({
          type: 'ADD_MESSAGE',
          payload: {
            id: `msg_${messageIdRef.current++}`,
            role: 'system',
            content: contextMarkdown,
            timestamp: new Date().toISOString(),
          },
        });
        break;
      }

      case 'session': {
        const session = tuiSessionRef.current;
        const messageCount = session?.getMessageCount() ?? 0;
        const tokenEstimate = session?.getTokenEstimate() ?? 0;
        const compactionConfig = session?.getCompactionConfig();
        const needsCompaction = session?.needsCompaction() ?? false;

        const sessionInfo = [
          `Session ID: ${state.sessionId ?? 'N/A'}`,
          `Messages: ${messageCount}`,
          '',
          '**Token Usage**',
          `  Input: ${state.tokenUsage.input.toLocaleString()} tokens`,
          `  Output: ${state.tokenUsage.output.toLocaleString()} tokens`,
          `  Total: ${(state.tokenUsage.input + state.tokenUsage.output).toLocaleString()} tokens`,
          '',
          '**Context Estimate**',
          `  Current messages: ~${tokenEstimate.toLocaleString()} tokens`,
          `  Compaction threshold: ${compactionConfig?.maxTokens?.toLocaleString() ?? 'N/A'} tokens`,
          `  Needs compaction: ${needsCompaction ? 'Yes' : 'No'}`,
        ].join('\n');

        dispatch({
          type: 'ADD_MESSAGE',
          payload: {
            id: `msg_${messageIdRef.current++}`,
            role: 'system',
            content: sessionInfo,
            timestamp: new Date().toISOString(),
          },
        });
        break;
      }

      case 'history':
        dispatch({
          type: 'ADD_MESSAGE',
          payload: {
            id: `msg_${messageIdRef.current++}`,
            role: 'system',
            content: `${state.messages.length} messages in history`,
            timestamp: new Date().toISOString(),
          },
        });
        break;

      case 'resume':
        dispatch({
          type: 'ADD_MESSAGE',
          payload: {
            id: `msg_${messageIdRef.current++}`,
            role: 'system',
            content: `Session resume functionality:\n\nTo resume a session, use:\n  tron --continue     # Resume most recent session\n  tron --resume <id>  # Resume specific session\n\nSession files are stored in ~/.tron/sessions/`,
            timestamp: new Date().toISOString(),
          },
        });
        break;

      case 'rewind':
        dispatch({
          type: 'ADD_MESSAGE',
          payload: {
            id: `msg_${messageIdRef.current++}`,
            role: 'system',
            content: `Session rewind functionality (coming soon):\n\nThis will allow you to:\n  - Rewind to a specific message in the conversation\n  - Undo recent exchanges\n  - Create a checkpoint before experimental changes`,
            timestamp: new Date().toISOString(),
          },
        });
        break;

      case 'branch':
        dispatch({
          type: 'ADD_MESSAGE',
          payload: {
            id: `msg_${messageIdRef.current++}`,
            role: 'system',
            content: `Session branching functionality (coming soon):\n\nThis will allow you to:\n  - Fork the session at any point\n  - Explore alternative approaches\n  - Compare different solutions`,
            timestamp: new Date().toISOString(),
          },
        });
        break;

      case 'exit':
        handleExit();
        break;

      default:
        dispatch({
          type: 'ADD_MESSAGE',
          payload: {
            id: `msg_${messageIdRef.current++}`,
            role: 'system',
            content: `Unknown command: /${command.name}`,
            timestamp: new Date().toISOString(),
          },
        });
    }
  }, [config.model, config.workingDirectory, state.sessionId, state.tokenUsage, state.messages.length, handleExit]);

  // Get filtered commands for menu
  const getFilteredCommands = useCallback(() => {
    const { commandName } = parseSlashCommand(state.input);
    return filterCommands(BUILT_IN_COMMANDS, commandName);
  }, [state.input]);

  // Handle keyboard input
  // History navigation callbacks
  const handleHistoryUp = useCallback(() => {
    if (state.historyIndex === -1) {
      // Save current input before starting navigation
      dispatch({ type: 'SET_TEMPORARY_INPUT', payload: state.input });
    }
    dispatch({ type: 'HISTORY_UP' });
  }, [state.historyIndex, state.input]);

  const handleHistoryDown = useCallback(() => {
    dispatch({ type: 'HISTORY_DOWN' });
  }, []);

  useInput((input, key) => {
    // Ctrl+C to exit (with proper session end)
    if (input === 'c' && key.ctrl) {
      handleExit();
    }

    // Ctrl+L to clear display
    if (input === 'l' && key.ctrl) {
      dispatch({ type: 'RESET' });
    }

    // Slash menu navigation
    if (state.showSlashMenu && !state.isProcessing) {
      const filteredCommands = getFilteredCommands();

      if (key.upArrow) {
        const newIndex = state.slashMenuIndex > 0
          ? state.slashMenuIndex - 1
          : filteredCommands.length - 1;
        dispatch({ type: 'SET_SLASH_MENU_INDEX', payload: newIndex });
      }

      if (key.downArrow) {
        const newIndex = state.slashMenuIndex < filteredCommands.length - 1
          ? state.slashMenuIndex + 1
          : 0;
        dispatch({ type: 'SET_SLASH_MENU_INDEX', payload: newIndex });
      }

      if (key.return && filteredCommands.length > 0) {
        const selectedCommand = filteredCommands[state.slashMenuIndex];
        if (selectedCommand) {
          executeSlashCommand(selectedCommand);
        }
      }

      if (key.escape) {
        dispatch({ type: 'SHOW_SLASH_MENU', payload: false });
        dispatch({ type: 'CLEAR_INPUT' });
      }
    } else if (!state.isProcessing) {
      // History navigation when not in slash menu mode
      if (key.upArrow) {
        handleHistoryUp();
      }
      if (key.downArrow) {
        handleHistoryDown();
      }
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

      {/* Slash Command Menu */}
      {state.showSlashMenu && !state.isProcessing && (
        <SlashCommandMenu
          commands={BUILT_IN_COMMANDS}
          filter={parseSlashCommand(state.input).commandName}
          selectedIndex={state.slashMenuIndex}
          onSelect={executeSlashCommand}
          onCancel={() => {
            dispatch({ type: 'SHOW_SLASH_MENU', payload: false });
            dispatch({ type: 'CLEAR_INPUT' });
          }}
          maxVisible={5}
        />
      )}

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
