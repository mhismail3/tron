/**
 * @fileoverview Orchestrator Type Definitions
 *
 * Contains all type definitions for the EventStoreOrchestrator including
 * configuration, session state, and result types.
 */
import {
  EventStore,
  TronAgent,
  type SessionId,
  type WorkingDirectory,
  type WorktreeCoordinatorConfig,
  type SkillTracker,
  type RulesTracker,
  type SubAgentTracker,
  type TodoTracker,
} from '../index.js';
import type { SessionContext } from './session-context.js';

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
  /** Parent session ID if this is a subagent session (for event forwarding) */
  parentSessionId?: SessionId;
  /** WorkingDirectory abstraction (if worktree coordination is enabled) */
  workingDir?: WorkingDirectory;
  /**
   * Flag indicating if this session was interrupted by user.
   * Used to inform clients that the session ended due to interruption.
   */
  wasInterrupted?: boolean;
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
   * Reconstructed from events on session resume/fork.
   * Cleared on context clear and compaction.
   */
  skillTracker: SkillTracker;
  /**
   * Tracks rules files loaded for this session's context.
   * Loaded once at session start, reconstructed from events on resume/fork.
   * Rules are immutable for the session (no remove operation).
   */
  rulesTracker: RulesTracker;
  /**
   * SessionContext for modular state management.
   * Encapsulates EventPersister, TurnManager, PlanModeHandler.
   * All turn tracking, event persistence, and plan mode state are managed here.
   */
  sessionContext: SessionContext;
  /**
   * Tracks sub-agents spawned by this session.
   * Reconstructed from events on session resume/fork.
   */
  subagentTracker: SubAgentTracker;
  /**
   * Tracks todos/tasks for this session.
   * Reconstructed from events on session resume/fork.
   * Cleared on context clear (incomplete tasks -> backlog).
   */
  todoTracker: TodoTracker;
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
  /** Parsed frontmatter (optional, for plan mode detection) */
  frontmatter?: {
    planMode?: boolean;
    tools?: string[];
    [key: string]: unknown;
  };
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
  /** Parent session ID if this is a subagent session (for event forwarding) */
  parentSessionId?: string;
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
  /** Total tokens read from prompt cache */
  cacheReadTokens: number;
  /** Total tokens written to prompt cache */
  cacheCreationTokens: number;
  cost: number;
  createdAt: string;
  lastActivity: string;
  isActive: boolean;
  /** Worktree status (if worktree coordination is enabled) */
  worktree?: WorktreeInfo;
  /** Parent session ID if this is a forked session */
  parentSessionId?: string;
  /** Last user prompt text (for preview display) */
  lastUserPrompt?: string;
  /** Last assistant response text (for preview display) */
  lastAssistantResponse?: string;
}

// =============================================================================
// Fork Types
// =============================================================================

export interface ForkResult {
  newSessionId: string;
  rootEventId: string;
  forkedFromEventId: string;
  forkedFromSessionId: string;
  /** Worktree status for the forked session */
  worktree?: WorktreeInfo;
}
