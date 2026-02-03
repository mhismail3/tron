/**
 * @fileoverview TrackerReconstructor Unit Tests
 *
 * Tests for the TrackerReconstructor class which reconstructs all session trackers
 * from event history during session resumption.
 *
 * Contract:
 * 1. Reconstruct SkillTracker from skill events
 * 2. Reconstruct RulesTracker from rules events
 * 3. Reconstruct SubAgentTracker from subagent events
 * 4. Reconstruct TodoTracker from todo events
 * 5. Extract API token count from last turn_end event
 * 6. Handle empty event arrays
 * 7. Handle mixed event types correctly
 */
import { describe, it, expect, beforeEach } from 'vitest';
import {
  TrackerReconstructor,
  createTrackerReconstructor,
} from '../tracker-reconstructor.js';
import type { SessionEvent } from '@infrastructure/events/types.js';

describe('TrackerReconstructor', () => {
  let reconstructor: TrackerReconstructor;

  beforeEach(() => {
    reconstructor = createTrackerReconstructor();
  });

  describe('Empty events', () => {
    it('should return empty trackers for empty events array', () => {
      const result = reconstructor.reconstruct([]);

      expect(result.skillTracker.count).toBe(0);
      expect(result.rulesTracker.getTotalFiles()).toBe(0);
      expect(result.subagentTracker.count).toBe(0);
      expect(result.todoTracker.count).toBe(0);
      expect(result.apiTokenCount).toBeUndefined();
    });
  });

  describe('SkillTracker reconstruction', () => {
    it('should reconstruct skill tracker from skill.added events', () => {
      const events = [
        createEvent('session.start', {}),
        createEvent('skill.added', {
          skillName: 'commit',
          source: 'global',
          addedVia: 'mention',
        }),
        createEvent('skill.added', {
          skillName: 'review',
          source: 'project',
          addedVia: 'command',
        }),
      ] as SessionEvent[];

      const result = reconstructor.reconstruct(events);

      expect(result.skillTracker.count).toBe(2);
      expect(result.skillTracker.hasSkill('commit')).toBe(true);
      expect(result.skillTracker.hasSkill('review')).toBe(true);
    });

    it('should handle skill.removed events', () => {
      const events = [
        createEvent('skill.added', { skillName: 'commit', source: 'global', addedVia: 'mention' }),
        createEvent('skill.added', { skillName: 'review', source: 'global', addedVia: 'mention' }),
        createEvent('skill.removed', { skillName: 'commit' }),
      ] as SessionEvent[];

      const result = reconstructor.reconstruct(events);

      expect(result.skillTracker.count).toBe(1);
      expect(result.skillTracker.hasSkill('commit')).toBe(false);
      expect(result.skillTracker.hasSkill('review')).toBe(true);
    });
  });

  describe('RulesTracker reconstruction', () => {
    it('should reconstruct rules tracker from rules.loaded events', () => {
      const events = [
        createEvent('session.start', {}),
        createEvent('rules.loaded', {
          files: [
            { path: '/project/.claude/rules.md', relativePath: '.claude/rules.md', level: 'project', depth: 0, sizeBytes: 100 },
            { path: '/user/.claude/CLAUDE.md', relativePath: 'CLAUDE.md', level: 'global', depth: 0, sizeBytes: 200 },
          ],
          totalFiles: 2,
          mergedTokens: 500,
        }),
      ] as SessionEvent[];

      const result = reconstructor.reconstruct(events);

      expect(result.rulesTracker.getTotalFiles()).toBe(2);
      expect(result.rulesTracker.getMergedTokens()).toBe(500);
      expect(result.rulesTracker.hasRules()).toBe(true);
    });

    it('should handle multiple rules.loaded events (use latest)', () => {
      const events = [
        createEvent('rules.loaded', {
          files: [{ path: '/first.md', relativePath: 'first.md', level: 'project', depth: 0, sizeBytes: 100 }],
          totalFiles: 1,
          mergedTokens: 100,
        }),
        createEvent('rules.loaded', {
          files: [
            { path: '/second.md', relativePath: 'second.md', level: 'project', depth: 0, sizeBytes: 200 },
            { path: '/third.md', relativePath: 'third.md', level: 'project', depth: 0, sizeBytes: 300 },
          ],
          totalFiles: 2,
          mergedTokens: 500,
        }),
      ] as SessionEvent[];

      const result = reconstructor.reconstruct(events);

      // Latest event should win
      expect(result.rulesTracker.getTotalFiles()).toBe(2);
      expect(result.rulesTracker.getMergedTokens()).toBe(500);
    });
  });

  describe('SubAgentTracker reconstruction', () => {
    it('should reconstruct subagent tracker from subagent.spawned events', () => {
      const events = [
        createEvent('subagent.spawned', {
          subagentSessionId: 'sess_sub1',
          spawnType: 'Explore',
          task: 'Search for tests',
          model: 'claude-sonnet-4-20250514',
          workingDirectory: '/project',
        }),
        createEvent('subagent.spawned', {
          subagentSessionId: 'sess_sub2',
          spawnType: 'Plan',
          task: 'Create a plan',
          model: 'claude-sonnet-4-20250514',
          workingDirectory: '/project',
        }),
      ] as SessionEvent[];

      const result = reconstructor.reconstruct(events);

      expect(result.subagentTracker.count).toBe(2);
    });

    it('should track completed subagents', () => {
      const events = [
        createEvent('subagent.spawned', {
          subagentSessionId: 'sess_sub1',
          spawnType: 'Explore',
          task: 'Search',
          model: 'claude-sonnet-4-20250514',
          workingDirectory: '/project',
        }),
        createEvent('subagent.completed', {
          subagentSessionId: 'sess_sub1',
          result: 'Found 5 files',
        }),
      ] as SessionEvent[];

      const result = reconstructor.reconstruct(events);

      expect(result.subagentTracker.count).toBe(1);
      expect(result.subagentTracker.activeCount).toBe(0);
    });
  });

  describe('TodoTracker reconstruction', () => {
    it('should reconstruct todo tracker from todo.write events', () => {
      const events = [
        createEvent('todo.write', {
          todos: [
            createTodoItem('todo_1', 'First task', 'pending'),
            createTodoItem('todo_2', 'Second task', 'pending'),
          ],
          trigger: 'tool',
        }),
      ] as SessionEvent[];

      const result = reconstructor.reconstruct(events);

      expect(result.todoTracker.count).toBe(2);
      expect(result.todoTracker.hasIncompleteTasks).toBe(true);
    });

    it('should handle multiple todo.write events (latest wins)', () => {
      const events = [
        createEvent('todo.write', {
          todos: [
            createTodoItem('todo_1', 'Task', 'pending'),
          ],
          trigger: 'tool',
        }),
        createEvent('todo.write', {
          todos: [
            createTodoItem('todo_1', 'Task', 'completed'),
            createTodoItem('todo_2', 'Task 2', 'pending'),
          ],
          trigger: 'tool',
        }),
      ] as SessionEvent[];

      const result = reconstructor.reconstruct(events);

      expect(result.todoTracker.count).toBe(2);
      expect(result.todoTracker.hasIncompleteTasks).toBe(true);
    });
  });

  describe('API token count extraction', () => {
    it('should extract API token count from last turn_end event', () => {
      const events = [
        createEvent('stream.turn_end', {
          tokenRecord: createMockTokenRecord(5000),
        }),
        createEvent('stream.turn_end', {
          tokenRecord: createMockTokenRecord(10000),
        }),
        createEvent('stream.turn_end', {
          tokenRecord: createMockTokenRecord(15000),
        }),
      ] as SessionEvent[];

      const result = reconstructor.reconstruct(events);

      // Should use the LAST turn_end event's token count
      expect(result.apiTokenCount).toBe(15000);
    });

    it('should return undefined when no turn_end events exist', () => {
      const events = [
        createEvent('session.start', {}),
        createEvent('message.user', { content: 'Hello' }),
      ] as SessionEvent[];

      const result = reconstructor.reconstruct(events);

      expect(result.apiTokenCount).toBeUndefined();
    });

    it('should handle turn_end events without tokenRecord', () => {
      const events = [
        createEvent('stream.turn_end', {}),
      ] as SessionEvent[];

      const result = reconstructor.reconstruct(events);

      expect(result.apiTokenCount).toBeUndefined();
    });
  });

  describe('Mixed event types', () => {
    it('should correctly reconstruct all trackers from mixed events', () => {
      const events = [
        createEvent('session.start', {}),
        createEvent('rules.loaded', {
          files: [{ path: '/rules.md', relativePath: 'rules.md', level: 'project', depth: 0, sizeBytes: 100 }],
          totalFiles: 1,
          mergedTokens: 200,
        }),
        createEvent('skill.added', { skillName: 'commit', source: 'global', addedVia: 'mention' }),
        createEvent('message.user', { content: 'Hello' }),
        createEvent('stream.turn_end', {
          tokenRecord: createMockTokenRecord(5000),
        }),
        createEvent('subagent.spawned', {
          subagentSessionId: 'sess_sub1',
          spawnType: 'Explore',
          task: 'Search',
          model: 'claude-sonnet-4-20250514',
          workingDirectory: '/project',
        }),
        createEvent('todo.write', {
          todos: [createTodoItem('todo_1', 'Task', 'pending')],
          trigger: 'tool',
        }),
        createEvent('stream.turn_end', {
          tokenRecord: createMockTokenRecord(8000),
        }),
      ] as SessionEvent[];

      const result = reconstructor.reconstruct(events);

      expect(result.skillTracker.count).toBe(1);
      expect(result.rulesTracker.getTotalFiles()).toBe(1);
      expect(result.subagentTracker.count).toBe(1);
      expect(result.todoTracker.count).toBe(1);
      expect(result.apiTokenCount).toBe(8000);
    });
  });

  describe('Compaction boundary handling', () => {
    it('should clear skill tracker on compact.boundary', () => {
      const events = [
        // Pre-compaction events
        createEvent('skill.added', { skillName: 'old-skill', source: 'global', addedVia: 'mention' }),
        createEvent('compact.boundary', { reason: 'context_limit' }),
        // Post-compaction events
        createEvent('skill.added', { skillName: 'new-skill', source: 'global', addedVia: 'mention' }),
      ] as SessionEvent[];

      const result = reconstructor.reconstruct(events);

      // SkillTracker clears on compact.boundary, so only post-compaction skills remain
      expect(result.skillTracker.hasSkill('old-skill')).toBe(false);
      expect(result.skillTracker.hasSkill('new-skill')).toBe(true);
    });

    it('should clear todo tracker on compact.boundary', () => {
      const events = [
        createEvent('todo.write', {
          todos: [createTodoItem('todo_1', 'Old task', 'pending')],
          trigger: 'tool',
        }),
        createEvent('compact.boundary', { reason: 'context_limit' }),
        createEvent('todo.write', {
          todos: [createTodoItem('todo_2', 'New task', 'pending')],
          trigger: 'tool',
        }),
      ] as SessionEvent[];

      const result = reconstructor.reconstruct(events);

      // TodoTracker clears on compact.boundary
      expect(result.todoTracker.count).toBe(1);
    });

    it('should preserve API token count through compaction', () => {
      const events = [
        createEvent('stream.turn_end', { tokenRecord: createMockTokenRecord(5000) }),
        createEvent('compact.boundary', { reason: 'context_limit' }),
        createEvent('stream.turn_end', { tokenRecord: createMockTokenRecord(2000) }),
      ] as SessionEvent[];

      const result = reconstructor.reconstruct(events);

      // Should use the last turn_end after compaction
      expect(result.apiTokenCount).toBe(2000);
    });
  });

  describe('Type safety', () => {
    it('should return correctly typed trackers', () => {
      const result = reconstructor.reconstruct([]);

      // TypeScript should infer these correctly
      const skillCount: number = result.skillTracker.count;
      const hasRules: boolean = result.rulesTracker.hasRules();
      const subagentCount: number = result.subagentTracker.count;
      const todoCount: number = result.todoTracker.count;
      const tokenCount: number | undefined = result.apiTokenCount;

      expect(typeof skillCount).toBe('number');
      expect(typeof hasRules).toBe('boolean');
      expect(typeof subagentCount).toBe('number');
      expect(typeof todoCount).toBe('number');
      expect(tokenCount === undefined || typeof tokenCount === 'number').toBe(true);
    });
  });
});

// Helper to create mock token record
function createMockTokenRecord(contextWindowTokens: number) {
  return {
    source: {
      provider: 'anthropic' as const,
      timestamp: new Date().toISOString(),
      rawInputTokens: 100,
      rawOutputTokens: 50,
      rawCacheReadTokens: 0,
      rawCacheCreationTokens: 0,
    },
    computed: {
      contextWindowTokens,
      newInputTokens: 100,
      previousContextBaseline: 0,
      calculationMethod: 'anthropic_cache_aware' as const,
    },
    meta: {
      turn: 1,
      sessionId: 'test-session',
      extractedAt: new Date().toISOString(),
      normalizedAt: new Date().toISOString(),
    },
  };
}

// Helper to create mock events
function createEvent(type: string, payload: Record<string, unknown>): SessionEvent {
  return {
    id: `evt_${Math.random().toString(36).substring(7)}`,
    sessionId: 'sess_test',
    type: type as SessionEvent['type'],
    payload,
    timestamp: new Date().toISOString(),
    parentId: undefined,
  } as unknown as SessionEvent;
}

// Helper to create properly structured todo items
function createTodoItem(id: string, content: string, status: 'pending' | 'in_progress' | 'completed') {
  return {
    id,
    content,
    activeForm: `${content}ing`,
    status,
    source: 'agent' as const,
    createdAt: new Date().toISOString(),
  };
}
