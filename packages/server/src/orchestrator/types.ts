/**
 * @fileoverview Orchestrator Type Definitions
 *
 * Contains all type definitions for the EventStoreOrchestrator including
 * configuration, session state, and result types.
 */
import {
  EventStore,
  TronAgent,
  type EventId,
  type SessionId,
  type WorkingDirectory,
  type WorktreeCoordinatorConfig,
  type CurrentTurnToolCall,
  type SkillTracker,
} from '@tron/core';
import type { TurnContentTracker } from './turn-content-tracker.js';

// =============================================================================
// Configuration
// =============================================================================

export interface EventStoreOrchestratorConfig {
  /** Path to event store database (defaults to ~/.tron/events.db) */
  eventStoreDbPath?: string;
  /** Default model */
  defaultModel: string;
  /** Default provider */
  defaultProvider: string;
  /** Max concurrent sessions */
  maxConcurrentSessions?: number;
  /** Worktree configuration */
  worktree?: WorktreeCoordinatorConfig;
  /** Pre-existing EventStore instance (for testing) - if provided, eventStoreDbPath is ignored */
  eventStore?: EventStore;
  /** Browser automation configuration */
  browser?: BrowserConfig;
}

/**
 * Browser service configuration
 */
export interface BrowserConfig {
  /** Run browser in headless mode (default: true) */
  headless?: boolean;
  /** Browser viewport size (default: 1280x800) */
  viewport?: { width: number; height: number };
  /** Action timeout in ms (default: 30000) */
  timeout?: number;
}

// =============================================================================
// Worktree Types
// =============================================================================

/**
 * Worktree status information for a session
 */
export interface WorktreeInfo {
  /** Whether this session uses an isolated worktree */
  isolated: boolean;
  /** Git branch name */
  branch: string;
  /** Base commit hash when worktree was created */
  baseCommit: string;
  /** Filesystem path to the working directory */
  path: string;
  /** Whether there are uncommitted changes */
  hasUncommittedChanges?: boolean;
  /** Number of commits since base */
  commitCount?: number;
}

// =============================================================================
// Session Types
// =============================================================================

export interface ActiveSession {
  sessionId: SessionId;
  agent: TronAgent;
  isProcessing: boolean;
  lastActivity: Date;
  workingDirectory: string;
  model: string;
  /** WorkingDirectory abstraction (if worktree coordination is enabled) */
  workingDir?: WorkingDirectory;
  /** Current turn number (tracked for discrete event storage) */
  currentTurn: number;
  /**
   * Encapsulated content tracker for both accumulated and per-turn tracking.
   * Replaces the individual tracking fields below.
   */
  turnTracker: TurnContentTracker;
  /**
   * In-memory head event ID for linearizing event appends.
   * Updated synchronously BEFORE async DB writes to prevent race conditions
   * where multiple rapid events all read the same headEventId from DB.
   */
  pendingHeadEventId: EventId | null;
  /**
   * Promise chain that serializes event appends for this session.
   * Each append chains to the previous one, ensuring ordered persistence.
   */
  appendPromiseChain: Promise<void>;
  /**
   * P0 FIX: Track append errors to prevent malformed event trees.
   * If an append fails, subsequent appends are skipped to preserve chain integrity.
   */
  lastAppendError?: Error;
  /**
   * Accumulated text content from ALL turns in the current agent run.
   * Used to provide catch-up content when client resumes into running session.
   * Cleared at agent_start, accumulated on message_update across all turns,
   * cleared at agent_end. NOT reset at turn boundaries so resuming during
   * Turn N shows content from Turn 1, 2, ..., N.
   */
  currentTurnAccumulatedText: string;
  /**
   * Tool calls from ALL turns in the current agent run.
   * Used to provide catch-up content when client resumes into running session.
   * Cleared at agent_start, updated on tool_start/tool_end across all turns,
   * cleared at agent_end. NOT reset at turn boundaries so resuming during
   * Turn N shows tools from Turn 1, 2, ..., N.
   */
  currentTurnToolCalls: CurrentTurnToolCall[];
  /**
   * Content sequence tracking the order of text and tool calls.
   * Each entry is either {type: 'text', text: string} or {type: 'tool_ref', toolCallId: string}.
   * This preserves the interleaving order for proper reconstruction on interrupt.
   */
  currentTurnContentSequence: Array<{type: 'text', text: string} | {type: 'tool_ref', toolCallId: string}>;
  /**
   * Flag indicating if this session was interrupted by user.
   * Used to inform clients that the session ended due to interruption.
   */
  wasInterrupted?: boolean;
  /**
   * Token usage from the most recent turn_end event.
   * Contains PER-TURN values (not cumulative) directly from the LLM response.
   * Used to populate message.assistant.tokenUsage with accurate per-message tokens.
   * Includes cache token breakdown for accurate cost calculation.
   */
  lastTurnTokenUsage?: {
    inputTokens: number;
    outputTokens: number;
    cacheReadTokens?: number;
    cacheCreationTokens?: number;
  };
  /**
   * Start time of the current turn (set at turn_start).
   * Used to calculate latency for this turn's message.assistant event.
   */
  currentTurnStartTime?: number;
  /**
   * Content for THIS TURN ONLY (cleared after each message.assistant is created).
   * Separate from currentTurnAccumulatedText which accumulates across ALL turns for catch-up.
   */
  thisTurnContent: Array<{type: 'text', text: string} | {type: 'tool_ref', toolCallId: string}>;
  /**
   * Tool calls for THIS TURN ONLY (cleared after each message.assistant is created).
   * Maps toolCallId to full tool call data for this turn.
   */
  thisTurnToolCalls: Map<string, CurrentTurnToolCall>;
  /**
   * Current reasoning level for extended thinking models.
   * Tracked in-memory to detect changes and persist events.
   */
  reasoningLevel?: 'low' | 'medium' | 'high' | 'xhigh';
  /**
   * Parallel array tracking eventIds for messages in the context manager.
   * Used by ContextAuditView to enable message deletion.
   * Index corresponds to context manager message index.
   * May be undefined for messages created during current session (not yet persisted).
   */
  messageEventIds: (string | undefined)[];
  /**
   * Tracks skills explicitly added to this session's context.
   * Reconstructed from events on session resume/fork/rewind.
   * Cleared on context clear and compaction.
   */
  skillTracker: SkillTracker;
}

// =============================================================================
// Agent Run Types
// =============================================================================

/** File attachment from client (iOS app or web) */
export interface FileAttachment {
  /** Base64 encoded file data */
  data: string;
  /** MIME type (e.g., "image/jpeg", "application/pdf") */
  mimeType: string;
  /** Optional original filename */
  fileName?: string;
}

/** Skill reference passed with a prompt (explicitly selected by user) */
export interface PromptSkillRef {
  /** Skill name */
  name: string;
  /** Where the skill is from */
  source: 'global' | 'project';
}

/** Loaded skill content for injection into prompt */
export interface LoadedSkillContent {
  /** Skill name */
  name: string;
  /** Full SKILL.md content */
  content: string;
}

export interface AgentRunOptions {
  sessionId: string;
  prompt: string;
  onEvent?: (event: AgentEvent) => void;
  /** Reasoning effort level for OpenAI Codex models (low/medium/high/xhigh) */
  reasoningLevel?: 'low' | 'medium' | 'high' | 'xhigh';
  /** Optional image attachments (base64) - legacy, use attachments instead */
  images?: FileAttachment[];
  /** Optional file attachments (images and PDFs) */
  attachments?: FileAttachment[];
  /** Skills explicitly selected by user (via skill sheet or @mention in prompt) */
  skills?: PromptSkillRef[];
  /**
   * Callback to load skill content by names.
   * Called after skills are tracked to inject skill content into the prompt.
   */
  skillLoader?: (skillNames: string[]) => Promise<LoadedSkillContent[]>;
}

export interface AgentEvent {
  type: 'text' | 'tool_start' | 'tool_end' | 'turn_complete' | 'turn_interrupted' | 'error';
  sessionId: string;
  timestamp: string;
  data: unknown;
}

// =============================================================================
// Session Management Types
// =============================================================================

export interface CreateSessionOptions {
  workingDirectory: string;
  model?: string;
  provider?: string;
  title?: string;
  tags?: string[];
  systemPrompt?: string;
  /** Force worktree isolation even if not needed */
  forceIsolation?: boolean;
}

export interface SessionInfo {
  sessionId: string;
  workingDirectory: string;
  model: string;
  messageCount: number;
  eventCount: number;
  inputTokens: number;
  outputTokens: number;
  /** Current context size (input_tokens from last API call) */
  lastTurnInputTokens: number;
  cost: number;
  createdAt: string;
  lastActivity: string;
  isActive: boolean;
  /** Worktree status (if worktree coordination is enabled) */
  worktree?: WorktreeInfo;
  /** Parent session ID if this is a forked session */
  parentSessionId?: string;
}

// =============================================================================
// Fork/Rewind Types
// =============================================================================

export interface ForkResult {
  newSessionId: string;
  rootEventId: string;
  forkedFromEventId: string;
  forkedFromSessionId: string;
  /** Worktree status for the forked session */
  worktree?: WorktreeInfo;
}

export interface RewindResult {
  sessionId: string;
  newHeadEventId: string;
  previousHeadEventId: string;
}
