/**
 * @fileoverview Tests for memory types
 *
 * Tests for the simplified memory type system.
 */

import { describe, it, expect } from 'vitest';
import type {
  SessionMemory,
  HandoffRecord,
  LedgerEntry,
} from '../../src/memory/types.js';

describe('Memory Types', () => {
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

    it('should track token usage', () => {
      const session: SessionMemory = {
        sessionId: 'sess_abc123',
        startedAt: new Date().toISOString(),
        messages: [],
        toolCalls: [],
        workingDirectory: '/project/path',
        activeFiles: [],
        context: {},
        tokenUsage: {
          input: 1000,
          output: 500,
        },
      };

      expect(session.tokenUsage?.input).toBe(1000);
      expect(session.tokenUsage?.output).toBe(500);
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

    it('should support compressed messages', () => {
      const handoff: HandoffRecord = {
        id: 'handoff_789',
        sessionId: 'sess_ghi',
        createdAt: new Date().toISOString(),
        summary: 'Session summary',
        context: {},
        messageCount: 50,
        toolCallCount: 100,
        compressedMessages: 'Summarized conversation content...',
        keyInsights: ['Used TDD approach', 'Fixed authentication bug'],
      };

      expect(handoff.compressedMessages).toBeTruthy();
      expect(handoff.keyInsights).toHaveLength(2);
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

    it('should track failed actions', () => {
      const entry: LedgerEntry = {
        id: 'ledger_456',
        timestamp: new Date().toISOString(),
        sessionId: 'sess_def',
        action: 'run_tests',
        description: 'Ran test suite',
        success: false,
        error: '5 tests failed',
        duration: 15000,
      };

      expect(entry.success).toBe(false);
      expect(entry.error).toBe('5 tests failed');
      expect(entry.duration).toBe(15000);
    });
  });
});
