/**
 * @fileoverview TUI Types
 *
 * Type definitions for the terminal user interface.
 */
import type { AnthropicAuth } from '@tron/core';

// =============================================================================
// CLI Configuration
// =============================================================================

export interface CliConfig {
  /** Working directory for the session */
  workingDirectory: string;
  /** Model to use */
  model?: string;
  /** Provider to use */
  provider?: string;
  /** Resume a specific session */
  resumeSession?: string;
  /** Start in server mode */
  serverMode?: boolean;
  /** Server WebSocket port */
  wsPort?: number;
  /** Server health port */
  healthPort?: number;
  /** Verbose logging */
  verbose?: boolean;
  /** Debug mode - full trace logs */
  debug?: boolean;
  /** Non-interactive mode (single prompt) */
  nonInteractive?: boolean;
  /** Initial prompt (for non-interactive mode) */
  initialPrompt?: string;
  /** Ephemeral mode - no persistence */
  ephemeral?: boolean;
}

/** Authentication credentials for the session */
export type { AnthropicAuth };

// =============================================================================
// App State
// =============================================================================

export interface AppState {
  /** Whether app has initialized */
  isInitialized: boolean;
  /** Current input text */
  input: string;
  /** Whether agent is processing */
  isProcessing: boolean;
  /** Current session ID */
  sessionId: string | null;
  /** Conversation messages for display */
  messages: DisplayMessage[];
  /** Current status message */
  status: string;
  /** Error message if any */
  error: string | null;
  /** Token usage stats */
  tokenUsage: { input: number; output: number };
  /** Active tool name if executing */
  activeTool: string | null;
  /** Active tool input/command being executed */
  activeToolInput: string | null;
  /** Content currently being streamed */
  streamingContent: string;
  /** Whether text is actively streaming */
  isStreaming: boolean;
  /** Current thinking text (for extended thinking) */
  thinkingText: string;
  /** Whether slash command menu is visible */
  showSlashMenu: boolean;
  /** Selected index in slash command menu */
  slashMenuIndex: number;
  /** Prompt history for navigation */
  promptHistory: string[];
  /** Current history navigation index (-1 = not navigating) */
  historyIndex: number;
  /** Temporary input stored during history navigation */
  temporaryInput: string;
}

export interface DisplayMessage {
  id: string;
  role: 'user' | 'assistant' | 'system' | 'tool';
  content: string;
  timestamp: string;
  toolName?: string;
  toolStatus?: 'running' | 'success' | 'error';
  toolInput?: string;
  duration?: number;
}

// =============================================================================
// Actions
// =============================================================================

export type AppAction =
  | { type: 'SET_INITIALIZED'; payload: boolean }
  | { type: 'SET_INPUT'; payload: string }
  | { type: 'CLEAR_INPUT' }
  | { type: 'SET_PROCESSING'; payload: boolean }
  | { type: 'SET_SESSION'; payload: string }
  | { type: 'ADD_MESSAGE'; payload: DisplayMessage }
  | { type: 'UPDATE_MESSAGE'; payload: { id: string; updates: Partial<DisplayMessage> } }
  | { type: 'SET_STATUS'; payload: string }
  | { type: 'SET_ERROR'; payload: string | null }
  | { type: 'SET_TOKEN_USAGE'; payload: { input: number; output: number } }
  | { type: 'SET_ACTIVE_TOOL'; payload: string | null }
  | { type: 'SET_ACTIVE_TOOL_INPUT'; payload: string | null }
  | { type: 'APPEND_STREAMING_CONTENT'; payload: string }
  | { type: 'SET_STREAMING'; payload: boolean }
  | { type: 'CLEAR_STREAMING' }
  | { type: 'SET_THINKING_TEXT'; payload: string }
  | { type: 'APPEND_THINKING_TEXT'; payload: string }
  | { type: 'RESET' }
  | { type: 'SHOW_SLASH_MENU'; payload: boolean }
  | { type: 'SET_SLASH_MENU_INDEX'; payload: number }
  | { type: 'ADD_TO_HISTORY'; payload: string }
  | { type: 'HISTORY_UP' }
  | { type: 'HISTORY_DOWN' }
  | { type: 'SET_TEMPORARY_INPUT'; payload: string }
  | { type: 'RESET_HISTORY_NAVIGATION' };

// =============================================================================
// Component Props
// =============================================================================

export interface HeaderProps {
  sessionId: string | null;
  workingDirectory: string;
  model: string;
  tokenUsage: { input: number; output: number };
}

export interface MessageListProps {
  messages: DisplayMessage[];
  isProcessing: boolean;
  activeTool: string | null;
}

export interface InputAreaProps {
  /** Current input value */
  value: string;
  /** Callback when value changes */
  onChange: (value: string) => void;
  /** Callback when input is submitted */
  onSubmit: () => void;
  /** Whether a request is being processed */
  isProcessing: boolean;
  /** Callback for up arrow (history navigation) */
  onUpArrow?: () => void;
  /** Callback for down arrow (history navigation) */
  onDownArrow?: () => void;
  /** Callback when Ctrl+C is pressed (for exit handling) */
  onCtrlC?: () => void;
  /** Callback when Escape is pressed during processing (for interrupt) */
  onEscape?: () => void;
}

export interface StatusBarProps {
  status: string;
  error: string | null;
}
