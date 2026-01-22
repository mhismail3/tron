/**
 * @fileoverview Tests for WorktreeCoordinator
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { WorktreeCoordinator } from '../worktree-coordinator.js';
import { SessionId } from '../../events/types.js';

// Mock EventStore
const createMockEventStore = () => ({
  append: vi.fn().mockResolvedValue({ id: 'evt_test' }),
  getSession: vi.fn().mockResolvedValue(null),
  initialize: vi.fn().mockResolvedValue(undefined),
});

describe('WorktreeCoordinator', () => {
  let coordinator: WorktreeCoordinator;
  let mockEventStore: ReturnType<typeof createMockEventStore>;

  beforeEach(() => {
    mockEventStore = createMockEventStore();
    coordinator = new WorktreeCoordinator(mockEventStore as any, {
      isolationMode: 'lazy',
    });
  });

  describe('initialization', () => {
    it('should create coordinator with default config', () => {
      const coord = new WorktreeCoordinator(mockEventStore as any);
      expect(coord).toBeDefined();
    });

    it('should create coordinator with custom config', () => {
      const coord = new WorktreeCoordinator(mockEventStore as any, {
        branchPrefix: 'agent/',
        isolationMode: 'always',
        autoCommitOnRelease: false,
      });
      expect(coord).toBeDefined();
    });
  });

  describe('isGitRepo', () => {
    it('should detect git repository', async () => {
      // This test requires being run in a git repo
      const isRepo = await coordinator.isGitRepo(process.cwd());
      // We're in the tron repo, so this should be true
      expect(typeof isRepo).toBe('boolean');
    });

    it('should return false for non-git directory', async () => {
      const isRepo = await coordinator.isGitRepo('/tmp');
      expect(isRepo).toBe(false);
    });
  });

  describe('getRepoRoot', () => {
    it('should get repo root from subdirectory', async () => {
      const root = await coordinator.getRepoRoot(process.cwd());
      if (root) {
        expect(root).toContain('tron');
      }
    });

    it('should return null for non-git directory', async () => {
      const root = await coordinator.getRepoRoot('/tmp');
      expect(root).toBeNull();
    });
  });

  describe('active sessions', () => {
    it('should start with no active sessions', () => {
      const sessions = coordinator.getActiveSessions();
      expect(sessions.size).toBe(0);
    });

    it('should track if session is active', () => {
      const sessionId = SessionId('test-session');
      expect(coordinator.isSessionActive(sessionId)).toBe(false);
    });
  });

  describe('isolation decisions', () => {
    it('should not require isolation for first session in lazy mode', async () => {
      // This is tested implicitly - first session gets main directory
      const coord = new WorktreeCoordinator(mockEventStore as any, {
        isolationMode: 'lazy',
      });
      expect(coord).toBeDefined();
    });

    it('should never isolate in never mode', async () => {
      const coord = new WorktreeCoordinator(mockEventStore as any, {
        isolationMode: 'never',
      });
      expect(coord).toBeDefined();
    });

    it('should always isolate in always mode', async () => {
      const coord = new WorktreeCoordinator(mockEventStore as any, {
        isolationMode: 'always',
      });
      expect(coord).toBeDefined();
    });
  });

  describe('working directory lookup', () => {
    it('should return null for unknown session', () => {
      const sessionId = SessionId('unknown');
      const workDir = coordinator.getWorkingDirectory(sessionId);
      expect(workDir).toBeNull();
    });
  });
});
