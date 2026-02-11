/**
 * @fileoverview Base Event Structure
 *
 * Core event types and base event interface.
 */

import type { EventId, SessionId, WorkspaceId } from './branded.js';

// =============================================================================
// Event Type Discriminator
// =============================================================================

export type EventType =
  // Session lifecycle
  | 'session.start'
  | 'session.end'
  | 'session.fork'
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
  | 'config.reasoning_level'
  // Message operations
  | 'message.deleted'
  // Notifications (in-chat pill notifications)
  | 'notification.interrupted'
  | 'notification.subagent_result'
  // Compaction/summarization
  | 'compact.boundary'
  | 'compact.summary'
  // Context clearing
  | 'context.cleared'
  // Skill tracking
  | 'skill.added'
  | 'skill.removed'
  // Rules tracking
  | 'rules.loaded'
  | 'rules.indexed'
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
  | 'error.provider'
  // Subagent events
  | 'subagent.spawned'
  | 'subagent.status_update'
  | 'subagent.completed'
  | 'subagent.failed'
  // Todo tracking (legacy, kept for event reconstruction)
  | 'todo.write'
  // Task management (broadcast only, not sourced)
  | 'task.created'
  | 'task.updated'
  | 'task.deleted'
  | 'project.updated'
  // Turn events
  | 'turn.failed'
  // Hook events
  | 'hook.triggered'
  | 'hook.completed'
  | 'hook.background_started'
  | 'hook.background_completed'
  // Memory events
  | 'memory.ledger'
  | 'memory.loaded';

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
