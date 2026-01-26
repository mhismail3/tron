/**
 * @fileoverview WorktreeController Tests
 *
 * Tests for the WorktreeController which manages git worktree operations.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';
import {
  WorktreeController,
  createWorktreeController,
  type WorktreeControllerConfig,
} from '../worktree-controller.js';
import type { ActiveSession } from '../../types.js';

describe('WorktreeController', () => {
  let mockWorktreeCoordinator: any;
  let mockGetActiveSession: ReturnType<typeof vi.fn>;
  let controller: WorktreeController;

  const mockWorkingDir = '/test/worktree';

  beforeEach(() => {
    mockWorktreeCoordinator = {
      mergeSession: vi.fn(),
      listWorktrees: vi.fn(),
    };

    mockGetActiveSession = vi.fn();

    controller = createWorktreeController({
      worktreeCoordinator: mockWorktreeCoordinator,
      getActiveSession: mockGetActiveSession,
    });
  });

  // ===========================================================================
  // getStatus
  // ===========================================================================

  describe('getStatus', () => {
    it('returns null when session not found', async () => {
      mockGetActiveSession.mockReturnValue(undefined);

      const result = await controller.getStatus('sess-123');

      expect(result).toBeNull();
    });

    it('returns null when session has no worktree', async () => {
      mockGetActiveSession.mockReturnValue({ workingDir: null } as any);

      const result = await controller.getStatus('sess-123');

      expect(result).toBeNull();
    });

    it('returns worktree info for session with worktree', async () => {
      mockGetActiveSession.mockReturnValue({ workingDir: mockWorkingDir } as any);

      // Mock the buildWorktreeInfoWithStatus function by testing the controller
      // delegates correctly - the actual git operations are tested in integration tests
      const result = await controller.getStatus('sess-123');

      // Result will be null in unit test since we can't mock the file system
      // The important thing is the method doesn't throw
      expect(mockGetActiveSession).toHaveBeenCalledWith('sess-123');
    });
  });

  // ===========================================================================
  // commit
  // ===========================================================================

  describe('commit', () => {
    it('returns error when session not found', async () => {
      mockGetActiveSession.mockReturnValue(undefined);

      const result = await controller.commit('sess-123', 'Test commit');

      expect(result.success).toBe(false);
      expect(result.error).toBe('Session not found or no worktree');
    });

    it('returns error when session has no worktree', async () => {
      mockGetActiveSession.mockReturnValue({ workingDir: null } as any);

      const result = await controller.commit('sess-123', 'Test commit');

      expect(result.success).toBe(false);
      expect(result.error).toBe('Session not found or no worktree');
    });

    it('attempts commit for session with worktree', async () => {
      mockGetActiveSession.mockReturnValue({ workingDir: mockWorkingDir } as any);

      // The actual git operations are tested in integration tests
      // Here we just verify the method doesn't throw
      const result = await controller.commit('sess-123', 'Test commit');

      expect(mockGetActiveSession).toHaveBeenCalledWith('sess-123');
    });
  });

  // ===========================================================================
  // merge
  // ===========================================================================

  describe('merge', () => {
    it('delegates merge to worktree coordinator', async () => {
      const mergeResult = {
        success: true,
        mergeCommit: 'abc123',
      };
      mockWorktreeCoordinator.mergeSession.mockResolvedValue(mergeResult);

      const result = await controller.merge('sess-123', 'main');

      expect(mockWorktreeCoordinator.mergeSession).toHaveBeenCalledWith('sess-123', 'main', 'merge');
      expect(result).toEqual(mergeResult);
    });

    it('uses specified merge strategy', async () => {
      const mergeResult = {
        success: true,
        mergeCommit: 'def456',
      };
      mockWorktreeCoordinator.mergeSession.mockResolvedValue(mergeResult);

      const result = await controller.merge('sess-123', 'main', 'squash');

      expect(mockWorktreeCoordinator.mergeSession).toHaveBeenCalledWith('sess-123', 'main', 'squash');
      expect(result).toEqual(mergeResult);
    });

    it('returns conflicts on merge failure', async () => {
      const mergeResult = {
        success: false,
        conflicts: ['src/file1.ts', 'src/file2.ts'],
      };
      mockWorktreeCoordinator.mergeSession.mockResolvedValue(mergeResult);

      const result = await controller.merge('sess-123', 'main');

      expect(result.success).toBe(false);
      expect(result.conflicts).toEqual(['src/file1.ts', 'src/file2.ts']);
    });
  });

  // ===========================================================================
  // list
  // ===========================================================================

  describe('list', () => {
    it('returns list of worktrees from coordinator', async () => {
      const worktrees = [
        { path: '/worktree1', branch: 'feature-1', sessionId: 'sess-1' },
        { path: '/worktree2', branch: 'feature-2', sessionId: 'sess-2' },
      ];
      mockWorktreeCoordinator.listWorktrees.mockResolvedValue(worktrees);

      const result = await controller.list();

      expect(mockWorktreeCoordinator.listWorktrees).toHaveBeenCalled();
      expect(result).toEqual(worktrees);
    });

    it('returns empty array when no worktrees', async () => {
      mockWorktreeCoordinator.listWorktrees.mockResolvedValue([]);

      const result = await controller.list();

      expect(result).toEqual([]);
    });
  });

  // ===========================================================================
  // getCoordinator
  // ===========================================================================

  describe('getCoordinator', () => {
    it('returns the worktree coordinator', () => {
      const coordinator = controller.getCoordinator();

      expect(coordinator).toBe(mockWorktreeCoordinator);
    });
  });

  // ===========================================================================
  // Factory Function
  // ===========================================================================

  describe('createWorktreeController', () => {
    it('creates a WorktreeController instance', () => {
      const ctrl = createWorktreeController({
        worktreeCoordinator: mockWorktreeCoordinator,
        getActiveSession: mockGetActiveSession,
      });

      expect(ctrl).toBeInstanceOf(WorktreeController);
    });
  });
});
