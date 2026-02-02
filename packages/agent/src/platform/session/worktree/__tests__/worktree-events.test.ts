/**
 * @fileoverview Tests for WorktreeEvents
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  WorktreeEvents,
  createWorktreeEvents,
  type WorktreeEventsDeps,
} from '../worktree-events.js';
import type { SessionId } from '@infrastructure/events/types.js';

// =============================================================================
// Test Helpers
// =============================================================================

function createMockEventStore() {
  return {
    append: vi.fn().mockResolvedValue('event-id'),
  };
}

// =============================================================================
// Tests
// =============================================================================

describe('WorktreeEvents', () => {
  let mockEventStore: ReturnType<typeof createMockEventStore>;
  let events: WorktreeEvents;
  const sessionId = 'test-session' as SessionId;

  beforeEach(() => {
    mockEventStore = createMockEventStore();
    events = createWorktreeEvents({ eventStore: mockEventStore });
  });

  describe('emitAcquired', () => {
    it('should emit worktree.acquired event', async () => {
      await events.emitAcquired(sessionId, {
        path: '/path/to/worktree',
        branch: 'session/test-session',
        baseCommit: 'abc123',
        isolated: true,
      });

      expect(mockEventStore.append).toHaveBeenCalledTimes(1);
      expect(mockEventStore.append).toHaveBeenCalledWith(
        sessionId,
        'worktree.acquired',
        expect.objectContaining({
          path: '/path/to/worktree',
          branch: 'session/test-session',
          baseCommit: 'abc123',
          isolated: true,
        })
      );
    });

    it('should include all required fields', async () => {
      await events.emitAcquired(sessionId, {
        path: '/worktree',
        branch: 'main',
        baseCommit: 'def456',
        isolated: false,
      });

      const call = mockEventStore.append.mock.calls[0];
      const payload = call[2];

      expect(payload.path).toBe('/worktree');
      expect(payload.branch).toBe('main');
      expect(payload.baseCommit).toBe('def456');
      expect(payload.isolated).toBe(false);
    });

    it('should include fork info when provided', async () => {
      await events.emitAcquired(sessionId, {
        path: '/forked/worktree',
        branch: 'session/forked',
        baseCommit: 'fork123',
        isolated: true,
        forkedFrom: {
          sessionId: 'parent-session' as SessionId,
          commit: 'parent-commit',
        },
      });

      const call = mockEventStore.append.mock.calls[0];
      const payload = call[2];

      expect(payload.forkedFrom).toEqual({
        sessionId: 'parent-session',
        commit: 'parent-commit',
      });
    });
  });

  describe('emitReleased', () => {
    it('should emit worktree.released event', async () => {
      await events.emitReleased(sessionId, {
        path: '/path/to/worktree',
        branch: 'session/test-session',
      });

      expect(mockEventStore.append).toHaveBeenCalledTimes(1);
      expect(mockEventStore.append).toHaveBeenCalledWith(
        sessionId,
        'worktree.released',
        expect.objectContaining({
          path: '/path/to/worktree',
          branch: 'session/test-session',
        })
      );
    });

    it('should include cleanup info', async () => {
      await events.emitReleased(sessionId, {
        path: '/worktree',
        branch: 'feature',
        branchDeleted: true,
        worktreeDeleted: true,
      });

      const call = mockEventStore.append.mock.calls[0];
      const payload = call[2];

      expect(payload.branchDeleted).toBe(true);
      expect(payload.worktreeDeleted).toBe(true);
    });
  });

  describe('emitCommit', () => {
    it('should emit worktree.commit event', async () => {
      await events.emitCommit(sessionId, {
        hash: 'commit-hash-123',
        message: 'Test commit message',
      });

      expect(mockEventStore.append).toHaveBeenCalledTimes(1);
      expect(mockEventStore.append).toHaveBeenCalledWith(
        sessionId,
        'worktree.commit',
        expect.objectContaining({
          hash: 'commit-hash-123',
          message: 'Test commit message',
        })
      );
    });

    it('should include commit hash and message', async () => {
      await events.emitCommit(sessionId, {
        hash: 'abc123def',
        message: 'Fix bug',
      });

      const call = mockEventStore.append.mock.calls[0];
      const payload = call[2];

      expect(payload.hash).toBe('abc123def');
      expect(payload.message).toBe('Fix bug');
    });
  });

  describe('emitMerged', () => {
    it('should emit worktree.merged event', async () => {
      await events.emitMerged(sessionId, {
        success: true,
        strategy: 'merge',
        commitHash: 'merge-commit',
        targetBranch: 'main',
        sourceBranch: 'feature',
      });

      expect(mockEventStore.append).toHaveBeenCalledTimes(1);
      expect(mockEventStore.append).toHaveBeenCalledWith(
        sessionId,
        'worktree.merged',
        expect.objectContaining({
          success: true,
          strategy: 'merge',
          commitHash: 'merge-commit',
        })
      );
    });

    it('should include merge result details', async () => {
      await events.emitMerged(sessionId, {
        success: false,
        strategy: 'rebase',
        conflicts: ['file1.txt', 'file2.txt'],
        targetBranch: 'main',
        sourceBranch: 'feature',
      });

      const call = mockEventStore.append.mock.calls[0];
      const payload = call[2];

      expect(payload.success).toBe(false);
      expect(payload.strategy).toBe('rebase');
      expect(payload.conflicts).toEqual(['file1.txt', 'file2.txt']);
    });
  });

  describe('factory function', () => {
    it('should create WorktreeEvents instance', () => {
      const events = createWorktreeEvents({ eventStore: mockEventStore });
      expect(events).toBeInstanceOf(WorktreeEvents);
    });
  });
});
