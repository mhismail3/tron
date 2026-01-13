/**
 * @fileoverview RPC Protocol Types
 *
 * Defines the message protocol for communication between
 * clients (TUI, Web) and the server.
 */

import type {
  EventType,
  SessionEvent,
  Message,
  TokenUsage,
} from '../events/types.js';

// Re-export branded types for convenience
export type { EventId, SessionId, WorkspaceId, BranchId } from '../events/types.js';

// =============================================================================
// Request/Response Pattern
// =============================================================================

/**
 * Base request structure - all requests have an id and method
 */
export interface RpcRequest<TMethod extends string = string, TParams = unknown> {
  /** Unique request identifier for correlation */
  id: string;
  /** The method being called */
  method: TMethod;
  /** Method parameters */
  params?: TParams;
}

/**
 * Base response structure
 */
export interface RpcResponse<TResult = unknown> {
  /** Request ID this response is for */
  id: string;
  /** Whether the request succeeded */
  success: boolean;
  /** Result data (if success) */
  result?: TResult;
  /** Error information (if !success) */
  error?: RpcError;
}

/**
 * Error structure for failed requests
 */
export interface RpcError {
  /** Error code */
  code: string;
  /** Human-readable message */
  message: string;
  /** Additional error details */
  details?: unknown;
}

// =============================================================================
// Event Types (Server → Client)
// =============================================================================

/**
 * Server-to-client events for real-time updates
 */
export interface RpcEvent<TType extends string = string, TData = unknown> {
  /** Event type identifier */
  type: TType;
  /** Session ID if applicable */
  sessionId?: string;
  /** Event timestamp */
  timestamp: string;
  /** Event-specific data */
  data: TData;
}

// =============================================================================
// Method Definitions
// =============================================================================

/**
 * Available RPC methods
 */
export type RpcMethod =
  // Session management
  | 'session.create'
  | 'session.resume'
  | 'session.list'
  | 'session.delete'
  | 'session.fork'
  | 'session.rewind'
  | 'session.getHead'
  | 'session.getState'
  // Worktree operations
  | 'worktree.getStatus'
  | 'worktree.commit'
  | 'worktree.merge'
  | 'worktree.list'
  // Event operations
  | 'events.getHistory'
  | 'events.getSince'
  | 'events.subscribe'
  | 'events.unsubscribe'
  | 'events.append'
  // Tree operations
  | 'tree.getVisualization'
  | 'tree.getBranches'
  | 'tree.getSubtree'
  | 'tree.getAncestors'
  | 'tree.compareBranches'
  // Agent interaction
  | 'agent.prompt'
  | 'agent.abort'
  | 'agent.getState'
  // Model management
  | 'model.switch'
  | 'model.list'
  // Memory operations
  | 'memory.search'
  | 'memory.addEntry'
  | 'memory.getHandoffs'
  // Skill operations
  | 'skill.list'
  | 'skill.get'
  | 'skill.refresh'
  // Filesystem operations
  | 'filesystem.listDir'
  | 'filesystem.getHome'
  | 'filesystem.createDir'
  // Search
  | 'search.content'
  | 'search.events'
  // System
  | 'system.ping'
  | 'system.getInfo'
  | 'system.shutdown'
  // Transcription
  | 'transcribe.audio'
  | 'transcribe.listModels'
  // Context management
  | 'context.getSnapshot'
  | 'context.getDetailedSnapshot'
  | 'context.shouldCompact'
  | 'context.previewCompaction'
  | 'context.confirmCompaction'
  | 'context.canAcceptTurn'
  | 'context.clear'
  // Voice Notes
  | 'voiceNotes.save'
  | 'voiceNotes.list'
  | 'voiceNotes.delete'
  // Message operations
  | 'message.delete'
  // Browser automation
  | 'browser.startStream'
  | 'browser.stopStream'
  | 'browser.getStatus';

// =============================================================================
// Session Methods
// =============================================================================

/** Create new session */
export interface SessionCreateParams {
  /** Working directory for the session */
  workingDirectory: string;
  /** Model to use (optional, defaults to config) */
  model?: string;
  /** Initial context files to load */
  contextFiles?: string[];
}

export interface SessionCreateResult {
  sessionId: string;
  model: string;
  createdAt: string;
}

/** Resume existing session */
export interface SessionResumeParams {
  /** Session ID to resume */
  sessionId: string;
}

export interface SessionResumeResult {
  sessionId: string;
  model: string;
  messageCount: number;
  lastActivity: string;
}

/** List sessions */
export interface SessionListParams {
  /** Filter by working directory */
  workingDirectory?: string;
  /** Max sessions to return */
  limit?: number;
  /** Include ended sessions */
  includeEnded?: boolean;
}

export interface SessionListResult {
  sessions: Array<{
    sessionId: string;
    workingDirectory: string;
    model: string;
    messageCount: number;
    inputTokens: number;
    outputTokens: number;
    cost: number;
    createdAt: string;
    lastActivity: string;
    isActive: boolean;
  }>;
}

/** Delete session */
export interface SessionDeleteParams {
  sessionId: string;
}

export interface SessionDeleteResult {
  deleted: boolean;
}

/** Fork session from specific event */
export interface SessionForkParams {
  sessionId: string;
  /** Event ID to fork from (uses session head if not specified) */
  fromEventId?: string;
  /** Name for the forked session */
  name?: string;
  /** Model for the forked session (inherits from source if not specified) */
  model?: string;
}

export interface SessionForkResult {
  newSessionId: string;
  rootEventId: string;
  forkedFromEventId: string;
  forkedFromSessionId: string;
}

/** Rewind session to specific event */
export interface SessionRewindParams {
  sessionId: string;
  /** Event ID to rewind to (must be ancestor of current head) */
  toEventId: string;
}

export interface SessionRewindResult {
  sessionId: string;
  newHeadEventId: string;
  previousHeadEventId: string;
}

/** Get session head event */
export interface SessionGetHeadParams {
  sessionId: string;
}

export interface SessionGetHeadResult {
  sessionId: string;
  headEventId: string;
  headEvent: SessionEvent;
}

/** Get full session state at head */
export interface SessionGetStateParams {
  sessionId: string;
  /** Optional: get state at specific event (defaults to head) */
  atEventId?: string;
}

export interface SessionGetStateResult {
  sessionId: string;
  workspaceId: string;
  headEventId: string;
  model: string;
  workingDirectory: string;
  messages: Message[];
  tokenUsage: TokenUsage;
  turnCount: number;
  eventCount: number;
}

// =============================================================================
// Agent Methods
// =============================================================================

/**
 * File attachment from client (iOS app or web)
 * Supports images (JPEG, PNG, GIF, WebP) and documents (PDF)
 */
export interface FileAttachment {
  /** Base64 encoded file data */
  data: string;
  /** MIME type (e.g., "image/jpeg", "application/pdf") */
  mimeType: string;
  /** Optional original filename */
  fileName?: string;
}

/** Send prompt to agent */
export interface AgentPromptParams {
  /** Session to send to */
  sessionId: string;
  /** User message */
  prompt: string;
  /** Optional image attachments (base64) - legacy, use attachments instead */
  images?: FileAttachment[];
  /** Optional file attachments (images and PDFs) */
  attachments?: FileAttachment[];
  /** Reasoning effort level for OpenAI Codex models (low/medium/high/xhigh) */
  reasoningLevel?: 'low' | 'medium' | 'high' | 'xhigh';
}

export interface AgentPromptResult {
  /** Response will be streamed via events */
  acknowledged: boolean;
}

/** Abort current agent run */
export interface AgentAbortParams {
  sessionId: string;
}

export interface AgentAbortResult {
  aborted: boolean;
}

/** Get agent state */
export interface AgentGetStateParams {
  sessionId: string;
}

/** Tool call info for in-progress turn */
export interface CurrentTurnToolCall {
  toolCallId: string;
  toolName: string;
  arguments: Record<string, unknown>;
  status: 'pending' | 'running' | 'completed' | 'error';
  result?: string;
  isError?: boolean;
  startedAt: string;
  completedAt?: string;
}

export interface AgentGetStateResult {
  isRunning: boolean;
  currentTurn: number;
  messageCount: number;
  tokenUsage: {
    input: number;
    output: number;
  };
  model: string;
  tools: string[];
  /** Accumulated text from current in-progress turn (for resume) */
  currentTurnText?: string;
  /** Tool calls from current in-progress turn (for resume) */
  currentTurnToolCalls?: CurrentTurnToolCall[];
}

// =============================================================================
// Model Methods
// =============================================================================

/** Switch model */
export interface ModelSwitchParams {
  sessionId: string;
  model: string;
}

export interface ModelSwitchResult {
  previousModel: string;
  newModel: string;
}

/** List available models */
export interface ModelListParams {
  /** Filter by provider (anthropic, openai, google, openai-codex) */
  provider?: string;
}

export interface ModelListResult {
  models: Array<{
    id: string;
    name: string;
    provider: string;
    contextWindow: number;
    supportsThinking: boolean;
    supportsImages: boolean;
    /** Model tier: opus, sonnet, haiku, flagship, mini, standard */
    tier?: string;
    /** Whether this is a legacy/deprecated model */
    isLegacy?: boolean;
    /** For models with reasoning capability (e.g., OpenAI Codex) */
    supportsReasoning?: boolean;
    /** Available reasoning effort levels (low, medium, high, xhigh) */
    reasoningLevels?: string[];
    /** Default reasoning level */
    defaultReasoningLevel?: string;
  }>;
}

// =============================================================================
// Memory Methods
// =============================================================================

/** Search memory */
export interface MemorySearchParams {
  searchText?: string;
  type?: 'pattern' | 'decision' | 'preference' | 'lesson' | 'error';
  source?: 'immediate' | 'session' | 'project' | 'global';
  limit?: number;
}

export interface RpcMemorySearchResult {
  entries: Array<{
    id: string;
    type: string;
    content: string;
    source: string;
    relevance: number;
    timestamp: string;
  }>;
  totalCount: number;
}

/** Alias for backward compatibility */
export type MemorySearchResultRpc = RpcMemorySearchResult;

/** Add memory entry */
export interface MemoryAddEntryParams {
  type: 'pattern' | 'decision' | 'preference' | 'lesson' | 'error';
  content: string;
  source?: 'project' | 'global';
  metadata?: Record<string, unknown>;
}

export interface MemoryAddEntryResult {
  id: string;
  created: boolean;
}

/** Get handoffs */
export interface MemoryGetHandoffsParams {
  workingDirectory?: string;
  limit?: number;
}

export interface MemoryGetHandoffsResult {
  handoffs: Array<{
    id: string;
    sessionId: string;
    summary: string;
    createdAt: string;
  }>;
}

// =============================================================================
// Skill Methods
// =============================================================================

/**
 * Skill info returned in list operations
 */
export interface RpcSkillInfo {
  /** Skill name (folder name, used as @reference) */
  name: string;
  /** Short description (first non-header line of SKILL.md) */
  description: string;
  /** Where the skill was loaded from */
  source: 'global' | 'project';
  /** Whether this skill auto-injects into every prompt (Rules) */
  autoInject: boolean;
  /** Tags for categorization */
  tags?: string[];
}

/**
 * Full skill metadata with content
 */
export interface RpcSkillMetadata extends RpcSkillInfo {
  /** Full SKILL.md content (after frontmatter stripped) */
  content: string;
  /** Absolute path to skill folder */
  path: string;
  /** List of additional files in the skill folder */
  additionalFiles: string[];
}

/** List available skills */
export interface SkillListParams {
  /** Session ID to get working directory for project skills */
  sessionId?: string;
  /** Filter by source (global, project) */
  source?: 'global' | 'project';
  /** Filter for auto-inject skills only */
  autoInjectOnly?: boolean;
  /** Include full content in results */
  includeContent?: boolean;
}

export interface SkillListResult {
  /** List of skills (with or without content based on includeContent param) */
  skills: RpcSkillInfo[] | RpcSkillMetadata[];
  /** Total number of skills */
  totalCount: number;
  /** Number of auto-inject skills (Rules) */
  autoInjectCount: number;
}

/** Get a single skill by name */
export interface SkillGetParams {
  /** Session ID to get working directory for project skills */
  sessionId?: string;
  /** Skill name */
  name: string;
}

export interface SkillGetResult {
  /** Skill metadata with full content */
  skill: RpcSkillMetadata | null;
  /** Whether the skill was found */
  found: boolean;
}

/** Refresh skills cache */
export interface SkillRefreshParams {
  /** Session ID to get working directory for project skills */
  sessionId?: string;
}

export interface SkillRefreshResult {
  /** Whether the refresh was successful */
  success: boolean;
  /** Number of skills loaded after refresh */
  skillCount: number;
}

// =============================================================================
// Event Methods
// =============================================================================

/** Get event history for a session */
export interface EventsGetHistoryParams {
  sessionId: string;
  /** Filter by event types */
  types?: EventType[];
  /** Limit number of events returned */
  limit?: number;
  /** Include events from before this event ID */
  beforeEventId?: string;
}

export interface EventsGetHistoryResult {
  events: SessionEvent[];
  hasMore: boolean;
  oldestEventId?: string;
}

/** Get events since a cursor (for sync) */
export interface EventsGetSinceParams {
  /** Session to get events from */
  sessionId?: string;
  /** Workspace to get events from (all sessions in workspace) */
  workspaceId?: string;
  /** Get events after this event ID (cursor) */
  afterEventId?: string;
  /** Get events after this timestamp */
  afterTimestamp?: string;
  /** Limit number of events */
  limit?: number;
}

export interface EventsGetSinceResult {
  events: SessionEvent[];
  /** Cursor for next request */
  nextCursor?: string;
  /** Whether more events are available */
  hasMore: boolean;
}

/** Subscribe to event stream */
export interface EventsSubscribeParams {
  /** Session IDs to subscribe to */
  sessionIds?: string[];
  /** Workspace ID to subscribe to (all sessions) */
  workspaceId?: string;
  /** Event types to filter */
  types?: EventType[];
}

export interface EventsSubscribeResult {
  subscriptionId: string;
  subscribed: boolean;
}

/** Unsubscribe from event stream */
export interface EventsUnsubscribeParams {
  subscriptionId: string;
}

export interface EventsUnsubscribeResult {
  unsubscribed: boolean;
}

/** Append a new event (for client-side event creation) */
export interface EventsAppendParams {
  sessionId: string;
  type: EventType;
  payload: Record<string, unknown>;
  /** Parent event ID (defaults to session head) */
  parentId?: string;
}

export interface EventsAppendResult {
  event: SessionEvent;
  newHeadEventId: string;
}

// =============================================================================
// Tree Methods
// =============================================================================

/** Tree node for visualization */
export interface TreeNodeCompact {
  id: string;
  parentId: string | null;
  type: EventType;
  timestamp: string;
  /** Summary of event content (first 100 chars) */
  summary: string;
  hasChildren: boolean;
  childCount: number;
  depth: number;
  isBranchPoint: boolean;
  isHead: boolean;
  /** Branch name if this is a fork point */
  branchName?: string;
}

/** Get tree visualization for a session */
export interface TreeGetVisualizationParams {
  sessionId: string;
  /** Max depth to fetch (for lazy loading) */
  maxDepth?: number;
  /** Only include message events for compact view */
  messagesOnly?: boolean;
}

export interface TreeGetVisualizationResult {
  sessionId: string;
  rootEventId: string;
  headEventId: string;
  nodes: TreeNodeCompact[];
  /** Total event count in session */
  totalEvents: number;
}

/** Get branches for a session */
export interface TreeGetBranchesParams {
  sessionId: string;
}

export interface TreeBranchInfo {
  sessionId: string;
  name?: string;
  forkEventId: string;
  headEventId: string;
  messageCount: number;
  createdAt: string;
  lastActivity: string;
}

export interface TreeGetBranchesResult {
  /** Original session */
  mainBranch: TreeBranchInfo;
  /** Forked sessions */
  forks: TreeBranchInfo[];
}

/** Get subtree starting from an event */
export interface TreeGetSubtreeParams {
  eventId: string;
  /** Max depth to fetch */
  maxDepth?: number;
  /** Direction: 'descendants' (default) or 'ancestors' */
  direction?: 'descendants' | 'ancestors';
}

export interface TreeGetSubtreeResult {
  rootEventId: string;
  nodes: TreeNodeCompact[];
  hasMore: boolean;
}

/** Get ancestors of an event */
export interface TreeGetAncestorsParams {
  eventId: string;
  /** Limit number of ancestors */
  limit?: number;
}

export interface TreeGetAncestorsResult {
  ancestors: SessionEvent[];
  /** The event requested */
  targetEvent: SessionEvent;
}

/** Compare two branches */
export interface TreeCompareBranchesParams {
  /** First session/branch */
  sessionId1: string;
  /** Second session/branch */
  sessionId2: string;
}

export interface TreeCompareBranchesResult {
  /** Common ancestor event */
  commonAncestorEventId: string | null;
  /** Events unique to first branch */
  uniqueToFirst: number;
  /** Events unique to second branch */
  uniqueToSecond: number;
  /** Shared events (before divergence) */
  sharedEvents: number;
  /** Divergence point event */
  divergenceEventId: string | null;
}

// =============================================================================
// Search Methods
// =============================================================================

/** Search content across events */
export interface SearchContentParams {
  /** Search query (FTS5 syntax supported) */
  query: string;
  /** Limit to specific workspace */
  workspaceId?: string;
  /** Limit to specific session */
  sessionId?: string;
  /** Filter by event types */
  types?: EventType[];
  /** Max results */
  limit?: number;
}

export interface SearchContentResult {
  results: Array<{
    eventId: string;
    sessionId: string;
    workspaceId: string;
    type: EventType;
    /** Highlighted snippet with matches */
    snippet: string;
    /** Relevance score */
    score: number;
    timestamp: string;
  }>;
  totalCount: number;
}

/** Search events by structured criteria */
export interface SearchEventsParams {
  /** Filter by workspace */
  workspaceId?: string;
  /** Filter by session */
  sessionId?: string;
  /** Filter by event types */
  types?: EventType[];
  /** Filter by time range - start */
  afterTimestamp?: string;
  /** Filter by time range - end */
  beforeTimestamp?: string;
  /** Text search within event content */
  contentQuery?: string;
  /** Limit results */
  limit?: number;
  /** Offset for pagination */
  offset?: number;
}

export interface SearchEventsResult {
  events: SessionEvent[];
  totalCount: number;
  hasMore: boolean;
}

// =============================================================================
// System Methods
// =============================================================================

/** Ping */
export interface SystemPingParams {}

export interface SystemPingResult {
  pong: true;
  timestamp: string;
}

/** Get system info */
export interface SystemGetInfoParams {}

export interface SystemGetInfoResult {
  version: string;
  uptime: number;
  activeSessions: number;
  memoryUsage: {
    heapUsed: number;
    heapTotal: number;
  };
}

/** Shutdown */
export interface SystemShutdownParams {
  /** Grace period in ms before force shutdown */
  gracePeriod?: number;
}

export interface SystemShutdownResult {
  acknowledged: boolean;
}

// =============================================================================
// Transcription Methods
// =============================================================================

export interface TranscribeAudioParams {
  /** Optional session ID for attribution */
  sessionId?: string;
  /** Base64-encoded audio bytes */
  audioBase64: string;
  /** MIME type for the audio (e.g., audio/m4a) */
  mimeType?: string;
  /** Original filename (optional) */
  fileName?: string;
  /** Preferred transcription model ID (server-defined) */
  transcriptionModelId?: string;
  /** Client-selected transcription quality profile */
  transcriptionQuality?: 'faster' | 'better';
  /** Cleanup mode override */
  cleanupMode?: 'none' | 'basic' | 'llm';
  /** Language hint (optional, e.g., "en") */
  language?: string;
  /** Initial prompt for transcription (optional) */
  prompt?: string;
  /** Task type (transcribe/translate) */
  task?: 'transcribe' | 'translate';
}

export interface TranscribeAudioResult {
  text: string;
  rawText: string;
  language: string;
  durationSeconds: number;
  processingTimeMs: number;
  model: string;
  device: string;
  computeType: string;
  cleanupMode: string;
}

export interface TranscriptionModelInfo {
  id: string;
  label: string;
  description?: string;
}

export interface TranscribeListModelsParams {}

export interface TranscribeListModelsResult {
  models: TranscriptionModelInfo[];
  defaultModelId?: string;
}

// =============================================================================
// Filesystem Methods
// =============================================================================

/** List directory contents */
export interface FilesystemListDirParams {
  /** Path to list (defaults to home directory if not specified) */
  path?: string;
  /** Include hidden files (starting with .) */
  showHidden?: boolean;
}

export interface FilesystemListDirResult {
  /** Current directory path (absolute) */
  path: string;
  /** Parent directory path (null if at root) */
  parent: string | null;
  /** Directory entries */
  entries: Array<{
    /** Entry name */
    name: string;
    /** Full path */
    path: string;
    /** Whether this is a directory */
    isDirectory: boolean;
    /** Whether this is a symbolic link */
    isSymlink?: boolean;
    /** File size in bytes (files only) */
    size?: number;
    /** Last modified timestamp */
    modifiedAt?: string;
  }>;
}

/** Get home directory */
export interface FilesystemGetHomeParams {}

export interface FilesystemGetHomeResult {
  /** User's home directory path */
  homePath: string;
  /** Common project directories */
  suggestedPaths: Array<{
    name: string;
    path: string;
    exists: boolean;
  }>;
}

/** Create directory */
export interface FilesystemCreateDirParams {
  /** Path of the directory to create */
  path: string;
  /** Whether to create parent directories if they don't exist (default: false) */
  recursive?: boolean;
}

export interface FilesystemCreateDirResult {
  /** Whether the directory was created successfully */
  created: boolean;
  /** The absolute path of the created directory */
  path: string;
}

// =============================================================================
// Event Types
// =============================================================================

/**
 * All event types that can be sent from server to client
 */
export type RpcEventType =
  // Agent events
  | 'agent.turn_start'
  | 'agent.turn_end'
  | 'agent.text_delta'
  | 'agent.thinking_delta'
  | 'agent.tool_start'
  | 'agent.tool_end'
  | 'agent.error'
  | 'agent.complete'
  // Session events
  | 'session.created'
  | 'session.ended'
  | 'session.updated'
  | 'session.forked'
  | 'session.rewound'
  // Event sync events (for real-time event broadcasting)
  | 'events.new'
  | 'events.batch'
  // Tree events
  | 'tree.updated'
  | 'tree.branch_created'
  // System events
  | 'system.connected'
  | 'system.disconnected'
  | 'system.error'
  // Browser events
  | 'browser.frame';

/**
 * Event data for agent text streaming
 */
export interface AgentTextDeltaEvent {
  delta: string;
  accumulated?: string;
}

/**
 * Event data for agent thinking streaming
 */
export interface AgentThinkingDeltaEvent {
  delta: string;
}

/**
 * Event data for tool start
 */
export interface AgentToolStartEvent {
  toolCallId: string;
  toolName: string;
  arguments: Record<string, unknown>;
}

/**
 * Event data for tool end
 */
export interface AgentToolEndEvent {
  toolCallId: string;
  toolName: string;
  duration: number;
  success: boolean;
  output?: string;
  error?: string;
}

/**
 * Event data for agent completion
 */
export interface AgentCompleteEvent {
  turns: number;
  tokenUsage: {
    input: number;
    output: number;
  };
  success: boolean;
  error?: string;
}

/**
 * Event data for session fork notification
 */
export interface SessionForkedEvent {
  sourceSessionId: string;
  sourceEventId: string;
  newSessionId: string;
  newRootEventId: string;
  name?: string;
}

/**
 * Event data for session rewind notification
 */
export interface SessionRewoundEvent {
  sessionId: string;
  previousHeadEventId: string;
  newHeadEventId: string;
}

/**
 * Event data for new session event broadcast
 */
export interface EventsNewEvent {
  event: SessionEvent;
  sessionId: string;
}

/**
 * Event data for batch event broadcast
 */
export interface EventsBatchEvent {
  events: SessionEvent[];
  sessionId: string;
  syncCursor: string;
}

/**
 * Event data for tree structure update
 */
export interface TreeUpdatedEvent {
  sessionId: string;
  headEventId: string;
  affectedEventIds: string[];
}

/**
 * Event data for branch creation
 */
export interface TreeBranchCreatedEvent {
  sourceSessionId: string;
  newSessionId: string;
  forkEventId: string;
  branchName?: string;
}

// =============================================================================
// Worktree Methods
// =============================================================================

/**
 * Worktree information returned by worktree operations
 */
export interface WorktreeInfoRpc {
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

/** Get worktree status for a session */
export interface WorktreeGetStatusParams {
  sessionId: string;
}

export interface WorktreeGetStatusResult {
  /** Session has a worktree */
  hasWorktree: boolean;
  /** Worktree info if available */
  worktree?: WorktreeInfoRpc;
}

/** Commit changes in a session's worktree */
export interface WorktreeCommitParams {
  sessionId: string;
  /** Commit message */
  message: string;
}

export interface WorktreeCommitResult {
  success: boolean;
  /** Commit hash if successful */
  commitHash?: string;
  /** Files that were changed */
  filesChanged?: string[];
  /** Error message if failed */
  error?: string;
}

/** Merge a session's worktree to a target branch */
export interface WorktreeMergeParams {
  sessionId: string;
  /** Target branch to merge into */
  targetBranch: string;
  /** Merge strategy */
  strategy?: 'merge' | 'rebase' | 'squash';
}

export interface WorktreeMergeResult {
  success: boolean;
  /** Merge commit hash if successful */
  mergeCommit?: string;
  /** Conflicting files if merge failed due to conflicts */
  conflicts?: string[];
  /** Error message if failed */
  error?: string;
}

/** List all worktrees */
export interface WorktreeListParams {}

export interface WorktreeListResult {
  worktrees: Array<{
    path: string;
    branch: string;
    sessionId?: string;
  }>;
}

// =============================================================================
// Context Methods
// =============================================================================

/** Get context snapshot for a session */
export interface ContextGetSnapshotParams {
  sessionId: string;
}

export interface ContextGetSnapshotResult {
  currentTokens: number;
  contextLimit: number;
  usagePercent: number;
  thresholdLevel: 'normal' | 'warning' | 'alert' | 'critical' | 'exceeded';
  breakdown: {
    systemPrompt: number;
    tools: number;
    messages: number;
  };
}

/** Get detailed context snapshot with per-message token breakdown */
export interface ContextGetDetailedSnapshotParams {
  sessionId: string;
}

export interface ContextDetailedMessageInfo {
  index: number;
  role: 'user' | 'assistant' | 'toolResult';
  tokens: number;
  summary: string;
  content: string;
  toolCalls?: Array<{
    id: string;
    name: string;
    tokens: number;
    arguments: string;
  }>;
  toolCallId?: string;
  isError?: boolean;
}

export interface ContextGetDetailedSnapshotResult extends ContextGetSnapshotResult {
  messages: ContextDetailedMessageInfo[];
  systemPromptContent: string;
  toolsContent: string[];
}

/** Check if compaction is needed */
export interface ContextShouldCompactParams {
  sessionId: string;
}

export interface ContextShouldCompactResult {
  shouldCompact: boolean;
}

/** Preview compaction without executing */
export interface ContextPreviewCompactionParams {
  sessionId: string;
}

export interface ContextPreviewCompactionResult {
  tokensBefore: number;
  tokensAfter: number;
  compressionRatio: number;
  preservedTurns: number;
  summarizedTurns: number;
  summary: string;
}

/** Confirm and execute compaction */
export interface ContextConfirmCompactionParams {
  sessionId: string;
  /** Optional user-edited summary to use instead of generated one */
  editedSummary?: string;
}

export interface ContextConfirmCompactionResult {
  success: boolean;
  tokensBefore: number;
  tokensAfter: number;
  compressionRatio: number;
  summary: string;
}

/** Pre-turn validation to check if turn can proceed */
export interface ContextCanAcceptTurnParams {
  sessionId: string;
  estimatedResponseTokens: number;
}

export interface ContextCanAcceptTurnResult {
  canProceed: boolean;
  needsCompaction: boolean;
  wouldExceedLimit: boolean;
  currentTokens: number;
  estimatedAfterTurn: number;
  contextLimit: number;
}

/** Clear all messages from context */
export interface ContextClearParams {
  sessionId: string;
}

export interface ContextClearResult {
  success: boolean;
  tokensBefore: number;
  tokensAfter: number;
}

// =============================================================================
// Voice Notes Methods
// =============================================================================

/** Save a voice note with transcription */
export interface VoiceNotesSaveParams {
  /** Base64-encoded audio bytes */
  audioBase64: string;
  /** MIME type for the audio (e.g., audio/m4a) */
  mimeType?: string;
  /** Original filename (optional) */
  fileName?: string;
  /** Preferred transcription model ID */
  transcriptionModelId?: string;
}

export interface VoiceNotesSaveResult {
  success: boolean;
  /** Generated filename */
  filename: string;
  /** Full path to saved file */
  filepath: string;
  /** Transcription details */
  transcription: {
    text: string;
    language: string;
    durationSeconds: number;
  };
}

/** List saved voice notes */
export interface VoiceNotesListParams {
  /** Maximum number of notes to return */
  limit?: number;
  /** Offset for pagination */
  offset?: number;
}

export interface VoiceNoteMetadata {
  /** Filename (e.g., "2025-01-09-143022-voice-note.md") */
  filename: string;
  /** Full path to file */
  filepath: string;
  /** ISO timestamp when created */
  createdAt: string;
  /** Duration in seconds */
  durationSeconds?: number;
  /** Detected language */
  language?: string;
  /** First line or summary of transcription */
  preview: string;
}

export interface VoiceNotesListResult {
  notes: VoiceNoteMetadata[];
  totalCount: number;
  hasMore: boolean;
}

/** Delete a voice note file */
export interface VoiceNotesDeleteParams {
  /** Filename of the note to delete (e.g., "voice-note-2024-01-15-143022.md") */
  filename: string;
}

export interface VoiceNotesDeleteResult {
  /** Whether the deletion was successful */
  success: boolean;
  /** The filename that was deleted */
  filename: string;
}

// =============================================================================
// Message Methods
// =============================================================================

/** Delete a message from a session */
export interface MessageDeleteParams {
  /** Session ID containing the message */
  sessionId: string;
  /** Event ID of the message to delete (must be message.user or message.assistant) */
  targetEventId: string;
  /** Reason for deletion (optional) */
  reason?: 'user_request' | 'content_policy' | 'context_management';
}

export interface MessageDeleteResult {
  /** Whether the deletion was successful */
  success: boolean;
  /** The event ID of the message.deleted event */
  deletionEventId: string;
  /** Type of event that was deleted */
  targetType: 'message.user' | 'message.assistant' | 'tool.result';
}

// =============================================================================
// Browser Methods
// =============================================================================

/** Start browser stream for a session */
export interface BrowserStartStreamParams {
  /** Session ID that has an active browser */
  sessionId: string;
  /** Stream quality (JPEG quality 1-100, default: 60) */
  quality?: number;
  /** Maximum frame width (default: 1280) */
  maxWidth?: number;
  /** Maximum frame height (default: 800) */
  maxHeight?: number;
  /** Stream format (default: 'jpeg') */
  format?: 'jpeg' | 'png';
  /** Frame rate control - emit every Nth frame (default: 1) */
  everyNthFrame?: number;
}

export interface BrowserStartStreamResult {
  /** Whether streaming started successfully */
  success: boolean;
  /** Error message if failed */
  error?: string;
}

/** Stop browser stream for a session */
export interface BrowserStopStreamParams {
  /** Session ID to stop streaming for */
  sessionId: string;
}

export interface BrowserStopStreamResult {
  /** Whether streaming stopped successfully */
  success: boolean;
  /** Error message if failed */
  error?: string;
}

/** Get browser status for a session */
export interface BrowserGetStatusParams {
  /** Session ID to check */
  sessionId: string;
}

export interface BrowserGetStatusResult {
  /** Whether the session has an active browser */
  hasBrowser: boolean;
  /** Whether the browser is currently streaming frames */
  isStreaming: boolean;
  /** Current URL if browser is active */
  currentUrl?: string;
}

/**
 * Event data for browser frame streaming
 * Sent from server to client when browser frames are captured
 */
export interface BrowserFrameEvent {
  /** Session ID the frame belongs to */
  sessionId: string;
  /** Base64-encoded frame data (JPEG or PNG) */
  data: string;
  /** Frame sequence number (from CDP sessionId) */
  frameId: number;
  /** Timestamp when frame was captured */
  timestamp: number;
  /** Optional frame metadata from CDP */
  metadata?: {
    /** Offset from top of viewport */
    offsetTop?: number;
    /** Page scale factor */
    pageScaleFactor?: number;
    /** Device width */
    deviceWidth?: number;
    /** Device height */
    deviceHeight?: number;
    /** Horizontal scroll offset */
    scrollOffsetX?: number;
    /** Vertical scroll offset */
    scrollOffsetY?: number;
  };
}

// =============================================================================
// Type Guards
// =============================================================================

export function isRpcRequest(msg: unknown): msg is RpcRequest {
  return (
    typeof msg === 'object' &&
    msg !== null &&
    'id' in msg &&
    'method' in msg &&
    typeof (msg as RpcRequest).id === 'string' &&
    typeof (msg as RpcRequest).method === 'string'
  );
}

export function isRpcResponse(msg: unknown): msg is RpcResponse {
  return (
    typeof msg === 'object' &&
    msg !== null &&
    'id' in msg &&
    'success' in msg &&
    typeof (msg as RpcResponse).id === 'string' &&
    typeof (msg as RpcResponse).success === 'boolean'
  );
}

export function isRpcEvent(msg: unknown): msg is RpcEvent {
  return (
    typeof msg === 'object' &&
    msg !== null &&
    'type' in msg &&
    'timestamp' in msg &&
    'data' in msg &&
    typeof (msg as RpcEvent).type === 'string'
  );
}
