/**
 * @fileoverview Todo Events
 *
 * Events for todo list tracking.
 */

import type { BaseEvent } from './base.js';

// =============================================================================
// Todo Events
// =============================================================================

/** Todo item for event payloads */
export interface TodoItemPayload {
  id: string;
  content: string;
  activeForm: string;
  status: 'pending' | 'in_progress' | 'completed';
  source: 'agent' | 'user' | 'skill';
  createdAt: string;
  completedAt?: string;
  metadata?: Record<string, unknown>;
}

/**
 * Todo write event - captures complete todo list state snapshot.
 * Uses snapshot approach (not diffs) for simple reconstruction.
 */
export interface TodoWriteEvent extends BaseEvent {
  type: 'todo.write';
  payload: {
    /** Complete current todo list */
    todos: TodoItemPayload[];
    /** What triggered this write */
    trigger: 'tool' | 'command' | 'skill' | 'restore';
  };
}
