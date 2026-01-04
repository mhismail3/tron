/**
 * @fileoverview State Reducer for Chat Web UI
 *
 * Reducer implementation matching TUI's pattern from packages/tui/src/app.tsx
 * with additional web-specific actions for connection and session management.
 */

import type { AppState, AppAction, MenuStackEntry } from './types.js';

// =============================================================================
// Constants
// =============================================================================

const MAX_HISTORY = 100;
const DEFAULT_MODEL = 'claude-opus-4-5-20251101';

// =============================================================================
// Initial State
// =============================================================================

export const initialState: AppState = {
  // Core state
  isInitialized: false,
  input: '',
  isProcessing: false,
  sessionId: null,
  messages: [],
  status: 'Initializing',
  error: null,

  // Token usage
  tokenUsage: { input: 0, output: 0 },

  // Tool state
  activeTool: null,
  activeToolInput: null,

  // Streaming state
  streamingContent: '',
  isStreaming: false,
  thinkingText: '',

  // Menu stack
  menuStack: [],

  // History
  promptHistory: [],
  historyIndex: -1,
  temporaryInput: '',

  // Model and environment
  currentModel: DEFAULT_MODEL,
  gitBranch: null,
  workingDirectory: '/project',

  // Queue
  queuedMessages: [],

  // Web-specific state
  connection: {
    status: 'disconnected',
    error: null,
    reconnectAttempt: 0,
  },
  sessions: [],
  ui: {
    sidebarOpen: false,
    isMobile: false,
  },
};

export function createInitialState(): AppState {
  return { ...initialState };
}

// =============================================================================
// Menu Stack Helpers
// =============================================================================

function getCurrentMenu(stack: MenuStackEntry[]): MenuStackEntry | null {
  return stack.length > 0 ? stack[stack.length - 1]! : null;
}

// =============================================================================
// Reducer
// =============================================================================

export function reducer(state: AppState, action: AppAction): AppState {
  switch (action.type) {
    // =========================================================================
    // Initialization
    // =========================================================================

    case 'SET_INITIALIZED':
      return { ...state, isInitialized: action.payload };

    case 'SET_SESSION':
      return { ...state, sessionId: action.payload };

    case 'RESET':
      return {
        ...initialState,
        isInitialized: true,
        sessionId: state.sessionId,
        status: 'Ready',
        activeToolInput: null,
        // Preserve web-specific state
        connection: state.connection,
        sessions: state.sessions,
        ui: state.ui,
        currentModel: state.currentModel,
        workingDirectory: state.workingDirectory,
      };

    // =========================================================================
    // Input
    // =========================================================================

    case 'SET_INPUT':
      return { ...state, input: action.payload };

    case 'CLEAR_INPUT':
      return { ...state, input: '' };

    // =========================================================================
    // Processing
    // =========================================================================

    case 'SET_PROCESSING':
      return { ...state, isProcessing: action.payload };

    case 'SET_STATUS':
      return { ...state, status: action.payload };

    case 'SET_ERROR':
      return { ...state, error: action.payload };

    // =========================================================================
    // Messages
    // =========================================================================

    case 'ADD_MESSAGE':
      return { ...state, messages: [...state.messages, action.payload] };

    case 'UPDATE_MESSAGE':
      return {
        ...state,
        messages: state.messages.map((m) =>
          m.id === action.payload.id ? { ...m, ...action.payload.updates } : m
        ),
      };

    // =========================================================================
    // Token Usage
    // =========================================================================

    case 'SET_TOKEN_USAGE':
      return {
        ...state,
        tokenUsage: {
          input: action.payload.input,
          output: action.payload.output,
        },
      };

    // =========================================================================
    // Tools
    // =========================================================================

    case 'SET_ACTIVE_TOOL':
      return { ...state, activeTool: action.payload };

    case 'SET_ACTIVE_TOOL_INPUT':
      return { ...state, activeToolInput: action.payload };

    // =========================================================================
    // Streaming
    // =========================================================================

    case 'APPEND_STREAMING_CONTENT':
      return { ...state, streamingContent: state.streamingContent + action.payload };

    case 'SET_STREAMING':
      return { ...state, isStreaming: action.payload };

    case 'CLEAR_STREAMING':
      return { ...state, streamingContent: '', isStreaming: false, thinkingText: '' };

    // =========================================================================
    // Thinking
    // =========================================================================

    case 'SET_THINKING_TEXT':
      return { ...state, thinkingText: action.payload };

    case 'APPEND_THINKING_TEXT':
      return { ...state, thinkingText: state.thinkingText + action.payload };

    // =========================================================================
    // Menu Stack
    // =========================================================================

    case 'PUSH_MENU': {
      const { id, index = 0, saveInput = false } = action.payload;
      const currentMenu = getCurrentMenu(state.menuStack);

      // Don't push if this menu is already at the top
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
      const newTop = getCurrentMenu(newStack);
      const restoredInput = newTop?.savedInput;

      return {
        ...state,
        menuStack: newStack,
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

    // =========================================================================
    // History
    // =========================================================================

    case 'ADD_TO_HISTORY': {
      const trimmed = action.payload.trim();
      if (!trimmed) return state;

      // Don't add consecutive duplicates
      if (
        state.promptHistory.length > 0 &&
        state.promptHistory[state.promptHistory.length - 1] === trimmed
      ) {
        return { ...state, historyIndex: -1, temporaryInput: '' };
      }

      const newHistory = [...state.promptHistory, trimmed];
      const limitedHistory =
        newHistory.length > MAX_HISTORY ? newHistory.slice(-MAX_HISTORY) : newHistory;

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

    // =========================================================================
    // Model
    // =========================================================================

    case 'SET_CURRENT_MODEL':
      return { ...state, currentModel: action.payload };

    case 'SET_GIT_BRANCH':
      return { ...state, gitBranch: action.payload };

    case 'SET_WORKING_DIRECTORY':
      return { ...state, workingDirectory: action.payload };

    // =========================================================================
    // Queue
    // =========================================================================

    case 'QUEUE_MESSAGE':
      return { ...state, queuedMessages: [...state.queuedMessages, action.payload] };

    case 'CLEAR_QUEUE':
      return { ...state, queuedMessages: [] };

    // =========================================================================
    // Connection (Web-specific)
    // =========================================================================

    case 'SET_CONNECTION_STATUS':
      return {
        ...state,
        connection: { ...state.connection, status: action.payload },
      };

    case 'SET_CONNECTION_ERROR':
      return {
        ...state,
        connection: { ...state.connection, error: action.payload },
      };

    case 'INCREMENT_RECONNECT_ATTEMPT':
      return {
        ...state,
        connection: {
          ...state.connection,
          reconnectAttempt: state.connection.reconnectAttempt + 1,
        },
      };

    case 'RESET_RECONNECT_ATTEMPT':
      return {
        ...state,
        connection: { ...state.connection, reconnectAttempt: 0 },
      };

    // =========================================================================
    // Sessions (Web-specific)
    // =========================================================================

    case 'SET_SESSIONS':
      return { ...state, sessions: action.payload };

    case 'ADD_SESSION':
      return { ...state, sessions: [...state.sessions, action.payload] };

    case 'REMOVE_SESSION':
      return {
        ...state,
        sessions: state.sessions.filter((s) => s.id !== action.payload),
      };

    // =========================================================================
    // UI (Web-specific)
    // =========================================================================

    case 'SET_SIDEBAR_OPEN':
      return {
        ...state,
        ui: { ...state.ui, sidebarOpen: action.payload },
      };

    case 'SET_IS_MOBILE':
      return {
        ...state,
        ui: { ...state.ui, isMobile: action.payload },
      };

    // =========================================================================
    // Default
    // =========================================================================

    default:
      return state;
  }
}
