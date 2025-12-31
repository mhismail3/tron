/**
 * @fileoverview Tests for memory types
 *
 * TDD: Tests for the four-level memory hierarchy
 */

import { describe, it, expect } from 'vitest';
import type {
  MemoryEntry,
  SessionMemory,
  ProjectMemory,
  GlobalMemory,
  HandoffRecord,
  LedgerEntry,
  MemoryStore,
  MemoryQuery,
  MemorySearchResult,
} from '../../src/memory/types.js';

describe('Memory Types', () => {
  describe('MemoryEntry', () => {
    it('should define base memory entry structure', () => {
      const entry: MemoryEntry = {
        id: 'mem_123',
        type: 'pattern',
        content: 'Use TypeScript strict mode',
        timestamp: new Date().toISOString(),
        source: 'session',
      };

      expect(entry.id).toBeDefined();
      expect(entry.type).toBe('pattern');
      expect(entry.content).toBeTruthy();
      expect(entry.timestamp).toBeTruthy();
      expect(entry.source).toBe('session');
    });

    it('should support optional metadata', () => {
      const entry: MemoryEntry = {
        id: 'mem_124',
        type: 'decision',
        content: 'Using React instead of Vue',
        timestamp: new Date().toISOString(),
        source: 'project',
        metadata: {
          reason: 'Team familiarity',
          alternatives: ['Vue', 'Svelte'],
        },
      };

      expect(entry.metadata).toBeDefined();
      expect(entry.metadata?.reason).toBe('Team familiarity');
    });

    it('should support different entry types', () => {
      const types: MemoryEntry['type'][] = [
        'pattern',
        'decision',
        'lesson',
        'context',
        'preference',
      ];

      types.forEach(type => {
        const entry: MemoryEntry = {
          id: `mem_${type}`,
          type,
          content: `Content for ${type}`,
          timestamp: new Date().toISOString(),
          source: 'session',
        };
        expect(entry.type).toBe(type);
      });
    });
  });

  describe('SessionMemory', () => {
    it('should track conversation context', () => {
      const session: SessionMemory = {
        sessionId: 'sess_abc123',
        startedAt: new Date().toISOString(),
        messages: [],
        toolCalls: [],
        workingDirectory: '/project/path',
        activeFiles: ['/project/src/index.ts'],
        context: {},
      };

      expect(session.sessionId).toBeTruthy();
      expect(session.messages).toBeInstanceOf(Array);
      expect(session.workingDirectory).toBeTruthy();
    });

    it('should support handoff references', () => {
      const session: SessionMemory = {
        sessionId: 'sess_abc123',
        startedAt: new Date().toISOString(),
        messages: [],
        toolCalls: [],
        workingDirectory: '/project/path',
        activeFiles: [],
        context: {},
        parentHandoffId: 'handoff_xyz',
      };

      expect(session.parentHandoffId).toBe('handoff_xyz');
    });
  });

  describe('ProjectMemory', () => {
    it('should store project-level memories', () => {
      const projectMemory: ProjectMemory = {
        projectPath: '/project/path',
        projectName: 'tron',
        claudeMdPath: '/project/.claude/CLAUDE.md',
        patterns: [],
        decisions: [],
        preferences: {},
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      };

      expect(projectMemory.projectPath).toBeTruthy();
      expect(projectMemory.patterns).toBeInstanceOf(Array);
      expect(projectMemory.decisions).toBeInstanceOf(Array);
    });

    it('should track file patterns', () => {
      const projectMemory: ProjectMemory = {
        projectPath: '/project/path',
        projectName: 'tron',
        patterns: [
          {
            id: 'pat_1',
            type: 'pattern',
            content: 'Always use async/await over .then()',
            timestamp: new Date().toISOString(),
            source: 'project',
            category: 'code_style',
          },
        ],
        decisions: [],
        preferences: {},
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      };

      expect(projectMemory.patterns.length).toBe(1);
      expect(projectMemory.patterns[0].category).toBe('code_style');
    });
  });

  describe('GlobalMemory', () => {
    it('should store cross-project learnings', () => {
      const globalMemory: GlobalMemory = {
        userId: 'user_123',
        lessons: [],
        preferences: {},
        statistics: {
          totalSessions: 100,
          totalToolCalls: 5000,
        },
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      };

      expect(globalMemory.lessons).toBeInstanceOf(Array);
      expect(globalMemory.statistics.totalSessions).toBe(100);
    });
  });

  describe('HandoffRecord', () => {
    it('should capture session state for continuation', () => {
      const handoff: HandoffRecord = {
        id: 'handoff_123',
        sessionId: 'sess_abc',
        createdAt: new Date().toISOString(),
        summary: 'Implemented user authentication',
        pendingTasks: ['Add password reset', 'Add 2FA'],
        context: {
          lastFile: '/src/auth.ts',
          lastAction: 'edit',
        },
        messageCount: 25,
        toolCallCount: 50,
      };

      expect(handoff.id).toBeTruthy();
      expect(handoff.summary).toBeTruthy();
      expect(handoff.pendingTasks).toHaveLength(2);
    });

    it('should support optional parent reference', () => {
      const handoff: HandoffRecord = {
        id: 'handoff_456',
        sessionId: 'sess_def',
        createdAt: new Date().toISOString(),
        summary: 'Continued auth work',
        parentHandoffId: 'handoff_123',
        context: {},
        messageCount: 10,
        toolCallCount: 20,
      };

      expect(handoff.parentHandoffId).toBe('handoff_123');
    });
  });

  describe('LedgerEntry', () => {
    it('should track completed work', () => {
      const entry: LedgerEntry = {
        id: 'ledger_123',
        timestamp: new Date().toISOString(),
        sessionId: 'sess_abc',
        action: 'implement_feature',
        description: 'Added user login flow',
        filesModified: ['/src/auth.ts', '/src/login.tsx'],
        success: true,
      };

      expect(entry.action).toBe('implement_feature');
      expect(entry.filesModified).toHaveLength(2);
      expect(entry.success).toBe(true);
    });
  });

  describe('MemoryStore interface', () => {
    it('should define query structure', () => {
      const query: MemoryQuery = {
        source: 'project',
        type: 'pattern',
        limit: 10,
        searchText: 'async await',
      };

      expect(query.source).toBe('project');
      expect(query.type).toBe('pattern');
      expect(query.limit).toBe(10);
    });

    it('should define search result structure', () => {
      const result: MemorySearchResult = {
        entries: [],
        totalCount: 0,
        hasMore: false,
      };

      expect(result.entries).toBeInstanceOf(Array);
      expect(typeof result.totalCount).toBe('number');
      expect(typeof result.hasMore).toBe('boolean');
    });
  });
});
