/**
 * @fileoverview Event-Sourced Session Tree Types
 *
 * Core types for the immutable event log. All events are append-only
 * and form a tree structure via parentId chains.
 *
 * Design principles:
 * 1. Every event is immutable - never modified after creation
 * 2. Events form a tree via parentId chains
 * 3. Sessions are pointers to head events
 * 4. State is reconstructed by replaying events
 */

// =============================================================================
// Branded Types for Type Safety
// =============================================================================

/** Globally unique event identifier (UUID v7 for time-ordering) */
export type EventId = string & { readonly __brand: 'EventId' };

/** Session identifier - groups related events */
export type SessionId = string & { readonly __brand: 'SessionId' };

/** Workspace identifier - project/directory scope */
export type WorkspaceId = string & { readonly __brand: 'WorkspaceId' };

/** Branch identifier for named branches */
export type BranchId = string & { readonly __brand: 'BranchId' };

// Type constructors
export const EventId = (id: string): EventId => id as EventId;
export const SessionId = (id: string): SessionId => id as SessionId;
export const WorkspaceId = (id: string): WorkspaceId => id as WorkspaceId;
export const BranchId = (id: string): BranchId => id as BranchId;

// =============================================================================
// Event Type Discriminator
// =============================================================================

export type EventType =
  // Session lifecycle
  | 'session.start'
  | 'session.end'
  | 'session.fork'
  | 'session.branch'
  // Conversation
  | 'message.user'
  | 'message.assistant'
  | 'message.system'
  // Tool execution
  | 'tool.call'
  | 'tool.result'
  // Streaming (for real-time reconstruction)
  | 'stream.text_delta'
  | 'stream.thinking_delta'
  | 'stream.turn_start'
  | 'stream.turn_end'
  // Model/config changes
  | 'config.model_switch'
  | 'config.prompt_update'
  // Ledger/state
  | 'ledger.update'
  | 'ledger.goal'
  | 'ledger.task'
  // Compaction/summarization
  | 'compact.boundary'
  | 'compact.summary'
  // Metadata
  | 'metadata.update'
  | 'metadata.tag'
  // File operations (for change tracking)
  | 'file.read'
  | 'file.write'
  | 'file.edit'
  // Worktree/git operations
  | 'worktree.acquired'
  | 'worktree.commit'
  | 'worktree.released'
  | 'worktree.merged'
  // Error events
  | 'error.agent'
  | 'error.tool'
  | 'error.provider';

// =============================================================================
// Base Event Structure
// =============================================================================

/**
 * Base event structure - all events extend this.
 * Uses UUID v7 for chronologically sortable IDs.
 */
export interface BaseEvent {
  /** Unique event ID (UUID v7 - time-ordered) */
  id: EventId;
  /** Parent event ID - null only for root events */
  parentId: EventId | null;
  /** Session this event belongs to */
  sessionId: SessionId;
  /** Workspace/project scope for queries */
  workspaceId: WorkspaceId;
  /** ISO 8601 timestamp with millisecond precision */
  timestamp: string;
  /** Event type discriminator */
  type: EventType;
  /** Monotonic sequence within session for ordering */
  sequence: number;
  /** Hash of (parentId + payload) for integrity verification */
  checksum?: string;
}

// =============================================================================
// Token Usage
// =============================================================================

export interface TokenUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens?: number;
  cacheCreationTokens?: number;
}

// =============================================================================
// Session Events
// =============================================================================

/**
 * Session start event - root of a session tree
 */
export interface SessionStartEvent extends BaseEvent {
  type: 'session.start';
  payload: {
    workingDirectory: string;
    model: string;
    provider: string;
    systemPrompt?: string;
    title?: string;
    tags?: string[];
    /** If this is a fork, reference the source */
    forkedFrom?: {
      sessionId: SessionId;
      eventId: EventId;
    };
  };
}

/**
 * Session end event
 */
export interface SessionEndEvent extends BaseEvent {
  type: 'session.end';
  payload: {
    reason: 'completed' | 'aborted' | 'error' | 'timeout';
    summary?: string;
    totalTokenUsage?: TokenUsage;
    duration?: number; // milliseconds
  };
}

/**
 * Session fork event - marks a fork point
 */
export interface SessionForkEvent extends BaseEvent {
  type: 'session.fork';
  payload: {
    /** Source session we forked from */
    sourceSessionId: SessionId;
    /** Event ID we forked from */
    sourceEventId: EventId;
    /** Name for the fork */
    name?: string;
    /** Why was this forked */
    reason?: string;
  };
}

/**
 * Named branch creation
 */
export interface SessionBranchEvent extends BaseEvent {
  type: 'session.branch';
  payload: {
    branchId: BranchId;
    name: string;
    description?: string;
  };
}

// =============================================================================
// Message Events
// =============================================================================

/** Content block types for messages */
export type ContentBlock =
  | { type: 'text'; text: string }
  | { type: 'image'; source: { type: 'base64'; mediaType: string; data: string } }
  | { type: 'tool_use'; id: string; name: string; input: Record<string, unknown> }
  | { type: 'tool_result'; toolUseId: string; content: string; isError?: boolean }
  | { type: 'thinking'; thinking: string };

/**
 * User message event
 */
export interface UserMessageEvent extends BaseEvent {
  type: 'message.user';
  payload: {
    content: string | ContentBlock[];
    /** Turn number within session */
    turn: number;
    /** Optional attached images */
    imageCount?: number;
  };
}

/**
 * Assistant message event
 */
export interface AssistantMessageEvent extends BaseEvent {
  type: 'message.assistant';
  payload: {
    content: ContentBlock[];
    turn: number;
    tokenUsage: TokenUsage;
    stopReason: 'end_turn' | 'tool_use' | 'max_tokens' | 'stop_sequence';
    /** Duration of LLM call in ms */
    latency?: number;
    /** Model used (may differ from session default) */
    model: string;
    /** Whether extended thinking was used */
    hasThinking?: boolean;
  };
}

/**
 * System message event
 */
export interface SystemMessageEvent extends BaseEvent {
  type: 'message.system';
  payload: {
    content: string;
    source: 'compaction' | 'context' | 'hook' | 'error' | 'inject';
  };
}

// =============================================================================
// Tool Events
// =============================================================================

/**
 * Tool call event
 */
export interface ToolCallEvent extends BaseEvent {
  type: 'tool.call';
  payload: {
    toolCallId: string;
    name: string;
    arguments: Record<string, unknown>;
    turn: number;
  };
}

/**
 * Tool result event
 */
export interface ToolResultEvent extends BaseEvent {
  type: 'tool.result';
  payload: {
    toolCallId: string;
    content: string;
    isError: boolean;
    duration: number; // milliseconds
    /** Files affected (for change tracking) */
    affectedFiles?: string[];
    /** Whether result was truncated */
    truncated?: boolean;
  };
}

// =============================================================================
// Streaming Events
// =============================================================================

/**
 * Turn start event
 */
export interface StreamTurnStartEvent extends BaseEvent {
  type: 'stream.turn_start';
  payload: {
    turn: number;
  };
}

/**
 * Turn end event
 */
export interface StreamTurnEndEvent extends BaseEvent {
  type: 'stream.turn_end';
  payload: {
    turn: number;
    tokenUsage: TokenUsage;
  };
}

/**
 * Text delta for streaming reconstruction
 */
export interface StreamTextDeltaEvent extends BaseEvent {
  type: 'stream.text_delta';
  payload: {
    delta: string;
    turn: number;
    /** Content block index */
    blockIndex?: number;
  };
}

/**
 * Thinking delta for streaming reconstruction
 */
export interface StreamThinkingDeltaEvent extends BaseEvent {
  type: 'stream.thinking_delta';
  payload: {
    delta: string;
    turn: number;
  };
}

// =============================================================================
// Config Events
// =============================================================================

/**
 * Model switch event
 */
export interface ConfigModelSwitchEvent extends BaseEvent {
  type: 'config.model_switch';
  payload: {
    previousModel: string;
    newModel: string;
    reason?: string;
  };
}

/**
 * System prompt update
 */
export interface ConfigPromptUpdateEvent extends BaseEvent {
  type: 'config.prompt_update';
  payload: {
    previousHash?: string;
    newHash: string;
    /** Content stored separately in blobs table */
    contentBlobId?: string;
  };
}

// =============================================================================
// Ledger Events
// =============================================================================

/**
 * Ledger update event
 */
export interface LedgerUpdateEvent extends BaseEvent {
  type: 'ledger.update';
  payload: {
    field: 'goal' | 'now' | 'next' | 'done' | 'constraints' | 'decisions' | 'workingFiles';
    previousValue?: unknown;
    newValue: unknown;
  };
}

/**
 * Goal event
 */
export interface LedgerGoalEvent extends BaseEvent {
  type: 'ledger.goal';
  payload: {
    goal: string;
  };
}

/**
 * Task event
 */
export interface LedgerTaskEvent extends BaseEvent {
  type: 'ledger.task';
  payload: {
    action: 'add' | 'complete' | 'remove';
    task: string;
    list: 'next' | 'done';
  };
}

// =============================================================================
// Compaction Events
// =============================================================================

/**
 * Compaction boundary - marks where context was summarized
 */
export interface CompactBoundaryEvent extends BaseEvent {
  type: 'compact.boundary';
  payload: {
    /** Events being summarized (from, to) */
    range: { from: EventId; to: EventId };
    /** Token count before compaction */
    originalTokens: number;
    /** Token count after compaction */
    compactedTokens: number;
  };
}

/**
 * Compaction summary - the actual summarized content
 */
export interface CompactSummaryEvent extends BaseEvent {
  type: 'compact.summary';
  payload: {
    summary: string;
    keyDecisions?: string[];
    filesModified?: string[];
    /** Link to boundary event */
    boundaryEventId: EventId;
  };
}

// =============================================================================
// Metadata Events
// =============================================================================

/**
 * Metadata update event
 */
export interface MetadataUpdateEvent extends BaseEvent {
  type: 'metadata.update';
  payload: {
    key: string;
    previousValue?: unknown;
    newValue: unknown;
  };
}

/**
 * Tag event
 */
export interface MetadataTagEvent extends BaseEvent {
  type: 'metadata.tag';
  payload: {
    action: 'add' | 'remove';
    tag: string;
  };
}

// =============================================================================
// File Events
// =============================================================================

/**
 * File read event
 */
export interface FileReadEvent extends BaseEvent {
  type: 'file.read';
  payload: {
    path: string;
    lines?: { start: number; end: number };
  };
}

/**
 * File write event
 */
export interface FileWriteEvent extends BaseEvent {
  type: 'file.write';
  payload: {
    path: string;
    size: number;
    /** Content hash for deduplication */
    contentHash: string;
  };
}

/**
 * File edit event
 */
export interface FileEditEvent extends BaseEvent {
  type: 'file.edit';
  payload: {
    path: string;
    oldString: string;
    newString: string;
    /** Patch/diff representation */
    diff?: string;
  };
}

// =============================================================================
// Worktree Events
// =============================================================================

/**
 * Worktree acquired event - session has a working directory
 */
export interface WorktreeAcquiredEvent extends BaseEvent {
  type: 'worktree.acquired';
  payload: {
    /** Filesystem path to working directory */
    path: string;
    /** Git branch name */
    branch: string;
    /** Starting commit hash */
    baseCommit: string;
    /** Whether this is isolated (worktree) or shared (main directory) */
    isolated: boolean;
    /** If forked, the parent session's info */
    forkedFrom?: {
      sessionId: SessionId;
      commit: string;
    };
  };
}

/**
 * Worktree commit event - changes committed in session's worktree
 */
export interface WorktreeCommitEvent extends BaseEvent {
  type: 'worktree.commit';
  payload: {
    /** Git commit hash */
    commitHash: string;
    /** Commit message */
    message: string;
    /** Files changed in this commit */
    filesChanged: string[];
    /** Number of insertions */
    insertions?: number;
    /** Number of deletions */
    deletions?: number;
  };
}

/**
 * Worktree released event - session released its working directory
 */
export interface WorktreeReleasedEvent extends BaseEvent {
  type: 'worktree.released';
  payload: {
    /** Final commit hash (if changes were committed) */
    finalCommit?: string;
    /** Whether worktree was deleted */
    deleted: boolean;
    /** Whether branch was preserved */
    branchPreserved: boolean;
  };
}

/**
 * Worktree merged event - session's branch was merged
 */
export interface WorktreeMergedEvent extends BaseEvent {
  type: 'worktree.merged';
  payload: {
    /** Branch that was merged */
    sourceBranch: string;
    /** Target branch */
    targetBranch: string;
    /** Merge commit hash */
    mergeCommit: string;
    /** Merge strategy used */
    strategy: 'merge' | 'rebase' | 'squash';
  };
}

// =============================================================================
// Error Events
// =============================================================================

/**
 * Agent error event
 */
export interface ErrorAgentEvent extends BaseEvent {
  type: 'error.agent';
  payload: {
    error: string;
    code?: string;
    recoverable: boolean;
  };
}

/**
 * Tool error event
 */
export interface ErrorToolEvent extends BaseEvent {
  type: 'error.tool';
  payload: {
    toolName: string;
    toolCallId: string;
    error: string;
    code?: string;
  };
}

/**
 * Provider error event
 */
export interface ErrorProviderEvent extends BaseEvent {
  type: 'error.provider';
  payload: {
    provider: string;
    error: string;
    code?: string;
    retryable: boolean;
    retryAfter?: number;
  };
}

// =============================================================================
// Union Type
// =============================================================================

export type SessionEvent =
  // Session lifecycle
  | SessionStartEvent
  | SessionEndEvent
  | SessionForkEvent
  | SessionBranchEvent
  // Messages
  | UserMessageEvent
  | AssistantMessageEvent
  | SystemMessageEvent
  // Tools
  | ToolCallEvent
  | ToolResultEvent
  // Streaming
  | StreamTurnStartEvent
  | StreamTurnEndEvent
  | StreamTextDeltaEvent
  | StreamThinkingDeltaEvent
  // Config
  | ConfigModelSwitchEvent
  | ConfigPromptUpdateEvent
  // Ledger
  | LedgerUpdateEvent
  | LedgerGoalEvent
  | LedgerTaskEvent
  // Compaction
  | CompactBoundaryEvent
  | CompactSummaryEvent
  // Metadata
  | MetadataUpdateEvent
  | MetadataTagEvent
  // Files
  | FileReadEvent
  | FileWriteEvent
  | FileEditEvent
  // Worktree
  | WorktreeAcquiredEvent
  | WorktreeCommitEvent
  | WorktreeReleasedEvent
  | WorktreeMergedEvent
  // Errors
  | ErrorAgentEvent
  | ErrorToolEvent
  | ErrorProviderEvent;

// =============================================================================
// Type Guards
// =============================================================================

export function isSessionStartEvent(event: SessionEvent): event is SessionStartEvent {
  return event.type === 'session.start';
}

export function isSessionEndEvent(event: SessionEvent): event is SessionEndEvent {
  return event.type === 'session.end';
}

export function isSessionForkEvent(event: SessionEvent): event is SessionForkEvent {
  return event.type === 'session.fork';
}

export function isUserMessageEvent(event: SessionEvent): event is UserMessageEvent {
  return event.type === 'message.user';
}

export function isAssistantMessageEvent(event: SessionEvent): event is AssistantMessageEvent {
  return event.type === 'message.assistant';
}

export function isToolCallEvent(event: SessionEvent): event is ToolCallEvent {
  return event.type === 'tool.call';
}

export function isToolResultEvent(event: SessionEvent): event is ToolResultEvent {
  return event.type === 'tool.result';
}

export function isMessageEvent(event: SessionEvent): event is UserMessageEvent | AssistantMessageEvent | SystemMessageEvent {
  return event.type === 'message.user' || event.type === 'message.assistant' || event.type === 'message.system';
}

export function isStreamingEvent(event: SessionEvent): boolean {
  return event.type.startsWith('stream.');
}

export function isErrorEvent(event: SessionEvent): event is ErrorAgentEvent | ErrorToolEvent | ErrorProviderEvent {
  return event.type.startsWith('error.');
}

export function isWorktreeEvent(event: SessionEvent): event is WorktreeAcquiredEvent | WorktreeCommitEvent | WorktreeReleasedEvent | WorktreeMergedEvent {
  return event.type.startsWith('worktree.');
}

export function isWorktreeAcquiredEvent(event: SessionEvent): event is WorktreeAcquiredEvent {
  return event.type === 'worktree.acquired';
}

export function isWorktreeCommitEvent(event: SessionEvent): event is WorktreeCommitEvent {
  return event.type === 'worktree.commit';
}

export function isWorktreeReleasedEvent(event: SessionEvent): event is WorktreeReleasedEvent {
  return event.type === 'worktree.released';
}

export function isWorktreeMergedEvent(event: SessionEvent): event is WorktreeMergedEvent {
  return event.type === 'worktree.merged';
}

// =============================================================================
// Event Creation Helpers
// =============================================================================

export type CreateEventInput<T extends SessionEvent> = Omit<T, 'id' | 'timestamp' | 'sequence' | 'checksum'>;

// =============================================================================
// Message Type (for API compatibility)
// =============================================================================

/** Message format for API calls */
export interface Message {
  role: 'user' | 'assistant' | 'system';
  content: string | ContentBlock[];
}

// =============================================================================
// Session State (Reconstructed from Events)
// =============================================================================

export interface SessionState {
  /** Session ID */
  sessionId: SessionId;
  /** Workspace ID */
  workspaceId: WorkspaceId;
  /** The head event this state is at */
  headEventId: EventId;
  /** Current model */
  model: string;
  /** Working directory */
  workingDirectory: string;
  /** All messages up to this point (for API calls) */
  messages: Message[];
  /** Total token usage */
  tokenUsage: TokenUsage;
  /** Turn count */
  turnCount: number;
  /** Current provider */
  provider?: string;
  /** System prompt */
  systemPrompt?: string;
  /** Current turn number (deprecated, use turnCount) */
  currentTurn?: number;
  /** Session metadata */
  metadata?: SessionMetadata;
  /** Active files being worked on */
  activeFiles?: string[];
  /** Session status */
  status?: 'active' | 'ended';
  /** Branch information */
  branch?: {
    id: BranchId;
    name: string;
  };
  /** Timestamp of this state */
  timestamp?: string;
  /** Ledger state reconstructed from ledger.update events */
  ledger?: {
    goal: string;
    now: string;
    next: string[];
    done: string[];
    constraints: string[];
    workingFiles: string[];
    decisions: Array<{ choice: string; reason: string; timestamp?: string }>;
  };
}

export interface SessionMetadata {
  title?: string;
  tags: string[];
  created: string;
  lastActivity: string;
  forkedFrom?: {
    sessionId: SessionId;
    eventId: EventId;
  };
  custom: Record<string, unknown>;
}

// =============================================================================
// Tree Structures
// =============================================================================

export interface Branch {
  /** Branch identifier */
  id: BranchId;
  /** Human-readable name */
  name: string;
  /** Session this branch belongs to */
  sessionId: SessionId;
  /** Root event of this branch (fork point) */
  rootEventId: EventId;
  /** Current head event */
  headEventId: EventId;
  /** Number of events in branch */
  eventCount: number;
  /** Creation timestamp */
  created: string;
  /** Last activity */
  lastActivity: string;
  /** Is this the main/default branch */
  isDefault: boolean;
}

export interface TreeNode {
  /** Event at this node */
  eventId: EventId;
  /** Event type */
  type: EventType;
  /** Timestamp */
  timestamp: string;
  /** Summary for display */
  summary: string;
  /** Child nodes (branches from this point) */
  children: TreeNode[];
  /** Depth in tree */
  depth: number;
  /** Is this the current head of any branch */
  isHead: boolean;
  /** Is this a branching point (multiple children) */
  isBranchPoint: boolean;
  /** Branch this node belongs to */
  branchId?: BranchId;
}

export interface TreeNodeCompact {
  id: EventId;
  parentId: EventId | null;
  type: EventType;
  timestamp: string;
  summary: string;
  hasChildren: boolean;
  childCount: number;
  depth: number;
  isBranchPoint: boolean;
  isHead: boolean;
}

// =============================================================================
// Query Types
// =============================================================================

export interface SearchResult {
  eventId: EventId;
  sessionId: SessionId;
  type: EventType;
  timestamp: string;
  /** Matched content snippet */
  snippet: string;
  /** Match relevance score */
  score: number;
}

export interface SessionSummary {
  sessionId: SessionId;
  workspaceId: WorkspaceId;
  title?: string;
  eventCount: number;
  messageCount: number;
  branchCount: number;
  tokenUsage: TokenUsage;
  created: string;
  lastActivity: string;
  status: 'active' | 'ended';
  tags: string[];
}

// =============================================================================
// Workspace
// =============================================================================

export interface Workspace {
  id: WorkspaceId;
  path: string;
  name?: string;
  created: string;
  lastActivity: string;
  sessionCount: number;
}
