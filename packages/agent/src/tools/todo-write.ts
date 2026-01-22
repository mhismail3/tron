/**
 * @fileoverview TodoWrite Tool
 *
 * Allows the agent to create and manage a structured task list.
 * Uses snapshot-based updates (each call replaces the full list).
 */

import type { TronTool, TronToolResult } from '../types/index.js';
import type { TodoItem } from '../todos/types.js';
import { createLogger } from '../logging/logger.js';

const logger = createLogger('tool:todo-write');

// =============================================================================
// Types
// =============================================================================

/**
 * Input parameters for TodoWrite tool
 */
export interface TodoWriteParams {
  todos: Array<{
    content: string;
    status: 'pending' | 'in_progress' | 'completed';
    activeForm: string;
  }>;
}

/**
 * Configuration for TodoWrite tool
 */
export interface TodoWriteToolConfig {
  /**
   * Callback when todos are updated.
   * Receives the full list of TodoItems with IDs.
   */
  onTodosUpdated: (todos: TodoItem[]) => Promise<void>;

  /**
   * Generate a unique ID for a new todo
   */
  generateId: () => string;
}

/**
 * Details returned with the tool result
 */
export interface TodoWriteDetails {
  todoCount: number;
  pendingCount: number;
  inProgressCount: number;
  completedCount: number;
}

// =============================================================================
// Tool Implementation
// =============================================================================

/**
 * TodoWrite tool for task management.
 *
 * The agent uses this tool to:
 * - Create a structured task list for complex work
 * - Track progress on multi-step tasks
 * - Mark tasks as in_progress or completed
 */
export class TodoWriteTool implements TronTool<TodoWriteParams, TodoWriteDetails> {
  readonly name = 'TodoWrite';
  readonly label = 'Task Manager';
  readonly description = `Create and manage a structured task list for your current session.

## When to Use
- Complex multi-step tasks (3+ steps)
- User provides multiple tasks
- After receiving new instructions - capture them as todos
- When starting work (mark as in_progress)
- After completing work (mark as completed)

## When NOT to Use
- Single, straightforward tasks
- Trivial changes (typo fixes, simple questions)
- Pure research/exploration tasks

## Task States
- pending: Not yet started
- in_progress: Currently working on (limit to ONE at a time)
- completed: Finished successfully

## Important Rules
- Mark tasks complete IMMEDIATELY after finishing (don't batch)
- Only ONE task should be in_progress at a time
- content: Imperative form ("Run tests", "Fix the bug")
- activeForm: Present continuous ("Running tests", "Fixing the bug")`;

  readonly parameters = {
    type: 'object' as const,
    properties: {
      todos: {
        type: 'array' as const,
        description: 'The complete updated todo list. This replaces the previous list.',
        items: {
          type: 'object' as const,
          properties: {
            content: {
              type: 'string' as const,
              description: 'Task description in imperative form (e.g., "Fix the authentication bug")',
            },
            status: {
              type: 'string' as const,
              enum: ['pending', 'in_progress', 'completed'],
              description: 'Current status of the task',
            },
            activeForm: {
              type: 'string' as const,
              description: 'Present continuous form for display (e.g., "Fixing the authentication bug")',
            },
          },
          required: ['content', 'status', 'activeForm'],
        },
      },
    },
    required: ['todos'] as string[],
  };

  private config: TodoWriteToolConfig;

  constructor(config: TodoWriteToolConfig) {
    this.config = config;
  }

  async execute(args: Record<string, unknown>): Promise<TronToolResult<TodoWriteDetails>> {
    // Validate required parameters
    if (!args.todos) {
      return {
        content: 'Error: todos parameter is required',
        isError: true,
      };
    }

    if (!Array.isArray(args.todos)) {
      return {
        content: 'Error: todos must be an array',
        isError: true,
      };
    }

    const inputTodos = args.todos as TodoWriteParams['todos'];

    // Validate each todo
    for (let i = 0; i < inputTodos.length; i++) {
      const todo = inputTodos[i];
      if (!todo || typeof todo !== 'object') {
        return {
          content: `Error: todos[${i}] must be an object`,
          isError: true,
        };
      }
      if (!todo.content || typeof todo.content !== 'string') {
        return {
          content: `Error: todos[${i}].content is required and must be a string`,
          isError: true,
        };
      }
      if (!todo.status || !['pending', 'in_progress', 'completed'].includes(todo.status)) {
        return {
          content: `Error: todos[${i}].status must be "pending", "in_progress", or "completed"`,
          isError: true,
        };
      }
      if (!todo.activeForm || typeof todo.activeForm !== 'string') {
        return {
          content: `Error: todos[${i}].activeForm is required and must be a string`,
          isError: true,
        };
      }
    }

    // Convert to full TodoItems with IDs
    const now = new Date().toISOString();
    const todos: TodoItem[] = inputTodos.map(t => ({
      id: this.config.generateId(),
      content: t.content,
      activeForm: t.activeForm,
      status: t.status,
      source: 'agent' as const,
      createdAt: now,
      completedAt: t.status === 'completed' ? now : undefined,
    }));

    logger.debug('TodoWrite tool called', {
      todoCount: todos.length,
      statuses: todos.map(t => t.status),
    });

    // Call the update callback
    await this.config.onTodosUpdated(todos);

    // Count statuses
    let completed = 0;
    let inProgress = 0;
    let pending = 0;

    for (const t of todos) {
      if (t.status === 'completed') completed++;
      else if (t.status === 'in_progress') inProgress++;
      else pending++;
    }

    // Build output
    const lines = ['Todo list updated:'];
    for (const t of todos) {
      const mark = t.status === 'completed' ? 'x' : t.status === 'in_progress' ? '>' : ' ';
      const text = t.status === 'in_progress' ? t.activeForm : t.content;
      lines.push(`- [${mark}] ${text}`);
    }
    lines.push('');
    lines.push(`${completed} completed, ${inProgress} in progress, ${pending} pending`);

    logger.info('Todo list updated', {
      todoCount: todos.length,
      completed,
      inProgress,
      pending,
    });

    return {
      content: lines.join('\n'),
      isError: false,
      details: {
        todoCount: todos.length,
        pendingCount: pending,
        inProgressCount: inProgress,
        completedCount: completed,
      },
    };
  }
}
