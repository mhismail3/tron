/**
 * @fileoverview Session Management Types
 *
 * Types for session lifecycle, persistence, and state management.
 */
import type { Message, TokenUsage } from '../types/index.js';

// =============================================================================
// Session State
// =============================================================================

/**
 * Full session state including messages and metadata
 */
export interface Session {
  /** Unique session identifier */
  id: string;
  /** Working directory for file operations */
  workingDirectory: string;
  /** Current model being used */
  model: string;
  /** Provider for the model */
  provider: string;
  /** Custom system prompt for the session */
  systemPrompt?: string;
  /** All messages in the session */
  messages: Message[];
  /** Creation timestamp */
  createdAt: string;
  /** Last activity timestamp */
  lastActivityAt: string;
  /** End timestamp if session ended */
  endedAt?: string;
  /** Total token usage */
  tokenUsage: TokenUsage;
  /** Current turn number */
  currentTurn: number;
  /** Whether the session is currently active */
  isActive: boolean;
  /** Associated files being worked on */
  activeFiles: string[];
  /** Session metadata */
  metadata: SessionMetadata;
}

/**
 * Session metadata stored alongside messages
 */
export interface SessionMetadata {
  /** User-provided title */
  title?: string;
  /** Tags for organization */
  tags?: string[];
  /** Parent session if forked */
  parentSessionId?: string;
  /** Index from which this was forked */
  forkFromIndex?: number;
  /** Context files loaded */
  contextFiles?: string[];
  /** Custom user data */
  custom?: Record<string, unknown>;
}

/**
 * Session summary for listing
 */
export interface SessionSummary {
  id: string;
  workingDirectory: string;
  model: string;
  messageCount: number;
  createdAt: string;
  lastActivityAt: string;
  isActive: boolean;
  title?: string;
  tags?: string[];
}

// =============================================================================
// Session Operations
// =============================================================================

/**
 * Options for creating a new session
 */
export interface CreateSessionOptions {
  /** Working directory for the session */
  workingDirectory: string;
  /** Model to use (defaults to config) */
  model?: string;
  /** Provider to use (defaults to anthropic) */
  provider?: string;
  /** Custom system prompt */
  systemPrompt?: string;
  /** Initial title */
  title?: string;
  /** Initial tags */
  tags?: string[];
  /** Context files to load */
  contextFiles?: string[];
}

/**
 * Options for listing sessions
 */
export interface ListSessionsOptions {
  /** Filter by working directory */
  workingDirectory?: string;
  /** Include ended sessions */
  includeEnded?: boolean;
  /** Maximum sessions to return */
  limit?: number;
  /** Offset for pagination */
  offset?: number;
  /** Filter by tags */
  tags?: string[];
  /** Order by field */
  orderBy?: 'createdAt' | 'lastActivityAt';
  /** Order direction */
  order?: 'asc' | 'desc';
}

/**
 * Options for forking a session
 */
export interface ForkSessionOptions {
  /** Session to fork from */
  sessionId: string;
  /** Message index to fork from (defaults to current) */
  fromIndex?: number;
  /** New title for forked session */
  title?: string;
}

/**
 * Result of forking a session
 */
export interface ForkSessionResult {
  /** New session ID */
  newSessionId: string;
  /** Original session ID */
  forkedFrom: string;
  /** Number of messages copied */
  messageCount: number;
}

// =============================================================================
// JSONL Persistence
// =============================================================================

/**
 * Entry types in the JSONL session file
 */
export type SessionLogEntry =
  | SessionStartEntry
  | MessageEntry
  | ToolCallEntry
  | ToolResultEntry
  | MetadataUpdateEntry
  | SessionEndEntry;

/**
 * Session start entry
 */
export interface SessionStartEntry {
  type: 'session_start';
  timestamp: string;
  sessionId: string;
  workingDirectory: string;
  model: string;
  provider: string;
  systemPrompt?: string;
  metadata: SessionMetadata;
}

/**
 * Message entry (user or assistant)
 */
export interface MessageEntry {
  type: 'message';
  timestamp: string;
  message: Message;
  turn?: number;
  tokenUsage?: TokenUsage;
}

/**
 * Tool call entry
 */
export interface ToolCallEntry {
  type: 'tool_call';
  timestamp: string;
  toolCall: {
    id: string;
    name: string;
    arguments: Record<string, unknown>;
  };
}

/**
 * Tool result entry
 */
export interface ToolResultEntry {
  type: 'tool_result';
  timestamp: string;
  toolCallId: string;
  result: {
    content: string;
    isError: boolean;
    duration?: number;
  };
}

/**
 * Metadata update entry (also used for session property updates like model)
 */
export interface MetadataUpdateEntry {
  type: 'metadata_update';
  timestamp: string;
  updates: Partial<SessionMetadata> & {
    /** Model update (stored alongside metadata for convenience) */
    model?: string;
    /** System prompt update */
    systemPrompt?: string;
  };
}

/**
 * Session end entry
 */
export interface SessionEndEntry {
  type: 'session_end';
  timestamp: string;
  reason: 'completed' | 'aborted' | 'error' | 'timeout';
  summary?: string;
  tokenUsage?: TokenUsage;
}

// =============================================================================
// Session Events
// =============================================================================

/**
 * Events emitted by the session manager
 */
export type SessionEvent =
  | { type: 'session_created'; session: SessionSummary }
  | { type: 'session_resumed'; session: SessionSummary }
  | { type: 'session_ended'; sessionId: string; reason: string }
  | { type: 'session_forked'; original: string; forked: string }
  | { type: 'session_rewound'; sessionId: string; toIndex: number }
  | { type: 'session_deleted'; sessionId: string };
