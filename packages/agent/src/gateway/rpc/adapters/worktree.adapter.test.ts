/**
 * @fileoverview Tests for Worktree Adapter
 *
 * The worktree adapter delegates git worktree operations
 * to the EventStoreOrchestrator.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createWorktreeAdapter } from './worktree.adapter.js';
import type { EventStoreOrchestrator } from '../../../event-store-orchestrator.js';

describe('WorktreeAdapter', () => {
  let mockOrchestrator: Partial<EventStoreOrchestrator>;

  beforeEach(() => {
    mockOrchestrator = {
      getWorktreeStatus: vi.fn(),
      commitWorktree: vi.fn(),
      mergeWorktree: vi.fn(),
      listWorktrees: vi.fn(),
    };
  });

  describe('getWorktreeStatus', () => {
    it('should return worktree status from orchestrator', async () => {
      const mockStatus = {
        isolated: true,
        branch: 'feature/test',
        baseCommit: 'abc123',
        path: '/path/to/worktree',
        hasUncommittedChanges: true,
        commitCount: 3,
      };
      vi.mocked(mockOrchestrator.getWorktreeStatus!).mockResolvedValue(mockStatus);

      const adapter = createWorktreeAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getWorktreeStatus('sess-123');

      expect(mockOrchestrator.getWorktreeStatus).toHaveBeenCalledWith('sess-123');
      expect(result).toEqual(mockStatus);
    });

    it('should return null when no worktree exists', async () => {
      vi.mocked(mockOrchestrator.getWorktreeStatus!).mockResolvedValue(null);

      const adapter = createWorktreeAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.getWorktreeStatus('sess-123');

      expect(result).toBeNull();
    });
  });

  describe('commitWorktree', () => {
    it('should delegate commit to orchestrator', async () => {
      const mockResult = {
        success: true,
        commitHash: 'def456',
        filesChanged: ['file1.ts', 'file2.ts'],
      };
      vi.mocked(mockOrchestrator.commitWorktree!).mockResolvedValue(mockResult);

      const adapter = createWorktreeAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.commitWorktree('sess-123', 'Commit message');

      expect(mockOrchestrator.commitWorktree).toHaveBeenCalledWith('sess-123', 'Commit message');
      expect(result).toEqual(mockResult);
    });

    it('should return error result on failure', async () => {
      const mockResult = {
        success: false,
        error: 'No changes to commit',
      };
      vi.mocked(mockOrchestrator.commitWorktree!).mockResolvedValue(mockResult);

      const adapter = createWorktreeAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.commitWorktree('sess-123', 'Commit message');

      expect(result.success).toBe(false);
      expect(result.error).toBe('No changes to commit');
    });
  });

  describe('mergeWorktree', () => {
    it('should delegate merge to orchestrator with default strategy', async () => {
      const mockResult = {
        success: true,
        mergeCommit: 'ghi789',
      };
      vi.mocked(mockOrchestrator.mergeWorktree!).mockResolvedValue(mockResult);

      const adapter = createWorktreeAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.mergeWorktree('sess-123', 'main');

      expect(mockOrchestrator.mergeWorktree).toHaveBeenCalledWith('sess-123', 'main', undefined);
      expect(result).toEqual(mockResult);
    });

    it('should pass strategy to orchestrator', async () => {
      const mockResult = { success: true, mergeCommit: 'jkl012' };
      vi.mocked(mockOrchestrator.mergeWorktree!).mockResolvedValue(mockResult);

      const adapter = createWorktreeAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      await adapter.mergeWorktree('sess-123', 'main', 'squash');

      expect(mockOrchestrator.mergeWorktree).toHaveBeenCalledWith('sess-123', 'main', 'squash');
    });

    it('should return conflicts on merge failure', async () => {
      const mockResult = {
        success: false,
        conflicts: ['file1.ts', 'file2.ts'],
      };
      vi.mocked(mockOrchestrator.mergeWorktree!).mockResolvedValue(mockResult);

      const adapter = createWorktreeAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.mergeWorktree('sess-123', 'main');

      expect(result.success).toBe(false);
      expect(result.conflicts).toEqual(['file1.ts', 'file2.ts']);
    });
  });

  describe('listWorktrees', () => {
    it('should return list of worktrees', async () => {
      const mockWorktrees = [
        { path: '/path/1', branch: 'feature/a', sessionId: 'sess-1' },
        { path: '/path/2', branch: 'feature/b', sessionId: 'sess-2' },
      ];
      vi.mocked(mockOrchestrator.listWorktrees!).mockResolvedValue(mockWorktrees);

      const adapter = createWorktreeAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.listWorktrees();

      expect(mockOrchestrator.listWorktrees).toHaveBeenCalled();
      expect(result).toEqual(mockWorktrees);
    });

    it('should return empty array when no worktrees exist', async () => {
      vi.mocked(mockOrchestrator.listWorktrees!).mockResolvedValue([]);

      const adapter = createWorktreeAdapter({
        orchestrator: mockOrchestrator as EventStoreOrchestrator,
      });

      const result = await adapter.listWorktrees();

      expect(result).toEqual([]);
    });
  });
});
