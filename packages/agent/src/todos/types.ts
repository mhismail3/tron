/**
 * @fileoverview Todo Management Types
 *
 * Core types for the todo/task tracking system.
 * Supports agent, user, and skill-created tasks with event-sourced persistence.
 */

// =============================================================================
// Todo Status and Source
// =============================================================================

/** Status of a todo item */
export type TodoStatus = 'pending' | 'in_progress' | 'completed';

/** Source that created the todo */
export type TodoSource = 'agent' | 'user' | 'skill';

// =============================================================================
// TodoItem Interface
// =============================================================================

/**
 * A single todo item in the task list.
 * Immutable once created - updates create new events with full state.
 */
export interface TodoItem {
  /** Unique identifier (e.g., "todo_abc123") */
  id: string;

  /** Task description - imperative form ("Fix the bug") */
  content: string;

  /** Present continuous form for display ("Fixing the bug") */
  activeForm: string;

  /** Current status */
  status: TodoStatus;

  /** Where this task originated */
  source: TodoSource;

  /** ISO timestamp when created */
  createdAt: string;

  /** ISO timestamp when completed (if completed) */
  completedAt?: string;

  /** Extensible metadata */
  metadata?: TodoMetadata;
}

/**
 * Extensible metadata for todo items.
 * Allows future enhancements without schema changes.
 */
export interface TodoMetadata {
  /** Task priority */
  priority?: 'low' | 'medium' | 'high';

  /** Tags for categorization */
  tags?: string[];

  /** Skill name if source is 'skill' */
  skillName?: string;

  /** Parent task ID for subtasks (future enhancement) */
  parentTaskId?: string;

  /** If restored from backlog, the original task ID */
  restoredFrom?: string;

  /** Original creation date if restored from backlog */
  originalCreatedAt?: string;

  /** Allow additional properties */
  [key: string]: unknown;
}

// =============================================================================
// BackloggedTask Interface
// =============================================================================

/** Reason a task was moved to backlog */
export type BacklogReason = 'session_clear' | 'context_compact' | 'session_end';

/**
 * A task that has been moved to the backlog.
 * Extends TodoItem with backlog-specific metadata.
 */
export interface BackloggedTask extends TodoItem {
  /** When moved to backlog */
  backloggedAt: string;

  /** Why it was backlogged */
  backlogReason: BacklogReason;

  /** Session it came from */
  sourceSessionId: string;

  /** Workspace for scoping */
  workspaceId: string;

  /** Session ID if restored */
  restoredToSessionId?: string;

  /** When restored */
  restoredAt?: string;
}

// =============================================================================
// Event Payloads
// =============================================================================

/**
 * Payload for todo.write event.
 * Uses snapshot approach - stores complete todo list state.
 */
export interface TodoWritePayload {
  /** Complete current todo list */
  todos: TodoItem[];

  /** What triggered this write */
  trigger: 'tool' | 'command' | 'skill' | 'restore';
}

// =============================================================================
// Tracking Types
// =============================================================================

/**
 * Event type for TodoTracker reconstruction.
 * Union of event types that affect todo state.
 */
export interface TodoTrackingEvent {
  id: string;
  type: string;
  payload: unknown;
}
