/**
 * @fileoverview Orchestrator Type Definitions
 *
 * Contains all type definitions for the EventStoreOrchestrator including
 * configuration, session state, and result types.
 */
// Direct imports to avoid circular dependencies through index.js
import { EventStore } from '@infrastructure/events/event-store.js';
import { TronAgent } from '../agent/tron-agent.js';
import type { SessionId } from '@infrastructure/events/types.js';
import type { WorkingDirectory } from '@platform/session/working-directory.js';
import type { WorktreeCoordinatorConfig } from '@platform/session/worktree-coordinator.js';
import type { SkillTracker } from '@capabilities/extensions/skills/skill-tracker.js';
import type { RulesTracker } from '@context/rules-tracker.js';
import type { SubAgentTracker } from '@capabilities/tools/subagent/subagent-tracker.js';
import type { TodoTracker } from '@capabilities/todos/todo-tracker.js';
import type { SessionContext } from './session/session-context.js';
import type { ReasoningLevel } from '../agent/types.js';

// =============================================================================
// Configuration
// =============================================================================

export interface EventStoreOrchestratorConfig {
  /** Path to event store database (defaults to ~/.tron/database/prod.db) */
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
  /** Blocked domains for web tools (optional) */
  blockedWebDomains?: string[];
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
// Session Types — Sub-interfaces
// =============================================================================

/**
 * Immutable identity of an active session.
 * Set at creation time, never changes during the session's lifetime.
 */
export interface SessionIdentity {
  sessionId: SessionId;
  workingDirectory: string;
  model: string;
  /** Parent session ID if this is a subagent session (for event forwarding) */
  parentSessionId?: SessionId;
}

/**
 * Runtime execution dependencies for the session.
 * Created at session start, destroyed at session end.
 */
export interface SessionRuntime {
  agent: TronAgent;
  sessionContext: SessionContext;
  /** WorkingDirectory abstraction (if worktree coordination is enabled) */
  workingDir?: WorkingDirectory;
}

/**
 * Tracker instances for session-scoped state.
 * Each tracker is reconstructed from events on session resume/fork.
 */
export interface SessionTracking {
  skillTracker: SkillTracker;
  rulesTracker: RulesTracker;
  subagentTracker: SubAgentTracker;
  todoTracker: TodoTracker;
}

/**
 * Mutable metadata that changes during the session's lifecycle.
 */
export interface SessionMetadata {
  lastActivity: Date;
  /** Flag indicating if this session was interrupted by user */
  wasInterrupted?: boolean;
  /** Current reasoning level for extended thinking models */
  reasoningLevel?: ReasoningLevel;
  /** Current run ID — set when a run starts, cleared when it completes */
  currentRunId?: string;
}

// =============================================================================
// Session Types — Composed
// =============================================================================

/**
 * Complete active session state.
 *
 * Composed from four focused sub-interfaces:
 * - SessionIdentity:  immutable session identity (id, directory, model, parent)
 * - SessionRuntime:   agent instance and persistence context
 * - SessionTracking:  skill/rules/subagent/todo trackers
 * - SessionMetadata:  mutable activity/interruption/reasoning state
 *
 * Consumers that only need a subset should accept the appropriate sub-interface.
 */
export type ActiveSession = SessionIdentity & SessionRuntime & SessionTracking & SessionMetadata;

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
  /** Parsed frontmatter (optional, for tool preferences) */
  frontmatter?: {
    allowedTools?: string[];
    tools?: string[];
    [key: string]: unknown;
  };
}

export interface AgentRunOptions {
  sessionId: string;
  prompt: string;
  onEvent?: (event: AgentEvent) => void;
  /** Reasoning effort level for models with reasoning/effort support (Codex, Opus 4.6) */
  reasoningLevel?: ReasoningLevel;
  /** Optional image attachments (base64) - legacy, use attachments instead */
  images?: FileAttachment[];
  /** Optional file attachments (images and PDFs) */
  attachments?: FileAttachment[];
  /** Skills explicitly selected by user (via skill sheet or @mention in prompt) */
  skills?: PromptSkillRef[];
  /**
   * Spells (ephemeral skills) - injected for one prompt only, not tracked via events.
   * Spells are automatically "forgotten" after the turn - subsequent prompts will
   * include them in the "stop following" instruction.
   */
  spells?: PromptSkillRef[];
  /**
   * Callback to load skill content by names.
   * Called after skills are tracked to inject skill content into the prompt.
   */
  skillLoader?: (skillNames: string[]) => Promise<LoadedSkillContent[]>;
  /**
   * Unique identifier for this agent run.
   * Generated by the caller (agent adapter) and propagated through all events.
   * Used to correlate events belonging to the same run.
   */
  runId?: string;
  /**
   * Optional abort signal for cancellation.
   * Used by subagent guardrail timeout to abort runaway executions.
   */
  signal?: AbortSignal;
}

export interface AgentEvent {
  type: 'text' | 'tool_start' | 'tool_end' | 'turn_complete' | 'turn_interrupted' | 'error';
  sessionId: string;
  timestamp: string;
  data: unknown;
  /** Run ID for correlating events to a specific agent run */
  runId?: string;
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
  /**
   * Tool denial configuration.
   * Subagent inherits all parent tools minus any specified denials.
   * - undefined: all tools available (default for agent type)
   * - { denyAll: true }: no tools (text generation only)
   * - { tools: ['Bash', 'Write'] }: deny specific tools
   * - { rules: [...] }: granular denial with parameter patterns
   */
  toolDenials?: import('../../capabilities/tools/subagent/tool-denial.js').ToolDenialConfig;
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
