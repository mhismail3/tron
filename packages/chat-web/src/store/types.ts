/**
 * @fileoverview State Types for Chat Web UI
 *
 * Type definitions matching TUI's state structure from packages/tui/src/types.ts
 * with additional web-specific state for connection and session management.
 */

// =============================================================================
// Display Message Types
// =============================================================================

export interface DisplayMessage {
  id: string;
  role: 'user' | 'assistant' | 'system' | 'tool';
  content: string;
  timestamp: string;
  toolName?: string;
  toolStatus?: 'running' | 'success' | 'error';
  toolInput?: string;
  duration?: number;
  tokenUsage?: {
    inputTokens: number;
    outputTokens: number;
  };
}

// =============================================================================
// Menu Stack Types
// =============================================================================

export type MenuId = 'slash-menu' | 'model-switcher' | string;

export interface MenuStackEntry {
  id: MenuId;
  index: number;
  savedInput?: string;
}

// =============================================================================
// Session Types (Web-specific)
// =============================================================================

export interface SessionSummary {
  id: string;
  title: string;
  lastActivity: string;
  model?: string;
  messageCount?: number;
  workingDirectory?: string;
}

// =============================================================================
// Connection State (Web-specific)
// =============================================================================

export type ConnectionStatus = 'disconnected' | 'connecting' | 'connected' | 'error';

export interface ConnectionState {
  status: ConnectionStatus;
  error: string | null;
  reconnectAttempt: number;
}

// =============================================================================
// UI State (Web-specific)
// =============================================================================

export interface UIState {
  sidebarOpen: boolean;
  isMobile: boolean;
}

// =============================================================================
// App State
// =============================================================================

export interface AppState {
  // Core state (matches TUI)
  isInitialized: boolean;
  input: string;
  isProcessing: boolean;
  sessionId: string | null;
  messages: DisplayMessage[];
  status: string;
  error: string | null;

  // Token usage
  tokenUsage: { input: number; output: number };

  // Tool state
  activeTool: string | null;
  activeToolInput: string | null;

  // Streaming state
  streamingContent: string;
  isStreaming: boolean;
  thinkingText: string;

  // Menu stack for hierarchical navigation
  menuStack: MenuStackEntry[];

  // History navigation
  promptHistory: string[];
  historyIndex: number;
  temporaryInput: string;

  // Model and environment
  currentModel: string;
  gitBranch: string | null;

  // Message queue (for queuing during processing)
  queuedMessages: string[];

  // Web-specific state
  connection: ConnectionState;
  sessions: SessionSummary[];
  ui: UIState;
}

// =============================================================================
// Actions
// =============================================================================

export type AppAction =
  // Initialization
  | { type: 'SET_INITIALIZED'; payload: boolean }
  | { type: 'SET_SESSION'; payload: string }
  | { type: 'RESET' }

  // Input
  | { type: 'SET_INPUT'; payload: string }
  | { type: 'CLEAR_INPUT' }

  // Processing
  | { type: 'SET_PROCESSING'; payload: boolean }
  | { type: 'SET_STATUS'; payload: string }
  | { type: 'SET_ERROR'; payload: string | null }

  // Messages
  | { type: 'ADD_MESSAGE'; payload: DisplayMessage }
  | { type: 'UPDATE_MESSAGE'; payload: { id: string; updates: Partial<DisplayMessage> } }

  // Token usage
  | { type: 'SET_TOKEN_USAGE'; payload: { input: number; output: number } }

  // Tools
  | { type: 'SET_ACTIVE_TOOL'; payload: string | null }
  | { type: 'SET_ACTIVE_TOOL_INPUT'; payload: string | null }

  // Streaming
  | { type: 'APPEND_STREAMING_CONTENT'; payload: string }
  | { type: 'SET_STREAMING'; payload: boolean }
  | { type: 'CLEAR_STREAMING' }

  // Thinking
  | { type: 'SET_THINKING_TEXT'; payload: string }
  | { type: 'APPEND_THINKING_TEXT'; payload: string }

  // Menu stack
  | { type: 'PUSH_MENU'; payload: { id: MenuId; index?: number; saveInput?: boolean } }
  | { type: 'POP_MENU' }
  | { type: 'SET_MENU_INDEX'; payload: number }
  | { type: 'CLOSE_ALL_MENUS' }

  // History
  | { type: 'ADD_TO_HISTORY'; payload: string }
  | { type: 'HISTORY_UP' }
  | { type: 'HISTORY_DOWN' }
  | { type: 'SET_TEMPORARY_INPUT'; payload: string }
  | { type: 'RESET_HISTORY_NAVIGATION' }

  // Model
  | { type: 'SET_CURRENT_MODEL'; payload: string }
  | { type: 'SET_GIT_BRANCH'; payload: string | null }

  // Queue
  | { type: 'QUEUE_MESSAGE'; payload: string }
  | { type: 'CLEAR_QUEUE' }

  // Connection (Web-specific)
  | { type: 'SET_CONNECTION_STATUS'; payload: ConnectionStatus }
  | { type: 'SET_CONNECTION_ERROR'; payload: string | null }
  | { type: 'INCREMENT_RECONNECT_ATTEMPT' }
  | { type: 'RESET_RECONNECT_ATTEMPT' }

  // Sessions (Web-specific)
  | { type: 'SET_SESSIONS'; payload: SessionSummary[] }
  | { type: 'ADD_SESSION'; payload: SessionSummary }
  | { type: 'REMOVE_SESSION'; payload: string }

  // UI (Web-specific)
  | { type: 'SET_SIDEBAR_OPEN'; payload: boolean }
  | { type: 'SET_IS_MOBILE'; payload: boolean };
