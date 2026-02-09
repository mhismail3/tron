/**
 * @fileoverview Todo Controller
 *
 * Extracted from EventStoreOrchestrator to handle todo and backlog operations.
 * Manages the session-scoped todo list and cross-session backlog persistence.
 *
 * ## Responsibilities
 *
 * - Track todos per session via TodoTracker
 * - Handle TodoWrite tool updates
 * - Manage backlog service for cross-session task persistence
 * - Restore tasks from backlog to sessions
 * - Backlog incomplete todos on context clear/session end
 */

import * as crypto from 'crypto';
import { createLogger } from '@infrastructure/logging/index.js';
import { BacklogService, createBacklogService } from '@capabilities/todos/backlog-service.js';
import type { TodoItem, BackloggedTask } from '@capabilities/todos/types.js';
import type { EventStore } from '@infrastructure/events/event-store.js';
import type { ActiveSessionStore } from '../session/active-session-store.js';

const logger = createLogger('todo-controller');

// =============================================================================
// Types
// =============================================================================

export interface TodoControllerConfig {
  /** Active session store */
  sessionStore: ActiveSessionStore;
  /** Event store for backlog service */
  eventStore: EventStore;
  /** Emit event */
  emit: (event: string, data: unknown) => void;
}

// =============================================================================
// TodoController Class
// =============================================================================

/**
 * Handles todo and backlog operations for sessions.
 */
export class TodoController {
  private config: TodoControllerConfig;
  private backlogService: BacklogService | null = null;

  constructor(config: TodoControllerConfig) {
    this.config = config;
  }

  /**
   * Get or create the backlog service (lazy initialization).
   */
  private getBacklogService(): BacklogService {
    if (!this.backlogService) {
      const db = this.config.eventStore.getDatabase();
      if (!db) {
        throw new Error('Database not available for backlog service');
      }
      this.backlogService = createBacklogService(db);
    }
    return this.backlogService;
  }

  // ===========================================================================
  // Todo Operations
  // ===========================================================================

  /**
   * Handle todos being updated via the TodoWrite tool.
   * Updates the tracker and persists a todo.write event.
   */
  async handleTodosUpdated(sessionId: string, todos: TodoItem[]): Promise<void> {
    const active = this.config.sessionStore.get(sessionId);
    if (!active) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    // Persist todo.write event (linearized via SessionContext)
    const event = await active.sessionContext!.appendEvent('todo.write', {
      todos,
      trigger: 'tool',
    });

    // Update the tracker
    if (event) {
      active.todoTracker.setTodos(todos, event.id);
    }

    logger.debug('Todos updated', {
      sessionId,
      todoCount: todos.length,
      eventId: event?.id,
    });

    // Emit event for UI updates
    this.config.emit('todos_updated', {
      sessionId,
      todos,
    });
  }

  /**
   * Get current todos for a session.
   */
  getTodos(sessionId: string): TodoItem[] {
    const active = this.config.sessionStore.get(sessionId);
    if (!active) {
      return [];
    }
    return active.todoTracker.getAllTodos();
  }

  /**
   * Get todo summary for a session.
   */
  getTodoSummary(sessionId: string): string {
    const active = this.config.sessionStore.get(sessionId);
    if (!active) {
      return 'no tasks';
    }
    return active.todoTracker.buildSummaryString();
  }

  // ===========================================================================
  // Backlog Operations
  // ===========================================================================

  /**
   * Get backlogged tasks for a workspace.
   */
  getBacklog(workspaceId: string, options?: { includeRestored?: boolean; limit?: number }): BackloggedTask[] {
    return this.getBacklogService().getBacklog(workspaceId, options);
  }

  /**
   * Get count of unrestored backlogged tasks for a workspace.
   */
  getBacklogCount(workspaceId: string): number {
    return this.getBacklogService().getUnrestoredCount(workspaceId);
  }

  /**
   * Restore tasks from backlog to a session.
   * Creates new TodoItems in the session and records a todo.write event.
   */
  async restoreFromBacklog(sessionId: string, taskIds: string[]): Promise<TodoItem[]> {
    const active = this.config.sessionStore.get(sessionId);
    if (!active) {
      const err = new Error('Session not active');
      (err as any).code = 'SESSION_NOT_ACTIVE';
      throw err;
    }

    // Generate IDs for restored tasks
    const generateId = () => `todo_${crypto.randomUUID().slice(0, 8)}`;

    // Restore tasks from backlog (marks them as restored in DB)
    const restoredTodos = this.getBacklogService().restoreTasks(taskIds, sessionId, generateId);

    if (restoredTodos.length === 0) {
      return [];
    }

    // Merge with existing todos
    const existingTodos = active.todoTracker.getAllTodos();
    const newTodoList = [...existingTodos, ...restoredTodos];

    // Record todo.write event with merged list
    const event = await active.sessionContext!.appendEvent('todo.write', {
      todos: newTodoList,
      trigger: 'restore',
    });

    if (event) {
      active.todoTracker.setTodos(newTodoList, event.id);
    }

    // Emit event for WebSocket broadcast
    this.config.emit('todos_updated', {
      sessionId,
      todos: newTodoList,
      restoredCount: restoredTodos.length,
    });

    logger.info('Tasks restored from backlog', {
      sessionId,
      requestedCount: taskIds.length,
      restoredCount: restoredTodos.length,
      totalTodos: newTodoList.length,
    });

    return restoredTodos;
  }

  /**
   * Move incomplete todos to backlog for a session.
   * Called internally when context is cleared or session ends.
   */
  async backlogIncompleteTodos(
    sessionId: string,
    workspaceId: string,
    reason: 'session_clear' | 'context_compact' | 'session_end'
  ): Promise<number> {
    const active = this.config.sessionStore.get(sessionId);
    if (!active) {
      return 0;
    }

    const incompleteTodos = active.todoTracker.getIncomplete();
    if (incompleteTodos.length === 0) {
      return 0;
    }

    this.getBacklogService().backlogTasks(incompleteTodos, sessionId, workspaceId, reason);

    logger.info('Incomplete todos backlogged', {
      sessionId,
      workspaceId,
      reason,
      count: incompleteTodos.length,
    });

    return incompleteTodos.length;
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create a TodoController instance.
 */
export function createTodoController(config: TodoControllerConfig): TodoController {
  return new TodoController(config);
}
