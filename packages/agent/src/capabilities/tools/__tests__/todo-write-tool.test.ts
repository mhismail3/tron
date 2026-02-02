/**
 * @fileoverview TodoWrite Tool Tests
 *
 * Comprehensive tests for the TodoWriteTool including:
 * - Parameter validation
 * - Todo creation and ID generation
 * - Output formatting
 * - Error handling
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { TodoWriteTool, type TodoWriteToolConfig } from '../ui/todo-write.js';
import type { TodoItem } from '../../todos/types.js';

// =============================================================================
// Test Helpers
// =============================================================================

function createMockConfig(): TodoWriteToolConfig {
  let counter = 0;
  return {
    generateId: vi.fn(() => `todo_${++counter}`),
    onTodosUpdated: vi.fn().mockResolvedValue(undefined),
  };
}

// =============================================================================
// TodoWriteTool Tests
// =============================================================================

describe('TodoWriteTool', () => {
  let tool: TodoWriteTool;
  let config: TodoWriteToolConfig;

  beforeEach(() => {
    config = createMockConfig();
    tool = new TodoWriteTool(config);
  });

  // =========================================================================
  // Tool Definition
  // =========================================================================

  describe('tool definition', () => {
    it('has correct name', () => {
      expect(tool.name).toBe('TodoWrite');
    });

    it('has correct label', () => {
      expect(tool.label).toBe('Task Manager');
    });

    it('has description explaining usage', () => {
      expect(tool.description).toContain('When to Use');
      expect(tool.description).toContain('When NOT to Use');
      expect(tool.description).toContain('Task States');
    });

    it('has correct parameters schema', () => {
      expect(tool.parameters.type).toBe('object');
      expect(tool.parameters.properties.todos.type).toBe('array');
      expect(tool.parameters.required).toContain('todos');
    });
  });

  // =========================================================================
  // Input Validation
  // =========================================================================

  describe('input validation', () => {
    it('rejects missing todos parameter', async () => {
      const result = await tool.execute({});

      expect(result.isError).toBe(true);
      expect(result.content).toContain('todos parameter is required');
    });

    it('rejects non-array todos', async () => {
      const result = await tool.execute({ todos: 'not-an-array' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('todos must be an array');
    });

    it('rejects todo without content', async () => {
      const result = await tool.execute({
        todos: [{ status: 'pending', activeForm: 'Working' }],
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('todos[0].content is required');
    });

    it('rejects todo with invalid content type', async () => {
      const result = await tool.execute({
        todos: [{ content: 123, status: 'pending', activeForm: 'Working' }],
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('todos[0].content is required and must be a string');
    });

    it('rejects todo without status', async () => {
      const result = await tool.execute({
        todos: [{ content: 'Task', activeForm: 'Working' }],
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('todos[0].status must be');
    });

    it('rejects invalid status value', async () => {
      const result = await tool.execute({
        todos: [{ content: 'Task', status: 'invalid', activeForm: 'Working' }],
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('todos[0].status must be');
    });

    it('rejects todo without activeForm', async () => {
      const result = await tool.execute({
        todos: [{ content: 'Task', status: 'pending' }],
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('todos[0].activeForm is required');
    });

    it('rejects non-object todo item', async () => {
      const result = await tool.execute({
        todos: ['not-an-object'],
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('todos[0] must be an object');
    });

    it('validates all todos in array', async () => {
      const result = await tool.execute({
        todos: [
          { content: 'Valid', status: 'pending', activeForm: 'Working' },
          { content: 'Missing status', activeForm: 'Working' }, // Missing status
        ],
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('todos[1].status');
    });

    it('accepts valid pending status', async () => {
      const result = await tool.execute({
        todos: [{ content: 'Task', status: 'pending', activeForm: 'Working' }],
      });

      expect(result.isError).toBeFalsy();
    });

    it('accepts valid in_progress status', async () => {
      const result = await tool.execute({
        todos: [{ content: 'Task', status: 'in_progress', activeForm: 'Working' }],
      });

      expect(result.isError).toBeFalsy();
    });

    it('accepts valid completed status', async () => {
      const result = await tool.execute({
        todos: [{ content: 'Task', status: 'completed', activeForm: 'Working' }],
      });

      expect(result.isError).toBeFalsy();
    });
  });

  // =========================================================================
  // Todo Creation
  // =========================================================================

  describe('todo creation', () => {
    it('generates unique IDs for each todo', async () => {
      await tool.execute({
        todos: [
          { content: 'Task A', status: 'pending', activeForm: 'Working on A' },
          { content: 'Task B', status: 'pending', activeForm: 'Working on B' },
        ],
      });

      expect(config.generateId).toHaveBeenCalledTimes(2);
    });

    it('sets source to agent', async () => {
      let capturedTodos: TodoItem[] = [];
      (config.onTodosUpdated as ReturnType<typeof vi.fn>).mockImplementation(async (todos: TodoItem[]) => {
        capturedTodos = todos;
      });

      await tool.execute({
        todos: [{ content: 'Task', status: 'pending', activeForm: 'Working' }],
      });

      expect(capturedTodos[0].source).toBe('agent');
    });

    it('sets createdAt timestamp', async () => {
      let capturedTodos: TodoItem[] = [];
      (config.onTodosUpdated as ReturnType<typeof vi.fn>).mockImplementation(async (todos: TodoItem[]) => {
        capturedTodos = todos;
      });

      const before = new Date().toISOString();
      await tool.execute({
        todos: [{ content: 'Task', status: 'pending', activeForm: 'Working' }],
      });
      const after = new Date().toISOString();

      expect(capturedTodos[0].createdAt).toBeDefined();
      expect(capturedTodos[0].createdAt >= before).toBe(true);
      expect(capturedTodos[0].createdAt <= after).toBe(true);
    });

    it('sets completedAt for completed tasks', async () => {
      let capturedTodos: TodoItem[] = [];
      (config.onTodosUpdated as ReturnType<typeof vi.fn>).mockImplementation(async (todos: TodoItem[]) => {
        capturedTodos = todos;
      });

      await tool.execute({
        todos: [
          { content: 'Pending', status: 'pending', activeForm: 'Working' },
          { content: 'Completed', status: 'completed', activeForm: 'Done' },
        ],
      });

      expect(capturedTodos[0].completedAt).toBeUndefined();
      expect(capturedTodos[1].completedAt).toBeDefined();
    });

    it('calls onTodosUpdated with full TodoItems', async () => {
      await tool.execute({
        todos: [
          { content: 'Task A', status: 'pending', activeForm: 'Working on A' },
          { content: 'Task B', status: 'in_progress', activeForm: 'Working on B' },
        ],
      });

      expect(config.onTodosUpdated).toHaveBeenCalledTimes(1);
      const todos = (config.onTodosUpdated as ReturnType<typeof vi.fn>).mock.calls[0][0] as TodoItem[];
      expect(todos).toHaveLength(2);
      expect(todos[0]).toMatchObject({
        content: 'Task A',
        status: 'pending',
        activeForm: 'Working on A',
        source: 'agent',
      });
    });

    it('handles empty todo list', async () => {
      const result = await tool.execute({ todos: [] });

      expect(result.isError).toBeFalsy();
      expect(config.onTodosUpdated).toHaveBeenCalledWith([]);
    });
  });

  // =========================================================================
  // Output Formatting
  // =========================================================================

  describe('output formatting', () => {
    it('includes header in output', async () => {
      const result = await tool.execute({
        todos: [{ content: 'Task', status: 'pending', activeForm: 'Working' }],
      });

      expect(result.content).toContain('Todo list updated:');
    });

    it('uses correct marker for pending tasks', async () => {
      const result = await tool.execute({
        todos: [{ content: 'Pending task', status: 'pending', activeForm: 'Working' }],
      });

      expect(result.content).toContain('- [ ] Pending task');
    });

    it('uses correct marker for in_progress tasks', async () => {
      const result = await tool.execute({
        todos: [{ content: 'Active task', status: 'in_progress', activeForm: 'Working on task' }],
      });

      expect(result.content).toContain('- [>] Working on task');
    });

    it('uses correct marker for completed tasks', async () => {
      const result = await tool.execute({
        todos: [{ content: 'Done task', status: 'completed', activeForm: 'Finished' }],
      });

      expect(result.content).toContain('- [x] Done task');
    });

    it('uses activeForm for in_progress display', async () => {
      const result = await tool.execute({
        todos: [{
          content: 'Fix the bug',
          status: 'in_progress',
          activeForm: 'Fixing the bug',
        }],
      });

      expect(result.content).toContain('Fixing the bug');
      expect(result.content).not.toContain('Fix the bug');
    });

    it('uses content for pending/completed display', async () => {
      const result = await tool.execute({
        todos: [
          { content: 'Pending content', status: 'pending', activeForm: 'Pending active' },
          { content: 'Completed content', status: 'completed', activeForm: 'Completed active' },
        ],
      });

      expect(result.content).toContain('Pending content');
      expect(result.content).not.toContain('Pending active');
      expect(result.content).toContain('Completed content');
      expect(result.content).not.toContain('Completed active');
    });

    it('includes status counts in summary', async () => {
      const result = await tool.execute({
        todos: [
          { content: 'A', status: 'completed', activeForm: 'A' },
          { content: 'B', status: 'completed', activeForm: 'B' },
          { content: 'C', status: 'in_progress', activeForm: 'C' },
          { content: 'D', status: 'pending', activeForm: 'D' },
          { content: 'E', status: 'pending', activeForm: 'E' },
          { content: 'F', status: 'pending', activeForm: 'F' },
        ],
      });

      expect(result.content).toContain('2 completed, 1 in progress, 3 pending');
    });

    it('lists all todos', async () => {
      const result = await tool.execute({
        todos: [
          { content: 'Task One', status: 'pending', activeForm: 'Working' },
          { content: 'Task Two', status: 'pending', activeForm: 'Working' },
          { content: 'Task Three', status: 'pending', activeForm: 'Working' },
        ],
      });

      expect(result.content).toContain('Task One');
      expect(result.content).toContain('Task Two');
      expect(result.content).toContain('Task Three');
    });
  });

  // =========================================================================
  // Result Details
  // =========================================================================

  describe('result details', () => {
    it('includes correct details', async () => {
      const result = await tool.execute({
        todos: [
          { content: 'A', status: 'pending', activeForm: 'A' },
          { content: 'B', status: 'pending', activeForm: 'B' },
          { content: 'C', status: 'in_progress', activeForm: 'C' },
          { content: 'D', status: 'completed', activeForm: 'D' },
        ],
      });

      expect(result.details).toEqual({
        todoCount: 4,
        pendingCount: 2,
        inProgressCount: 1,
        completedCount: 1,
      });
    });

    it('details match empty list', async () => {
      const result = await tool.execute({ todos: [] });

      expect(result.details).toEqual({
        todoCount: 0,
        pendingCount: 0,
        inProgressCount: 0,
        completedCount: 0,
      });
    });

    it('does not include details on error', async () => {
      const result = await tool.execute({});

      expect(result.isError).toBe(true);
      expect(result.details).toBeUndefined();
    });
  });

  // =========================================================================
  // Error Handling
  // =========================================================================

  describe('error handling', () => {
    it('propagates callback errors', async () => {
      (config.onTodosUpdated as ReturnType<typeof vi.fn>).mockRejectedValue(new Error('Callback failed'));

      await expect(
        tool.execute({
          todos: [{ content: 'Task', status: 'pending', activeForm: 'Working' }],
        })
      ).rejects.toThrow('Callback failed');
    });
  });
});
