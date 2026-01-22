/**
 * @fileoverview Todo Tracker Tests
 *
 * Comprehensive tests for TodoTracker class including:
 * - State management (add, update, remove, clear)
 * - Queries (by status, by source, incomplete)
 * - Context string generation
 * - Event reconstruction for session resume/fork
 */

import { describe, it, expect, beforeEach } from 'vitest';
import {
  TodoTracker,
  createTodoTracker,
  type TodoItem,
  type TodoTrackingEvent,
} from '../../src/todos/index.js';

// =============================================================================
// Test Helpers
// =============================================================================

function createTodo(overrides: Partial<TodoItem> = {}): TodoItem {
  const now = new Date().toISOString();
  return {
    id: `todo_${Math.random().toString(36).slice(2, 10)}`,
    content: 'Test task',
    activeForm: 'Testing task',
    status: 'pending',
    source: 'agent',
    createdAt: now,
    ...overrides,
  };
}

// =============================================================================
// TodoTracker Unit Tests
// =============================================================================

describe('TodoTracker', () => {
  let tracker: TodoTracker;

  beforeEach(() => {
    tracker = new TodoTracker();
  });

  // =========================================================================
  // Factory Function
  // =========================================================================

  describe('createTodoTracker', () => {
    it('creates a new empty tracker', () => {
      const t = createTodoTracker();
      expect(t.count).toBe(0);
      expect(t.getAllTodos()).toEqual([]);
    });
  });

  // =========================================================================
  // setTodos
  // =========================================================================

  describe('setTodos', () => {
    it('replaces entire todo list', () => {
      const todos = [
        createTodo({ id: 'a', content: 'Task A' }),
        createTodo({ id: 'b', content: 'Task B' }),
      ];

      tracker.setTodos(todos, 'event-1');

      expect(tracker.count).toBe(2);
      expect(tracker.getTodo('a')).toBeDefined();
      expect(tracker.getTodo('b')).toBeDefined();
    });

    it('clears previous todos on set', () => {
      tracker.setTodos([createTodo({ id: 'old' })], 'event-1');
      tracker.setTodos([createTodo({ id: 'new' })], 'event-2');

      expect(tracker.count).toBe(1);
      expect(tracker.getTodo('old')).toBeUndefined();
      expect(tracker.getTodo('new')).toBeDefined();
    });

    it('updates lastEventId', () => {
      tracker.setTodos([], 'event-123');
      expect(tracker.getLastEventId()).toBe('event-123');
    });

    it('handles empty array', () => {
      tracker.setTodos([createTodo({ id: 'x' })], 'e1');
      tracker.setTodos([], 'e2');

      expect(tracker.count).toBe(0);
      expect(tracker.getLastEventId()).toBe('e2');
    });
  });

  // =========================================================================
  // addTodo
  // =========================================================================

  describe('addTodo', () => {
    it('adds a single todo', () => {
      const todo = createTodo({ id: 'test-1' });
      tracker.addTodo(todo);

      expect(tracker.count).toBe(1);
      expect(tracker.getTodo('test-1')).toEqual(todo);
    });

    it('overwrites existing todo with same ID', () => {
      tracker.addTodo(createTodo({ id: 'dup', content: 'Original' }));
      tracker.addTodo(createTodo({ id: 'dup', content: 'Updated' }));

      expect(tracker.count).toBe(1);
      expect(tracker.getTodo('dup')?.content).toBe('Updated');
    });

    it('can add multiple todos', () => {
      tracker.addTodo(createTodo({ id: 'a' }));
      tracker.addTodo(createTodo({ id: 'b' }));
      tracker.addTodo(createTodo({ id: 'c' }));

      expect(tracker.count).toBe(3);
    });
  });

  // =========================================================================
  // updateTodo
  // =========================================================================

  describe('updateTodo', () => {
    it('updates existing todo', () => {
      tracker.addTodo(createTodo({ id: 'x', status: 'pending' }));

      const updated = tracker.updateTodo('x', { status: 'in_progress' });

      expect(updated).toBe(true);
      expect(tracker.getTodo('x')?.status).toBe('in_progress');
    });

    it('returns false for non-existent todo', () => {
      const updated = tracker.updateTodo('non-existent', { status: 'completed' });
      expect(updated).toBe(false);
    });

    it('preserves unchanged fields', () => {
      const original = createTodo({ id: 'y', content: 'Original', status: 'pending' });
      tracker.addTodo(original);

      tracker.updateTodo('y', { status: 'completed' });

      const updated = tracker.getTodo('y');
      expect(updated?.content).toBe('Original');
      expect(updated?.status).toBe('completed');
    });

    it('cannot update ID', () => {
      tracker.addTodo(createTodo({ id: 'z' }));
      // Type system prevents this, but verify behavior
      tracker.updateTodo('z', { content: 'New content' });

      expect(tracker.getTodo('z')?.id).toBe('z');
    });
  });

  // =========================================================================
  // removeTodo
  // =========================================================================

  describe('removeTodo', () => {
    it('removes existing todo', () => {
      tracker.addTodo(createTodo({ id: 'to-remove' }));

      const removed = tracker.removeTodo('to-remove');

      expect(removed).toBe(true);
      expect(tracker.getTodo('to-remove')).toBeUndefined();
      expect(tracker.count).toBe(0);
    });

    it('returns false for non-existent todo', () => {
      const removed = tracker.removeTodo('not-there');
      expect(removed).toBe(false);
    });

    it('only removes specified todo', () => {
      tracker.addTodo(createTodo({ id: 'keep-a' }));
      tracker.addTodo(createTodo({ id: 'remove' }));
      tracker.addTodo(createTodo({ id: 'keep-b' }));

      tracker.removeTodo('remove');

      expect(tracker.count).toBe(2);
      expect(tracker.getTodo('keep-a')).toBeDefined();
      expect(tracker.getTodo('keep-b')).toBeDefined();
    });
  });

  // =========================================================================
  // clear
  // =========================================================================

  describe('clear', () => {
    it('removes all todos', () => {
      tracker.setTodos([
        createTodo({ id: 'a' }),
        createTodo({ id: 'b' }),
        createTodo({ id: 'c' }),
      ], 'e1');

      tracker.clear();

      expect(tracker.count).toBe(0);
      expect(tracker.getAllTodos()).toEqual([]);
    });

    it('returns incomplete todos for backlog', () => {
      tracker.setTodos([
        createTodo({ id: 'pending-1', status: 'pending' }),
        createTodo({ id: 'in-progress-1', status: 'in_progress' }),
        createTodo({ id: 'completed-1', status: 'completed' }),
      ], 'e1');

      const incomplete = tracker.clear();

      expect(incomplete).toHaveLength(2);
      expect(incomplete.map(t => t.id).sort()).toEqual(['in-progress-1', 'pending-1']);
    });

    it('returns empty array if all completed', () => {
      tracker.setTodos([
        createTodo({ id: 'done-1', status: 'completed' }),
        createTodo({ id: 'done-2', status: 'completed' }),
      ], 'e1');

      const incomplete = tracker.clear();

      expect(incomplete).toEqual([]);
    });

    it('clears lastEventId', () => {
      tracker.setTodos([createTodo({ id: 'x' })], 'event-123');
      tracker.clear();

      expect(tracker.getLastEventId()).toBeUndefined();
    });
  });

  // =========================================================================
  // Queries
  // =========================================================================

  describe('getTodo', () => {
    it('returns todo by ID', () => {
      const todo = createTodo({ id: 'find-me' });
      tracker.addTodo(todo);

      expect(tracker.getTodo('find-me')).toEqual(todo);
    });

    it('returns undefined for missing ID', () => {
      expect(tracker.getTodo('missing')).toBeUndefined();
    });
  });

  describe('getAllTodos', () => {
    it('returns empty array for empty tracker', () => {
      expect(tracker.getAllTodos()).toEqual([]);
    });

    it('returns all todos sorted by createdAt', () => {
      const early = createTodo({ id: 'early', createdAt: '2024-01-01T00:00:00Z' });
      const late = createTodo({ id: 'late', createdAt: '2024-01-02T00:00:00Z' });
      const mid = createTodo({ id: 'mid', createdAt: '2024-01-01T12:00:00Z' });

      // Add in non-chronological order
      tracker.addTodo(late);
      tracker.addTodo(early);
      tracker.addTodo(mid);

      const todos = tracker.getAllTodos();
      expect(todos.map(t => t.id)).toEqual(['early', 'mid', 'late']);
    });
  });

  describe('getByStatus', () => {
    beforeEach(() => {
      tracker.setTodos([
        createTodo({ id: 'p1', status: 'pending' }),
        createTodo({ id: 'p2', status: 'pending' }),
        createTodo({ id: 'ip1', status: 'in_progress' }),
        createTodo({ id: 'c1', status: 'completed' }),
        createTodo({ id: 'c2', status: 'completed' }),
        createTodo({ id: 'c3', status: 'completed' }),
      ], 'e1');
    });

    it('filters by pending status', () => {
      const pending = tracker.getByStatus('pending');
      expect(pending).toHaveLength(2);
      expect(pending.every(t => t.status === 'pending')).toBe(true);
    });

    it('filters by in_progress status', () => {
      const inProgress = tracker.getByStatus('in_progress');
      expect(inProgress).toHaveLength(1);
      expect(inProgress[0].id).toBe('ip1');
    });

    it('filters by completed status', () => {
      const completed = tracker.getByStatus('completed');
      expect(completed).toHaveLength(3);
      expect(completed.every(t => t.status === 'completed')).toBe(true);
    });
  });

  describe('getBySource', () => {
    beforeEach(() => {
      tracker.setTodos([
        createTodo({ id: 'agent1', source: 'agent' }),
        createTodo({ id: 'agent2', source: 'agent' }),
        createTodo({ id: 'user1', source: 'user' }),
        createTodo({ id: 'skill1', source: 'skill' }),
      ], 'e1');
    });

    it('filters by agent source', () => {
      const agentTodos = tracker.getBySource('agent');
      expect(agentTodos).toHaveLength(2);
      expect(agentTodos.every(t => t.source === 'agent')).toBe(true);
    });

    it('filters by user source', () => {
      const userTodos = tracker.getBySource('user');
      expect(userTodos).toHaveLength(1);
      expect(userTodos[0].id).toBe('user1');
    });

    it('filters by skill source', () => {
      const skillTodos = tracker.getBySource('skill');
      expect(skillTodos).toHaveLength(1);
      expect(skillTodos[0].id).toBe('skill1');
    });
  });

  describe('getIncomplete', () => {
    it('returns pending and in_progress todos', () => {
      tracker.setTodos([
        createTodo({ id: 'pending', status: 'pending' }),
        createTodo({ id: 'in-progress', status: 'in_progress' }),
        createTodo({ id: 'completed', status: 'completed' }),
      ], 'e1');

      const incomplete = tracker.getIncomplete();

      expect(incomplete).toHaveLength(2);
      expect(incomplete.map(t => t.id).sort()).toEqual(['in-progress', 'pending']);
    });

    it('returns empty for all completed', () => {
      tracker.setTodos([
        createTodo({ id: 'c1', status: 'completed' }),
        createTodo({ id: 'c2', status: 'completed' }),
      ], 'e1');

      expect(tracker.getIncomplete()).toEqual([]);
    });
  });

  describe('count', () => {
    it('returns 0 for empty tracker', () => {
      expect(tracker.count).toBe(0);
    });

    it('returns correct count', () => {
      tracker.setTodos([
        createTodo({ id: 'a' }),
        createTodo({ id: 'b' }),
        createTodo({ id: 'c' }),
      ], 'e1');

      expect(tracker.count).toBe(3);
    });
  });

  describe('hasIncompleteTasks', () => {
    it('returns false for empty tracker', () => {
      expect(tracker.hasIncompleteTasks).toBe(false);
    });

    it('returns true when pending tasks exist', () => {
      tracker.addTodo(createTodo({ status: 'pending' }));
      expect(tracker.hasIncompleteTasks).toBe(true);
    });

    it('returns true when in_progress tasks exist', () => {
      tracker.addTodo(createTodo({ status: 'in_progress' }));
      expect(tracker.hasIncompleteTasks).toBe(true);
    });

    it('returns false when all tasks completed', () => {
      tracker.setTodos([
        createTodo({ status: 'completed' }),
        createTodo({ status: 'completed' }),
      ], 'e1');
      expect(tracker.hasIncompleteTasks).toBe(false);
    });
  });

  // =========================================================================
  // Context String Generation
  // =========================================================================

  describe('buildContextString', () => {
    it('returns undefined for empty tracker', () => {
      expect(tracker.buildContextString()).toBeUndefined();
    });

    it('includes header', () => {
      tracker.addTodo(createTodo({ status: 'pending' }));
      const context = tracker.buildContextString();
      expect(context).toContain('Your current task list:');
    });

    it('groups tasks by status', () => {
      tracker.setTodos([
        createTodo({ id: 'ip', status: 'in_progress', activeForm: 'Working on it' }),
        createTodo({ id: 'p', status: 'pending', content: 'Do this' }),
        createTodo({ id: 'c', status: 'completed', content: 'Done this' }),
      ], 'e1');

      const context = tracker.buildContextString()!;

      expect(context).toContain('## In Progress');
      expect(context).toContain('## Pending');
      expect(context).toContain('## Completed');
    });

    it('uses activeForm for in_progress tasks', () => {
      tracker.addTodo(createTodo({
        status: 'in_progress',
        content: 'Do task',
        activeForm: 'Doing task',
      }));

      const context = tracker.buildContextString()!;
      expect(context).toContain('Doing task');
      expect(context).not.toContain('Do task');
    });

    it('uses content for pending/completed tasks', () => {
      tracker.setTodos([
        createTodo({ status: 'pending', content: 'Pending content' }),
        createTodo({ status: 'completed', content: 'Completed content' }),
      ], 'e1');

      const context = tracker.buildContextString()!;
      expect(context).toContain('Pending content');
      expect(context).toContain('Completed content');
    });

    it('uses correct markers for each status', () => {
      tracker.setTodos([
        createTodo({ id: 'ip', status: 'in_progress', activeForm: 'In progress task' }),
        createTodo({ id: 'p', status: 'pending', content: 'Pending task' }),
        createTodo({ id: 'c', status: 'completed', content: 'Completed task' }),
      ], 'e1');

      const context = tracker.buildContextString()!;
      expect(context).toContain('- [>] In progress task');
      expect(context).toContain('- [ ] Pending task');
      expect(context).toContain('- [x] Completed task');
    });

    it('shows source for non-agent tasks', () => {
      tracker.setTodos([
        createTodo({ status: 'pending', content: 'User task', source: 'user' }),
        createTodo({ status: 'pending', content: 'Skill task', source: 'skill' }),
        createTodo({ status: 'pending', content: 'Agent task', source: 'agent' }),
      ], 'e1');

      const context = tracker.buildContextString()!;
      expect(context).toContain('User task (user)');
      expect(context).toContain('Skill task (skill)');
      expect(context).toContain('Agent task');
      expect(context).not.toContain('Agent task (agent)');
    });

    it('omits empty sections', () => {
      tracker.addTodo(createTodo({ status: 'pending', content: 'Only pending' }));

      const context = tracker.buildContextString()!;
      expect(context).toContain('## Pending');
      expect(context).not.toContain('## In Progress');
      expect(context).not.toContain('## Completed');
    });
  });

  describe('buildSummaryString', () => {
    it('returns "no tasks" for empty tracker', () => {
      expect(tracker.buildSummaryString()).toBe('no tasks');
    });

    it('shows counts for each status', () => {
      tracker.setTodos([
        createTodo({ status: 'pending' }),
        createTodo({ status: 'pending' }),
        createTodo({ status: 'in_progress' }),
        createTodo({ status: 'completed' }),
        createTodo({ status: 'completed' }),
        createTodo({ status: 'completed' }),
      ], 'e1');

      const summary = tracker.buildSummaryString();
      expect(summary).toBe('2 pending, 1 in progress, 3 completed');
    });

    it('omits zero counts', () => {
      tracker.setTodos([
        createTodo({ status: 'pending' }),
        createTodo({ status: 'completed' }),
      ], 'e1');

      const summary = tracker.buildSummaryString();
      expect(summary).toBe('1 pending, 1 completed');
      expect(summary).not.toContain('in progress');
    });

    it('handles single status', () => {
      tracker.addTodo(createTodo({ status: 'in_progress' }));
      expect(tracker.buildSummaryString()).toBe('1 in progress');
    });
  });

  // =========================================================================
  // Event Reconstruction
  // =========================================================================

  describe('fromEvents', () => {
    it('returns empty tracker for empty events', () => {
      const t = TodoTracker.fromEvents([]);
      expect(t.count).toBe(0);
    });

    it('reconstructs from todo.write events', () => {
      const todos = [
        createTodo({ id: 'a', content: 'Task A' }),
        createTodo({ id: 'b', content: 'Task B' }),
      ];

      const events: TodoTrackingEvent[] = [
        { id: 'e1', type: 'todo.write', payload: { todos, trigger: 'tool' } },
      ];

      const t = TodoTracker.fromEvents(events);

      expect(t.count).toBe(2);
      expect(t.getTodo('a')).toBeDefined();
      expect(t.getTodo('b')).toBeDefined();
      expect(t.getLastEventId()).toBe('e1');
    });

    it('uses latest todo.write event', () => {
      const events: TodoTrackingEvent[] = [
        {
          id: 'e1',
          type: 'todo.write',
          payload: {
            todos: [createTodo({ id: 'old', content: 'Old task' })],
            trigger: 'tool',
          },
        },
        {
          id: 'e2',
          type: 'todo.write',
          payload: {
            todos: [createTodo({ id: 'new', content: 'New task' })],
            trigger: 'tool',
          },
        },
      ];

      const t = TodoTracker.fromEvents(events);

      expect(t.count).toBe(1);
      expect(t.getTodo('old')).toBeUndefined();
      expect(t.getTodo('new')).toBeDefined();
      expect(t.getLastEventId()).toBe('e2');
    });

    it('clears on context.cleared event', () => {
      const events: TodoTrackingEvent[] = [
        {
          id: 'e1',
          type: 'todo.write',
          payload: {
            todos: [createTodo({ id: 'pre-clear' })],
            trigger: 'tool',
          },
        },
        {
          id: 'e2',
          type: 'context.cleared',
          payload: { tokensBefore: 10000, tokensAfter: 0, reason: 'manual' },
        },
      ];

      const t = TodoTracker.fromEvents(events);

      expect(t.count).toBe(0);
    });

    it('clears on compact.boundary event', () => {
      const events: TodoTrackingEvent[] = [
        {
          id: 'e1',
          type: 'todo.write',
          payload: {
            todos: [createTodo({ id: 'pre-compact' })],
            trigger: 'tool',
          },
        },
        {
          id: 'e2',
          type: 'compact.boundary',
          payload: { originalTokens: 10000, compactedTokens: 3000 },
        },
      ];

      const t = TodoTracker.fromEvents(events);

      expect(t.count).toBe(0);
    });

    it('handles todos added after clear', () => {
      const events: TodoTrackingEvent[] = [
        {
          id: 'e1',
          type: 'todo.write',
          payload: { todos: [createTodo({ id: 'old' })], trigger: 'tool' },
        },
        {
          id: 'e2',
          type: 'context.cleared',
          payload: { tokensBefore: 10000, tokensAfter: 0, reason: 'manual' },
        },
        {
          id: 'e3',
          type: 'todo.write',
          payload: { todos: [createTodo({ id: 'new' })], trigger: 'tool' },
        },
      ];

      const t = TodoTracker.fromEvents(events);

      expect(t.count).toBe(1);
      expect(t.getTodo('old')).toBeUndefined();
      expect(t.getTodo('new')).toBeDefined();
    });

    it('ignores unrelated event types', () => {
      const events: TodoTrackingEvent[] = [
        {
          id: 'e1',
          type: 'todo.write',
          payload: { todos: [createTodo({ id: 'a' })], trigger: 'tool' },
        },
        { id: 'e2', type: 'message.user', payload: { content: 'Hello' } },
        { id: 'e3', type: 'message.assistant', payload: { content: 'Hi' } },
        { id: 'e4', type: 'skill.added', payload: { skillName: 'test' } },
      ];

      const t = TodoTracker.fromEvents(events);

      expect(t.count).toBe(1);
      expect(t.getTodo('a')).toBeDefined();
    });

    it('handles complex event sequence', () => {
      const events: TodoTrackingEvent[] = [
        // First batch of todos
        {
          id: 'e1',
          type: 'todo.write',
          payload: {
            todos: [
              createTodo({ id: 'a', content: 'Task A' }),
              createTodo({ id: 'b', content: 'Task B' }),
            ],
            trigger: 'tool',
          },
        },
        // Update: mark A as in_progress, add C
        {
          id: 'e2',
          type: 'todo.write',
          payload: {
            todos: [
              createTodo({ id: 'a', content: 'Task A', status: 'in_progress' }),
              createTodo({ id: 'b', content: 'Task B' }),
              createTodo({ id: 'c', content: 'Task C' }),
            ],
            trigger: 'tool',
          },
        },
        // Context cleared
        {
          id: 'e3',
          type: 'context.cleared',
          payload: { reason: 'manual' },
        },
        // New todos after clear
        {
          id: 'e4',
          type: 'todo.write',
          payload: {
            todos: [
              createTodo({ id: 'x', content: 'New Task X' }),
            ],
            trigger: 'tool',
          },
        },
      ];

      const t = TodoTracker.fromEvents(events);

      // Should only have todos from after the clear
      expect(t.count).toBe(1);
      expect(t.getTodo('a')).toBeUndefined();
      expect(t.getTodo('b')).toBeUndefined();
      expect(t.getTodo('c')).toBeUndefined();
      expect(t.getTodo('x')).toBeDefined();
      expect(t.getLastEventId()).toBe('e4');
    });
  });

  // =========================================================================
  // Fork Scenarios (Integration)
  // =========================================================================

  describe('Fork Scenarios', () => {
    it('fork inherits parent todo state via event ancestry', () => {
      // Parent session events
      const parentEvents: TodoTrackingEvent[] = [
        {
          id: 'p1',
          type: 'todo.write',
          payload: {
            todos: [createTodo({ id: 'inherited', content: 'Inherited task' })],
            trigger: 'tool',
          },
        },
      ];

      // Fork includes parent events via ancestry
      const forkEvents: TodoTrackingEvent[] = [
        ...parentEvents,
        { id: 'f1', type: 'session.fork', payload: { forkedFrom: 'p1' } },
      ];

      const t = TodoTracker.fromEvents(forkEvents);

      expect(t.getTodo('inherited')).toBeDefined();
    });

    it('fork can add new todos without affecting parent', () => {
      const parentEvents: TodoTrackingEvent[] = [
        {
          id: 'p1',
          type: 'todo.write',
          payload: {
            todos: [createTodo({ id: 'parent-task', content: 'Parent task' })],
            trigger: 'tool',
          },
        },
      ];

      const forkEvents: TodoTrackingEvent[] = [
        ...parentEvents,
        { id: 'f1', type: 'session.fork', payload: { forkedFrom: 'p1' } },
        {
          id: 'f2',
          type: 'todo.write',
          payload: {
            todos: [
              createTodo({ id: 'parent-task', content: 'Parent task' }),
              createTodo({ id: 'fork-task', content: 'Fork task' }),
            ],
            trigger: 'tool',
          },
        },
      ];

      const parentTracker = TodoTracker.fromEvents(parentEvents);
      const forkTracker = TodoTracker.fromEvents(forkEvents);

      // Parent unchanged
      expect(parentTracker.count).toBe(1);
      expect(parentTracker.getTodo('fork-task')).toBeUndefined();

      // Fork has both
      expect(forkTracker.count).toBe(2);
      expect(forkTracker.getTodo('parent-task')).toBeDefined();
      expect(forkTracker.getTodo('fork-task')).toBeDefined();
    });
  });
});
