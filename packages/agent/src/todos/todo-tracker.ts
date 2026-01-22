/**
 * @fileoverview Todo Tracker
 *
 * In-memory session-scoped task state management.
 * Supports event-sourced reconstruction for session resume/fork.
 */

import type { TodoItem, TodoStatus, TodoSource, TodoTrackingEvent } from './types.js';

/**
 * TodoTracker manages the current session's todo list state.
 *
 * Key responsibilities:
 * - Track current session's todos in memory
 * - Reconstruct from events on resume/fork
 * - Build context strings for prompt injection
 * - Handle context clear -> backlog flow
 *
 * Design notes:
 * - Uses snapshot-based events (todo.write stores full list)
 * - Clears on context.cleared and compact.boundary
 * - State is purely derived from events, never persisted directly
 */
export class TodoTracker {
  private todos: Map<string, TodoItem> = new Map();
  private lastEventId?: string;

  // ===========================================================================
  // Mutations
  // ===========================================================================

  /**
   * Replace the entire todo list (from todo.write event).
   * This is the primary mutation method - all writes are full snapshots.
   */
  setTodos(todos: TodoItem[], eventId: string): void {
    this.todos.clear();
    for (const todo of todos) {
      this.todos.set(todo.id, todo);
    }
    this.lastEventId = eventId;
  }

  /**
   * Add a single todo item (for programmatic additions).
   * Prefer using setTodos with full snapshots for tool calls.
   */
  addTodo(todo: TodoItem): void {
    this.todos.set(todo.id, todo);
  }

  /**
   * Update a todo item by ID.
   * @returns true if updated, false if not found
   */
  updateTodo(id: string, updates: Partial<Omit<TodoItem, 'id'>>): boolean {
    const existing = this.todos.get(id);
    if (!existing) return false;
    this.todos.set(id, { ...existing, ...updates });
    return true;
  }

  /**
   * Remove a todo item by ID.
   * @returns true if removed, false if not found
   */
  removeTodo(id: string): boolean {
    return this.todos.delete(id);
  }

  /**
   * Clear all todos (on context clear/compact).
   * Returns the incomplete todos for backlog.
   */
  clear(): TodoItem[] {
    const incomplete = this.getIncomplete();
    this.todos.clear();
    this.lastEventId = undefined;
    return incomplete;
  }

  // ===========================================================================
  // Queries
  // ===========================================================================

  /**
   * Get a todo by ID
   */
  getTodo(id: string): TodoItem | undefined {
    return this.todos.get(id);
  }

  /**
   * Get all todos as an array (ordered by creation time)
   */
  getAllTodos(): TodoItem[] {
    return Array.from(this.todos.values()).sort(
      (a, b) => a.createdAt.localeCompare(b.createdAt)
    );
  }

  /**
   * Get todos filtered by status
   */
  getByStatus(status: TodoStatus): TodoItem[] {
    return this.getAllTodos().filter(t => t.status === status);
  }

  /**
   * Get todos filtered by source
   */
  getBySource(source: TodoSource): TodoItem[] {
    return this.getAllTodos().filter(t => t.source === source);
  }

  /**
   * Get incomplete todos (pending or in_progress)
   */
  getIncomplete(): TodoItem[] {
    return this.getAllTodos().filter(t => t.status !== 'completed');
  }

  /**
   * Get total todo count
   */
  get count(): number {
    return this.todos.size;
  }

  /**
   * Check if there are any incomplete tasks
   */
  get hasIncompleteTasks(): boolean {
    return this.getIncomplete().length > 0;
  }

  /**
   * Get the last event ID that modified this tracker
   */
  getLastEventId(): string | undefined {
    return this.lastEventId;
  }

  // ===========================================================================
  // Context Injection
  // ===========================================================================

  /**
   * Build a context string for prompt injection.
   * Returns undefined if no todos exist.
   *
   * Format:
   * ```
   * Your current task list:
   *
   * ## In Progress
   * - [>] Doing something (user)
   *
   * ## Pending
   * - [ ] Do this next
   *
   * ## Completed
   * - [x] Done with this
   * ```
   */
  buildContextString(): string | undefined {
    if (this.todos.size === 0) return undefined;

    const inProgress = this.getByStatus('in_progress');
    const pending = this.getByStatus('pending');
    const completed = this.getByStatus('completed');

    const lines: string[] = ['Your current task list:'];

    if (inProgress.length > 0) {
      lines.push('\n## In Progress');
      for (const t of inProgress) {
        const sourceNote = t.source !== 'agent' ? ` (${t.source})` : '';
        lines.push(`- [>] ${t.activeForm}${sourceNote}`);
      }
    }

    if (pending.length > 0) {
      lines.push('\n## Pending');
      for (const t of pending) {
        const sourceNote = t.source !== 'agent' ? ` (${t.source})` : '';
        lines.push(`- [ ] ${t.content}${sourceNote}`);
      }
    }

    if (completed.length > 0) {
      lines.push('\n## Completed');
      for (const t of completed) {
        lines.push(`- [x] ${t.content}`);
      }
    }

    return lines.join('\n');
  }

  /**
   * Build a summary string (e.g., "3 pending, 1 in progress, 2 completed")
   */
  buildSummaryString(): string {
    const pending = this.getByStatus('pending').length;
    const inProgress = this.getByStatus('in_progress').length;
    const completed = this.getByStatus('completed').length;

    const parts: string[] = [];
    if (pending > 0) parts.push(`${pending} pending`);
    if (inProgress > 0) parts.push(`${inProgress} in progress`);
    if (completed > 0) parts.push(`${completed} completed`);

    return parts.join(', ') || 'no tasks';
  }

  // ===========================================================================
  // Event Reconstruction
  // ===========================================================================

  /**
   * Reconstruct todo state from event history.
   *
   * This is the key method for supporting:
   * - Session resume: Replay events to rebuild state
   * - Fork: Events include parent ancestry, state is inherited
   *
   * @param events - Array of events in chronological order
   * @returns New TodoTracker with reconstructed state
   */
  static fromEvents(events: TodoTrackingEvent[]): TodoTracker {
    const tracker = new TodoTracker();

    for (const event of events) {
      switch (event.type) {
        case 'todo.write': {
          const payload = event.payload as { todos: TodoItem[] };
          tracker.setTodos(payload.todos, event.id);
          break;
        }
        case 'context.cleared':
        case 'compact.boundary':
          // Clear todos on context boundaries
          tracker.clear();
          break;
        // Other event types are ignored
      }
    }

    return tracker;
  }
}

/**
 * Create a new empty TodoTracker
 */
export function createTodoTracker(): TodoTracker {
  return new TodoTracker();
}
