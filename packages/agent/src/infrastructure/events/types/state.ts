/**
 * @fileoverview Session State and Related Types
 *
 * Types for session state reconstruction, messages, and queries.
 */

import type { EventId, SessionId, WorkspaceId, BranchId } from './branded.js';
import type { EventType } from './base.js';
import type { ContentBlock } from './message.js';
import type { TokenUsage } from './token-usage.js';
import type { SessionEvent } from './union.js';

// =============================================================================
// Event Creation Helpers
// =============================================================================

export type CreateEventInput<T extends SessionEvent> = Omit<T, 'id' | 'timestamp' | 'sequence' | 'checksum'>;

// =============================================================================
// Message Type (for API compatibility)
// =============================================================================

/** Message format for API calls */
export interface Message {
  role: 'user' | 'assistant' | 'system' | 'toolResult';
  content: string | ContentBlock[];
  /** For toolResult messages: the ID of the tool call this result corresponds to */
  toolCallId?: string;
  /** For toolResult messages: whether the result is an error */
  isError?: boolean;
}

/**
 * Message paired with its associated event IDs.
 *
 * Consolidates the parallel arrays pattern where messages[] and messageEventIds[]
 * had to stay in sync. A message can have multiple eventIds when consecutive
 * messages of the same role are merged (for proper deletion tracking).
 *
 * The eventIds array may be empty for:
 * - Synthetic messages (tool results, compaction summaries)
 * - Messages created during the current session (not yet persisted)
 */
export interface MessageWithEventId {
  message: Message;
  /** Event IDs associated with this message. Multiple IDs when messages are merged. */
  eventIds: (string | undefined)[];
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
  /** Messages with their associated event IDs (unified, no parallel arrays) */
  messagesWithEventIds: MessageWithEventId[];
  /** Total token usage */
  tokenUsage: TokenUsage;
  /** Turn count */
  turnCount: number;
  /** Current provider */
  provider?: string;
  /** System prompt */
  systemPrompt?: string;
  /** Current reasoning level (for extended thinking models) */
  reasoningLevel?: 'low' | 'medium' | 'high' | 'xhigh';
  /** Current turn number (deprecated, use turnCount) */
  currentTurn?: number;
  /** Session metadata */
  metadata?: SessionMetadata;
  /** Active files being worked on */
  activeFiles?: string[];
  /** Whether session is archived (derived from archived_at) */
  isArchived?: boolean;
  /** Branch information */
  branch?: {
    id: BranchId;
    name: string;
  };
  /** Timestamp of this state */
  timestamp?: string;
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
  /** Whether session is archived (derived from archived_at IS NOT NULL) */
  isArchived: boolean;
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
