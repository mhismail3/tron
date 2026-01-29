/**
 * @fileoverview Main Tron App Component
 *
 * The root React component for the Tron TUI.
 * Features:
 * - Full session lifecycle management via TuiSession
 * - Context loading from AGENTS.md files
 * - Memory/handoff integration for cross-session learning
 * - Streaming output from agent events
 * - Animated thinking indicator
 * - Proper session end with handoff creation
 */
import React, { useReducer, useCallback, useEffect, useRef } from 'react';
import { Box, Text, useInput, useApp } from 'ink';
import { MessageList } from './components/MessageList.js';
import { StatusBar } from './components/StatusBar.js';
import { SlashCommandMenu } from './components/SlashCommandMenu.js';
import { ModelSwitcher } from './components/ModelSwitcher.js';
import { PromptBox } from './components/PromptBox.js';
import {
  BUILT_IN_COMMANDS,
  isSlashCommandInput,
  parseSlashCommand,
  filterCommands,
  type SlashCommand,
} from './commands/slash-commands.js';
import { EventStoreTuiSession } from './session/eventstore-tui-session.js';
import type { CliConfig, AppState, AppAction, AnthropicAuth, DisplayMessage, MenuStackEntry } from './types.js';
import * as os from 'os';
import * as path from 'path';
import { exec } from 'child_process';
import { promisify } from 'util';
import {
  TronAgent,
  ReadTool,
  WriteTool,
  EditTool,
  BashTool,
  SearchTool,
  DEFAULT_MODEL,
  ANTHROPIC_MODELS,
  formatError,
  parseError,
  EventStore,
  type AgentOptions,
  type TronEvent,
  type Message,
  type ModelInfo,
} from '@tron/agent';
import { debugLog } from './debug/index.js';
import { inkColors } from './theme.js';
import { formatToolOutput } from './utils/tool-output-formatter.js';

const execAsync = promisify(exec);

/**
 * Get the git branch name for a directory
 */
async function getGitBranch(cwd: string): Promise<string | null> {
  try {
    const { stdout } = await execAsync('git rev-parse --abbrev-ref HEAD', { cwd });
    const branch = stdout.trim();
    return branch || null;
  } catch {
    return null;
  }
}

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
  menuStack: [],
  promptHistory: [],
  historyIndex: -1,
  temporaryInput: '',
  currentModel: DEFAULT_MODEL,
  gitBranch: null,
  queuedMessages: [],
};

// =============================================================================
// Menu Stack Helpers
// =============================================================================

/** Get the currently active menu (top of stack) */
function getCurrentMenu(stack: MenuStackEntry[]): MenuStackEntry | null {
  return stack.length > 0 ? stack[stack.length - 1]! : null;
}

/** Check if a specific menu is active (at top of stack) */
function isMenuActive(stack: MenuStackEntry[], menuId: string): boolean {
  const current = getCurrentMenu(stack);
  return current?.id === menuId;
}

/** Check if any menu is open */
function isAnyMenuOpen(stack: MenuStackEntry[]): boolean {
  return stack.length > 0;
}

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
    case 'SET_TOKEN_USAGE':
      // Set token usage directly (payload is cumulative total from agent)
      return {
        ...state,
        tokenUsage: {
          input: action.payload.input,
          output: action.payload.output,
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

    // Menu stack actions for hierarchical navigation
    case 'PUSH_MENU': {
      const { id, index = 0, saveInput = false } = action.payload;
      // Don't push if this menu is already at the top
      const currentMenu = getCurrentMenu(state.menuStack);
      if (currentMenu?.id === id) {
        return state;
      }
      const newEntry: MenuStackEntry = {
        id,
        index,
        savedInput: saveInput ? state.input : undefined,
      };
      return { ...state, menuStack: [...state.menuStack, newEntry] };
    }

    case 'POP_MENU': {
      if (state.menuStack.length === 0) return state;
      const newStack = state.menuStack.slice(0, -1);
      // Check if we should restore input from the new top of stack
      const newTop = getCurrentMenu(newStack);
      const restoredInput = newTop?.savedInput;
      return {
        ...state,
        menuStack: newStack,
        // Restore input if the new top has saved input
        input: restoredInput !== undefined ? restoredInput : state.input,
      };
    }

    case 'SET_MENU_INDEX': {
      if (state.menuStack.length === 0) return state;
      const updatedStack = [...state.menuStack];
      const topIndex = updatedStack.length - 1;
      updatedStack[topIndex] = { ...updatedStack[topIndex]!, index: action.payload };
      return { ...state, menuStack: updatedStack };
    }

    case 'CLOSE_ALL_MENUS':
      return { ...state, menuStack: [], input: '' };
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
    case 'SET_CURRENT_MODEL':
      return { ...state, currentModel: action.payload };
    case 'SET_GIT_BRANCH':
      return { ...state, gitBranch: action.payload };
    case 'UPDATE_LAST_ASSISTANT_TOKENS': {
      // Find the last assistant message and update its tokenUsage
      const messages = [...state.messages];
      for (let i = messages.length - 1; i >= 0; i--) {
        const msg = messages[i];
        if (msg && msg.role === 'assistant') {
          messages[i] = { ...msg, tokenUsage: action.payload };
          break;
        }
      }
      return { ...state, messages };
    }
    case 'QUEUE_MESSAGE':
      return { ...state, queuedMessages: [...state.queuedMessages, action.payload] };
    case 'CLEAR_QUEUE':
      return { ...state, queuedMessages: [] };
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
  const tuiSessionRef = useRef<EventStoreTuiSession | null>(null);
  const eventStoreRef = useRef<EventStore | null>(null);
  const messageIdRef = useRef(0);
  const currentToolInputRef = useRef<string | null>(null);
  // Track streaming content in a ref for synchronous access in event handler
  const streamingContentRef = useRef<string>('');
  // Track if we're exiting to prevent double-end
  const isExitingRef = useRef(false);
  // Track processing state in ref for useInput callback (avoids stale closure)
  const isProcessingRef = useRef(false);
  // Track menu stack in ref for raw stdin escape handler
  const menuStackRef = useRef<MenuStackEntry[]>([]);
  // Track previous cumulative input tokens for per-turn delta calculation
  const prevCumulativeInputRef = useRef(0);
  // Track if a tool was executed this turn (to know if we should show tokens)
  const hadToolThisTurnRef = useRef(false);
  // Track the last tool message ID to attach token usage
  const lastToolMsgIdRef = useRef<string | null>(null);

  // Welcome box state - must be set after mount to trigger Static render
  // Static only renders NEW items, so we start with false and set true after mount
  const [showWelcome, setShowWelcome] = React.useState(false);
  React.useEffect(() => {
    // Trigger Static to render the welcome box after first render
    setShowWelcome(true);
  }, []);

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
        // Reset tool tracking for this turn
        hadToolThisTurnRef.current = false;
        lastToolMsgIdRef.current = null;
        break;

      case 'message_update':
        // Accumulate text deltas in ref only - don't stream to display
        // Content will be shown as complete message after turn_end
        if ('content' in event && event.content) {
          streamingContentRef.current += event.content;
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
        }
        break;

      case 'tool_execution_end':
        if ('toolName' in event) {
          // Extract and format tool output for display
          let formattedContent = '';
          if ('result' in event && event.result) {
            const resultContent = typeof event.result.content === 'string'
              ? event.result.content
              : event.result.content.map(c => c.type === 'text' ? c.text : '[image]').join('\n');

            const formatted = formatToolOutput(
              event.toolName,
              resultContent,
              { isError: event.isError }
            );

            // Build display content: summary + preview lines
            const parts: string[] = [formatted.summary];
            if (formatted.preview.length > 0) {
              parts.push(...formatted.preview);
            }
            if (formatted.truncated) {
              parts.push(`... (${formatted.totalLines - formatted.preview.length} more lines)`);
            }
            formattedContent = parts.join('\n');
          }

          // Add tool message to display with the captured tool input
          const toolMsgId = `msg_${messageIdRef.current++}`;
          const toolMsg: DisplayMessage = {
            id: toolMsgId,
            role: 'tool',
            content: formattedContent,
            timestamp: new Date().toISOString(),
            toolName: event.toolName,
            toolStatus: event.isError ? 'error' : 'success',
            toolInput: currentToolInputRef.current ?? undefined,
            duration: 'duration' in event ? event.duration : undefined,
          };
          dispatch({ type: 'ADD_MESSAGE', payload: toolMsg });
          // Track that we had a tool this turn and store its ID for token attachment
          hadToolThisTurnRef.current = true;
          lastToolMsgIdRef.current = toolMsgId;
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
        // Attach per-turn token usage to the last tool message (if we had a tool)
        // Only show tokens on tool operations, not final text responses
        if ('tokenUsage' in event && event.tokenUsage && hadToolThisTurnRef.current && lastToolMsgIdRef.current) {
          // Calculate per-turn input tokens (delta from cumulative)
          const cumulativeInput = event.tokenUsage.inputTokens;
          const perTurnInput = cumulativeInput - prevCumulativeInputRef.current;
          prevCumulativeInputRef.current = cumulativeInput;
          // Output tokens are already per-turn from the API
          const perTurnOutput = event.tokenUsage.outputTokens;
          dispatch({
            type: 'UPDATE_MESSAGE',
            payload: {
              id: lastToolMsgIdRef.current,
              updates: {
                tokenUsage: {
                  inputTokens: perTurnInput,
                  outputTokens: perTurnOutput,
                },
              },
            },
          });
        } else if ('tokenUsage' in event && event.tokenUsage) {
          // Update cumulative tracking even when not displaying
          prevCumulativeInputRef.current = event.tokenUsage.inputTokens;
        }
        break;

      case 'hook_triggered':
        if ('hookName' in event && 'hookEvent' in event) {
          // Show hook execution in status
          dispatch({ type: 'SET_STATUS', payload: `Hook: ${event.hookEvent}` });
          debugLog.debug('hooks', `Hook triggered: ${event.hookName}`, { event: event.hookEvent });
        }
        break;

      case 'hook_completed':
        if ('hookName' in event && 'hookEvent' in event) {
          // Add a system message for hook completion if blocked
          const hookResult = 'result' in event ? event.result : 'continue';
          if (hookResult === 'block') {
            const hookMsg: DisplayMessage = {
              id: `msg_${messageIdRef.current++}`,
              role: 'system',
              content: `Hook "${event.hookName}" blocked ${event.hookEvent}`,
              timestamp: new Date().toISOString(),
            };
            dispatch({ type: 'ADD_MESSAGE', payload: hookMsg });
          }
          debugLog.debug('hooks', `Hook completed: ${event.hookName}`, { event: event.hookEvent, result: hookResult });
        }
        break;

      case 'agent_interrupted':
        // Handle interrupt event from agent
        // Note: Most cleanup is done in handleInterrupt, this is for logging
        debugLog.debug('agent', 'Agent interrupted event received', {
          turn: 'turn' in event ? event.turn : undefined,
          hasPartialContent: 'partialContent' in event && !!event.partialContent,
          activeTool: 'activeTool' in event ? event.activeTool : undefined,
        });
        break;

      case 'api_retry':
        // Handle retry event - show status to user
        if ('attempt' in event && 'delayMs' in event) {
          const delaySec = Math.round(event.delayMs / 1000);
          dispatch({
            type: 'SET_STATUS',
            payload: `Rate limited - retrying in ${delaySec}s (${event.attempt}/${event.maxRetries})`,
          });
          debugLog.info('retry', `API retry: attempt ${event.attempt}/${event.maxRetries}, delay ${delaySec}s`, {
            errorCategory: event.errorCategory,
            errorMessage: event.errorMessage,
          });
        }
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
      // Create EventStore for session management
      const globalTronDir = path.join(os.homedir(), '.tron');
      const eventStoreDbPath = path.join(globalTronDir, 'db', 'prod.db');

      // Initialize EventStore
      const eventStore = new EventStore(eventStoreDbPath);
      await eventStore.initialize();
      eventStoreRef.current = eventStore;

      // Create EventStoreTuiSession for unified session management
      const tuiSession = new EventStoreTuiSession({
        workingDirectory: config.workingDirectory,
        tronDir: globalTronDir,
        model: config.model ?? DEFAULT_MODEL,
        provider: config.provider ?? 'anthropic',
        ephemeral: config.ephemeral,
        eventStore,
      });

      debugLog.session('init', {
        workingDirectory: config.workingDirectory,
        model: config.model ?? DEFAULT_MODEL,
        tronDir: globalTronDir,
      });

      tuiSessionRef.current = tuiSession;

      // Initialize session (loads context and handoffs)
      const initResult = await tuiSession.initialize();

      // Create tools
      const tools = [
        new ReadTool({ workingDirectory: config.workingDirectory }),
        new WriteTool({ workingDirectory: config.workingDirectory }),
        new EditTool({ workingDirectory: config.workingDirectory }),
        new BashTool({ workingDirectory: config.workingDirectory }),
        new SearchTool({ workingDirectory: config.workingDirectory }),
      ];

      const agentOptions: AgentOptions = {
        workingDirectory: config.workingDirectory,
        sessionId: initResult.sessionId,
      };

      const agent = new TronAgent(
        {
          provider: {
            model: config.model ?? DEFAULT_MODEL,
            auth,
          },
          tools,
          maxTurns: 50,
          // No custom systemPrompt - agent uses TRON_CORE_PROMPT by default
        },
        agentOptions
      );

      // Set rules content for proper cache_control handling
      // Rules are now handled by the agent's ContextManager, not system prompt
      const rulesContent = tuiSession.getRulesContent();
      if (rulesContent) {
        agent.setRulesContent(rulesContent);
      }

      debugLog.agent('created', {
        sessionId: initResult.sessionId,
        model: config.model ?? DEFAULT_MODEL,
        toolCount: tools.length,
        hasRulesContent: !!rulesContent,
        rulesContentLength: rulesContent?.length ?? 0,
      });

      // Subscribe to events for streaming
      agent.onEvent(handleAgentEvent);

      agentRef.current = agent;

      dispatch({ type: 'SET_SESSION', payload: initResult.sessionId });

      // Set current model from config
      dispatch({ type: 'SET_CURRENT_MODEL', payload: config.model ?? DEFAULT_MODEL });

      // Detect git branch for working directory
      const gitBranch = await getGitBranch(config.workingDirectory);
      dispatch({ type: 'SET_GIT_BRANCH', payload: gitBranch });

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

  // Keep isProcessingRef in sync with state for useInput callback
  useEffect(() => {
    isProcessingRef.current = state.isProcessing;
  }, [state.isProcessing]);

  // Keep menu stack ref in sync with state for raw stdin escape handler
  useEffect(() => {
    menuStackRef.current = state.menuStack;
  }, [state.menuStack]);

  // Process queued messages when processing ends
  const processQueueRef = useRef<(() => Promise<void>) | null>(null);
  useEffect(() => {
    // When processing ends and we have queued messages, trigger the queue processing
    if (!state.isProcessing && state.queuedMessages.length > 0 && processQueueRef.current) {
      // Combine all queued messages into one prompt
      const combinedPrompt = state.queuedMessages.join('\n\n');
      dispatch({ type: 'CLEAR_QUEUE' });
      // Set the input and trigger submit
      dispatch({ type: 'SET_INPUT', payload: combinedPrompt });
      // Use setTimeout to ensure state is updated before submit
      setTimeout(() => processQueueRef.current?.(), 0);
    }
  }, [state.isProcessing, state.queuedMessages]);

  // Handle graceful exit with session end
  const handleExit = useCallback(async () => {
    if (isExitingRef.current) return;
    isExitingRef.current = true;

    dispatch({ type: 'SET_STATUS', payload: 'Ending session...' });

    if (tuiSessionRef.current) {
      try {
        const endResult = await tuiSessionRef.current.end();
        if (endResult.handoffCreated) {
          console.log(`\nSession summary created for: ${endResult.sessionId}`);
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

    // Show/hide slash menu based on input (only when no submenu is open)
    const currentMenu = getCurrentMenu(state.menuStack);
    const isSubMenuOpen = currentMenu !== null && currentMenu.id !== 'slash-menu';

    if (isSlashCommandInput(value)) {
      // Push slash menu if not already in stack (and no submenu is open)
      if (!isSubMenuOpen && !isMenuActive(state.menuStack, 'slash-menu')) {
        dispatch({ type: 'PUSH_MENU', payload: { id: 'slash-menu', saveInput: false } });
      }
    } else if (!isSubMenuOpen) {
      // Close menus when input no longer starts with '/' (unless submenu is open)
      if (state.menuStack.length > 0) {
        dispatch({ type: 'CLOSE_ALL_MENUS' });
      }
    }
  }, [state.historyIndex, state.menuStack]);

  // Handle submit
  const handleSubmit = useCallback(async () => {
    // Don't submit if any menu is open - the useInput hook handles Enter for that
    if (isAnyMenuOpen(state.menuStack)) {
      return;
    }

    if (!state.input.trim() || !agentRef.current || !tuiSessionRef.current) {
      return;
    }

    // If processing, queue the message for later
    if (state.isProcessing) {
      const queuedPrompt = state.input.trim();
      dispatch({ type: 'QUEUE_MESSAGE', payload: queuedPrompt });
      dispatch({ type: 'CLEAR_INPUT' });
      dispatch({ type: 'ADD_TO_HISTORY', payload: queuedPrompt });
      return;
    }

    const prompt = state.input.trim();
    dispatch({ type: 'CLEAR_INPUT' });
    dispatch({ type: 'ADD_TO_HISTORY', payload: prompt }); // Add to history
    dispatch({ type: 'SET_PROCESSING', payload: true });
    // CRITICAL: Set ref immediately (before async operation starts)
    // The useEffect sync happens after render, which may be too late
    isProcessingRef.current = true;
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

    try {
      dispatch({ type: 'SET_STATUS', payload: 'Thinking' });

      // Run agent
      const result = await agentRef.current.run(prompt);

      // Persist all messages from the agent result to session file
      // NOTE: We pass undefined for tokenUsage here - usage is tracked separately
      // to avoid the multiplication bug where cumulative totals get added per-message
      for (const msg of result.messages) {
        if (msg.role === 'user') continue;
        await tuiSessionRef.current.addMessage(msg);
      }

      // Set token usage (cumulative total from agent)
      // Update both the UI state and the session's internal tracking
      dispatch({
        type: 'SET_TOKEN_USAGE',
        payload: {
          input: result.totalTokenUsage.inputTokens,
          output: result.totalTokenUsage.outputTokens,
        },
      });
      tuiSessionRef.current.setTokenUsage(result.totalTokenUsage);

      // Clear streaming state
      dispatch({ type: 'CLEAR_STREAMING' });
      streamingContentRef.current = '';

      if (!result.success) {
        // Check if this was an interrupt (not an error)
        if (result.interrupted) {
          // Interrupt was already handled by handleInterrupt - just clean up
          dispatch({ type: 'SET_ERROR', payload: null });
          dispatch({ type: 'SET_STATUS', payload: 'Ready' });
        } else {
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
        }
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
      isProcessingRef.current = false; // Sync ref immediately
      dispatch({ type: 'SET_ACTIVE_TOOL', payload: null });
      dispatch({ type: 'CLEAR_STREAMING' });
      streamingContentRef.current = '';
    }
  }, [state.input, state.isProcessing, state.menuStack]);

  // Keep processQueueRef updated with latest handleSubmit
  useEffect(() => {
    processQueueRef.current = handleSubmit;
  }, [handleSubmit]);

  // Get sorted models for model switcher
  // Must match the sorting in ModelSwitcher component
  const getSortedModels = useCallback(() => {
    const tierOrder = { opus: 0, sonnet: 1, haiku: 2 };
    return [...ANTHROPIC_MODELS].sort((a, b) => {
      // First: non-legacy before legacy
      const legacyDiff = (a.legacy ? 1 : 0) - (b.legacy ? 1 : 0);
      if (legacyDiff !== 0) return legacyDiff;
      // Then: by tier (opus, sonnet, haiku)
      const tierDiff = tierOrder[a.tier] - tierOrder[b.tier];
      if (tierDiff !== 0) return tierDiff;
      // Within same tier and legacy status, sort by release date (newest first)
      return b.releaseDate.localeCompare(a.releaseDate);
    });
  }, []);

  // Execute a slash command
  const executeSlashCommand = useCallback((command: SlashCommand) => {
    // For most commands, close all menus and clear input
    // For submenu commands (like 'model'), we push onto the stack instead
    const isSubmenuCommand = command.name === 'model';

    if (!isSubmenuCommand) {
      dispatch({ type: 'CLOSE_ALL_MENUS' });
    }

    switch (command.name) {
      case 'help':
        dispatch({
          type: 'ADD_MESSAGE',
          payload: {
            id: `msg_${messageIdRef.current++}`,
            role: 'system',
            content: `## Commands\n${BUILT_IN_COMMANDS.map(c =>
              `- \`/${c.name}\`${c.shortcut ? ` *(${c.shortcut})*` : ''} - ${c.description}`
            ).join('\n')}\n\n## Keyboard Shortcuts\n- \`Ctrl+C\` - Exit\n- \`Ctrl+L\` - Clear screen\n- \`↑/↓\` - Navigate history or menu\n- \`Enter\` - Submit or select\n- \`Esc\` - Interrupt execution / Back to previous menu\n- \`Shift+Enter\` - New line`,
            timestamp: new Date().toISOString(),
          },
        });
        break;

      case 'clear':
        dispatch({ type: 'RESET' });
        break;

      case 'model': {
        // Push model switcher as submenu (preserving slash menu in stack)
        const sortedModels = getSortedModels();
        const currentIndex = Math.max(0, sortedModels.findIndex(m => m.id === state.currentModel));
        // Push model-switcher, saving the current input for restoration on Escape
        dispatch({
          type: 'PUSH_MENU',
          payload: { id: 'model-switcher', index: currentIndex, saveInput: true },
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
          `## Session`,
          `- **ID**: \`${state.sessionId ?? 'N/A'}\``,
          `- **Messages**: ${messageCount}`,
          '',
          '## Token Usage',
          `- **Input**: ${state.tokenUsage.input.toLocaleString()} tokens`,
          `- **Output**: ${state.tokenUsage.output.toLocaleString()} tokens`,
          `- **Total**: ${(state.tokenUsage.input + state.tokenUsage.output).toLocaleString()} tokens`,
          '',
          '## Context',
          `- **Estimate**: ~${tokenEstimate.toLocaleString()} tokens`,
          `- **Threshold**: ${compactionConfig?.maxTokens?.toLocaleString() ?? 'N/A'} tokens`,
          `- **Needs compaction**: ${needsCompaction ? 'Yes' : 'No'}`,
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
            content: `## Resume Session\n- \`tron --continue\` - Resume most recent session\n- \`tron --resume <id>\` - Resume specific session\n\nSession files are stored in \`~/.tron/sessions/\``,
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
            content: `## Branch *(coming soon)*\n- Fork session at any point\n- Explore alternative approaches\n- Compare different solutions`,
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
  }, [config.model, config.workingDirectory, state.sessionId, state.tokenUsage, state.messages.length, state.currentModel, getSortedModels, handleExit]);

  // Handle model selection from model switcher
  const handleModelSelect = useCallback((model: ModelInfo) => {
    // Close all menus when a model is selected
    dispatch({ type: 'CLOSE_ALL_MENUS' });

    const agent = agentRef.current;
    if (!agent) {
      dispatch({
        type: 'ADD_MESSAGE',
        payload: {
          id: `msg_${messageIdRef.current++}`,
          role: 'system',
          content: 'Cannot switch model: Agent not initialized',
          timestamp: new Date().toISOString(),
        },
      });
      return;
    }

    const previousModel = agent.getModel();

    // Check if already on this model
    if (model.id === previousModel) {
      dispatch({
        type: 'ADD_MESSAGE',
        payload: {
          id: `msg_${messageIdRef.current++}`,
          role: 'system',
          content: `Already using **${model.name}**`,
          timestamp: new Date().toISOString(),
        },
      });
      return;
    }

    try {
      // Switch the model on the agent (preserves context)
      agent.switchModel(model.id);

      // Update state
      dispatch({ type: 'SET_CURRENT_MODEL', payload: model.id });

      // Show success message with model details
      const thinkingNote = model.supportsThinking ? ' (extended thinking enabled)' : '';
      dispatch({
        type: 'ADD_MESSAGE',
        payload: {
          id: `msg_${messageIdRef.current++}`,
          role: 'system',
          content: [
            `Switched to **${model.name}**${thinkingNote}`,
            '',
            `${model.description}`,
            '',
            `Context: ${(model.contextWindow / 1000).toFixed(0)}K tokens | Max output: ${model.maxOutput.toLocaleString()} tokens`,
          ].join('\n'),
          timestamp: new Date().toISOString(),
        },
      });

      debugLog.info('model', `Model switched from ${previousModel} to ${model.id}`);
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error);
      dispatch({
        type: 'ADD_MESSAGE',
        payload: {
          id: `msg_${messageIdRef.current++}`,
          role: 'system',
          content: `Failed to switch model: ${errorMessage}`,
          timestamp: new Date().toISOString(),
        },
      });
    }
  }, []);

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

  // Handle interrupt - abort agent execution
  // Uses refs instead of state to avoid stale closures in useInput
  const handleInterrupt = useCallback(() => {
    // Use ref for current processing state (avoids stale closure)
    if (!isProcessingRef.current || !agentRef.current) {
      return;
    }

    debugLog.debug('interrupt', 'Esc pressed - interrupting agent execution');

    // Abort the agent
    agentRef.current.abort();

    // Finalize any streaming content as a partial message
    if (streamingContentRef.current.trim()) {
      dispatch({
        type: 'ADD_MESSAGE',
        payload: {
          id: `msg_${messageIdRef.current++}`,
          role: 'assistant',
          content: streamingContentRef.current.trim() + '\n\n*(interrupted)*',
          timestamp: new Date().toISOString(),
        },
      });
      streamingContentRef.current = '';
    }

    // Add system message indicating interruption
    dispatch({
      type: 'ADD_MESSAGE',
      payload: {
        id: `msg_${messageIdRef.current++}`,
        role: 'system',
        content: 'Interrupted - tell Tron what to do instead',
        timestamp: new Date().toISOString(),
      },
    });

    // Reset processing state
    dispatch({ type: 'SET_PROCESSING', payload: false });
    isProcessingRef.current = false; // Sync ref immediately
    dispatch({ type: 'SET_ACTIVE_TOOL', payload: null });
    dispatch({ type: 'SET_ACTIVE_TOOL_INPUT', payload: null });
    dispatch({ type: 'CLEAR_STREAMING' });
    dispatch({ type: 'SET_STATUS', payload: 'Ready' });

    debugLog.debug('interrupt', 'Agent execution interrupted by user');
  }, []); // No dependencies - uses refs for current values

  // Unified escape key handler - pops menu stack or interrupts processing
  // Called from raw stdin handler in MacOSInput, uses refs to avoid stale closures
  const handleEscapeKey = useCallback(() => {
    // Priority 1: Pop the menu stack if any menu is open
    if (menuStackRef.current.length > 0) {
      dispatch({ type: 'POP_MENU' });
      // Note: Don't sync ref here - let useEffect do it to avoid race conditions
      return;
    }

    // Priority 2: Interrupt processing if running
    if (isProcessingRef.current) {
      handleInterrupt();
      return;
    }
  }, [handleInterrupt]); // Only depends on handleInterrupt which is stable

  useInput((input, key) => {
    // Ctrl+C to exit (with proper session end)
    if (input === 'c' && key.ctrl) {
      handleExit();
    }

    // Ctrl+L to clear display
    if (input === 'l' && key.ctrl) {
      dispatch({ type: 'RESET' });
    }

    // Escape to interrupt processing or close menus
    if (key.escape) {
      if (isAnyMenuOpen(state.menuStack)) {
        dispatch({ type: 'POP_MENU' });
        return;
      }
      if (isProcessingRef.current) {
        handleInterrupt();
        return;
      }
    }

    // Get current menu state
    const currentMenu = getCurrentMenu(state.menuStack);
    const currentMenuIndex = currentMenu?.index ?? 0;

    // Model switcher navigation (only when active and not processing)
    if (isMenuActive(state.menuStack, 'model-switcher') && !isProcessingRef.current) {
      const sortedModels = getSortedModels();

      if (key.upArrow) {
        const newIndex = currentMenuIndex > 0
          ? currentMenuIndex - 1
          : sortedModels.length - 1;
        dispatch({ type: 'SET_MENU_INDEX', payload: newIndex });
      }

      if (key.downArrow) {
        const newIndex = currentMenuIndex < sortedModels.length - 1
          ? currentMenuIndex + 1
          : 0;
        dispatch({ type: 'SET_MENU_INDEX', payload: newIndex });
      }

      if (key.return && sortedModels.length > 0) {
        const selectedModel = sortedModels[currentMenuIndex];
        if (selectedModel) {
          handleModelSelect(selectedModel);
        }
      }

      return; // Don't process other input while model switcher is open
    }

    // Slash menu navigation (only when active and not processing)
    if (isMenuActive(state.menuStack, 'slash-menu') && !isProcessingRef.current) {
      const filteredCommands = getFilteredCommands();

      if (key.upArrow) {
        const newIndex = currentMenuIndex > 0
          ? currentMenuIndex - 1
          : filteredCommands.length - 1;
        dispatch({ type: 'SET_MENU_INDEX', payload: newIndex });
      }

      if (key.downArrow) {
        const newIndex = currentMenuIndex < filteredCommands.length - 1
          ? currentMenuIndex + 1
          : 0;
        dispatch({ type: 'SET_MENU_INDEX', payload: newIndex });
      }

      if (key.return && filteredCommands.length > 0) {
        const selectedCommand = filteredCommands[currentMenuIndex];
        if (selectedCommand) {
          executeSlashCommand(selectedCommand);
        }
      }

      return; // Don't process other input while slash menu is open
    }

  });

  // Don't render the full UI until initialized
  if (!state.isInitialized) {
    return (
      <Box flexDirection="column" padding={1}>
        <Text color={inkColors.dim}>Initializing...</Text>
      </Box>
    );
  }

  return (
    <Box flexDirection="column">
      {/*
        LAYOUT PHILOSOPHY FOR SCROLL BEHAVIOR:

        MessageList uses Ink's Static component for content that should be
        "written once" and become part of the terminal's scrollback buffer:
        1. Welcome box (rendered once at session start)
        2. Past messages (rendered once when they appear)

        Both are combined in ONE Static flow inside MessageList to ensure
        correct ordering (welcome first, then messages).

        Static content is NEVER re-rendered - it becomes permanent scrollback.
        Only the "live" area (thinking, streaming, input, status) re-renders.

        This allows users to scroll up freely while the agent processes.
      */}

      {/* Message List - combines welcome box and messages in one Static flow */}
      {/* This ensures correct ordering: welcome first, then messages */}
      <Box flexDirection="column" paddingX={1}>
        <MessageList
          messages={state.messages}
          isProcessing={state.isProcessing}
          activeTool={state.activeTool}
          activeToolInput={state.activeToolInput}
          streamingContent={state.streamingContent}
          isStreaming={state.isStreaming}
          thinkingText={state.thinkingText}
          showWelcome={showWelcome}
          welcomeModel={config.model ?? DEFAULT_MODEL}
          welcomeWorkingDirectory={config.workingDirectory}
          welcomeGitBranch={state.gitBranch ?? undefined}
        />
      </Box>

      {/* Slash Command Menu - visible when active */}
      {isMenuActive(state.menuStack, 'slash-menu') && !state.isProcessing && (
        <SlashCommandMenu
          commands={BUILT_IN_COMMANDS}
          filter={parseSlashCommand(state.input).commandName}
          selectedIndex={getCurrentMenu(state.menuStack)?.index ?? 0}
          onSelect={executeSlashCommand}
          onCancel={() => dispatch({ type: 'POP_MENU' })}
          maxVisible={5}
        />
      )}

      {/* Model Switcher Submenu - visible when active */}
      {isMenuActive(state.menuStack, 'model-switcher') && !state.isProcessing && (
        <ModelSwitcher
          currentModel={state.currentModel}
          selectedIndex={getCurrentMenu(state.menuStack)?.index ?? 0}
          onSelect={handleModelSelect}
          onCancel={() => dispatch({ type: 'POP_MENU' })}
          maxVisible={6}
        />
      )}

      {/* Queue indicator - shown when messages are queued */}
      {state.queuedMessages.length > 0 && (
        <Box marginLeft={2}>
          <Text color={inkColors.statusThinking}>
            ⏳ {state.queuedMessages.length} message{state.queuedMessages.length !== 1 ? 's' : ''} queued (will send when ready)
          </Text>
        </Box>
      )}

      {/* Prompt Box */}
      <PromptBox
        value={state.input}
        onChange={handleInputChange}
        onSubmit={handleSubmit}
        isProcessing={state.isProcessing}
        onUpArrow={handleHistoryUp}
        onDownArrow={handleHistoryDown}
        onCtrlC={handleExit}
        onEscape={handleEscapeKey}
        menuOpen={isAnyMenuOpen(state.menuStack)}
      />

      {/* Status Bar */}
      <StatusBar
        status={state.status}
        error={state.error}
        tokenUsage={state.tokenUsage}
        model={state.currentModel}
        gitBranch={state.gitBranch ?? undefined}
      />
    </Box>
  );
}
