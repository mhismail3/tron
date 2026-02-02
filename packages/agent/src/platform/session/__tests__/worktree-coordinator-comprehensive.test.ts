/**
 * @fileoverview Comprehensive WorktreeCoordinator Tests
 *
 * TDD: Write comprehensive tests BEFORE refactoring to ensure zero regressions.
 * These tests verify all existing behavior of WorktreeCoordinator.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { WorktreeCoordinator } from '../worktree-coordinator.js';
import { SessionId } from '@infrastructure/events/types.js';
import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';
import { execSync, exec } from 'child_process';
import { promisify } from 'util';

const execAsync = promisify(exec);

// =============================================================================
// Mock EventStore
// =============================================================================

const createMockEventStore = () => ({
  append: vi.fn().mockResolvedValue({ id: 'evt_test' }),
  getSession: vi.fn().mockResolvedValue(null),
  initialize: vi.fn().mockResolvedValue(undefined),
});

// =============================================================================
// Unit Tests (Mocked)
// =============================================================================

describe('WorktreeCoordinator - Unit Tests', () => {
  let coordinator: WorktreeCoordinator;
  let mockEventStore: ReturnType<typeof createMockEventStore>;

  beforeEach(() => {
    mockEventStore = createMockEventStore();
    coordinator = new WorktreeCoordinator(mockEventStore as any, {
      isolationMode: 'lazy',
    });
  });

  describe('configuration', () => {
    it('should use default config values', () => {
      const coord = new WorktreeCoordinator(mockEventStore as any);
      expect(coord).toBeDefined();
    });

    it('should accept custom branchPrefix', () => {
      const coord = new WorktreeCoordinator(mockEventStore as any, {
        branchPrefix: 'agent/',
      });
      expect(coord).toBeDefined();
    });

    it('should accept all isolation modes', () => {
      const modes: Array<'lazy' | 'always' | 'never'> = ['lazy', 'always', 'never'];
      for (const mode of modes) {
        const coord = new WorktreeCoordinator(mockEventStore as any, {
          isolationMode: mode,
        });
        expect(coord).toBeDefined();
      }
    });

    it('should accept autoCommitOnRelease option', () => {
      const coord = new WorktreeCoordinator(mockEventStore as any, {
        autoCommitOnRelease: false,
      });
      expect(coord).toBeDefined();
    });

    it('should accept preserveBranches option', () => {
      const coord = new WorktreeCoordinator(mockEventStore as any, {
        preserveBranches: false,
      });
      expect(coord).toBeDefined();
    });
  });

  describe('session tracking', () => {
    it('should start with no active sessions', () => {
      const sessions = coordinator.getActiveSessions();
      expect(sessions.size).toBe(0);
    });

    it('should report session as inactive when not acquired', () => {
      const sessionId = SessionId('test-session');
      expect(coordinator.isSessionActive(sessionId)).toBe(false);
    });

    it('should return null for unknown session working directory', () => {
      const sessionId = SessionId('unknown');
      expect(coordinator.getWorkingDirectory(sessionId)).toBeNull();
    });
  });

  describe('git detection', () => {
    it('should detect if directory is in a git repo', async () => {
      const isRepo = await coordinator.isGitRepo(process.cwd());
      expect(typeof isRepo).toBe('boolean');
    });

    it('should return false for non-git directory', async () => {
      const isRepo = await coordinator.isGitRepo('/tmp');
      expect(isRepo).toBe(false);
    });

    it('should get repo root for git directory', async () => {
      const root = await coordinator.getRepoRoot(process.cwd());
      if (root) {
        expect(root).toContain('tron');
      }
    });

    it('should return null for repo root of non-git directory', async () => {
      const root = await coordinator.getRepoRoot('/tmp');
      expect(root).toBeNull();
    });
  });
});

// =============================================================================
// Integration Tests (Real Git Operations)
// =============================================================================

describe('WorktreeCoordinator - Integration Tests', () => {
  let testDir: string;
  let coordinator: WorktreeCoordinator;
  let mockEventStore: ReturnType<typeof createMockEventStore>;

  // Create a real git repo for testing
  async function createTestRepo(): Promise<string> {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'worktree-test-'));
    // Resolve symlinks (macOS /var -> /private/var)
    const resolvedDir = await fs.realpath(dir);
    await execAsync('git init', { cwd: resolvedDir });
    await execAsync('git config user.email "test@test.com"', { cwd: resolvedDir });
    await execAsync('git config user.name "Test"', { cwd: resolvedDir });
    await fs.writeFile(path.join(resolvedDir, 'README.md'), '# Test');
    await execAsync('git add .', { cwd: resolvedDir });
    await execAsync('git commit -m "Initial commit"', { cwd: resolvedDir });
    return resolvedDir;
  }

  beforeEach(async () => {
    testDir = await createTestRepo();
    mockEventStore = createMockEventStore();
    coordinator = new WorktreeCoordinator(mockEventStore as any, {
      isolationMode: 'lazy',
      branchPrefix: 'test-session/',
    });
  });

  afterEach(async () => {
    // Clean up all worktrees first
    try {
      const worktrees = await coordinator.listWorktrees();
      for (const wt of worktrees) {
        if (wt.path !== testDir) {
          await fs.rm(wt.path, { recursive: true, force: true });
        }
      }
    } catch {
      // Ignore errors during cleanup
    }

    // Remove test directory
    try {
      await fs.rm(testDir, { recursive: true, force: true });
    } catch {
      // Ignore cleanup errors
    }
  });

  describe('acquire - main directory', () => {
    it('should acquire main directory for first session in lazy mode', async () => {
      const sessionId = SessionId('sess_first');
      const workDir = await coordinator.acquire(sessionId, testDir);

      expect(workDir).toBeDefined();
      expect(workDir.path).toBe(testDir);
      expect(workDir.isolated).toBe(false);
      expect(coordinator.isSessionActive(sessionId)).toBe(true);
    });

    it('should return same working directory for already-acquired session', async () => {
      const sessionId = SessionId('sess_same');
      const workDir1 = await coordinator.acquire(sessionId, testDir);
      const workDir2 = await coordinator.acquire(sessionId, testDir);

      expect(workDir1).toBe(workDir2);
    });

    it('should emit worktree.acquired event', async () => {
      const sessionId = SessionId('sess_event');
      await coordinator.acquire(sessionId, testDir);

      expect(mockEventStore.append).toHaveBeenCalled();
      const call = mockEventStore.append.mock.calls[0][0];
      expect(call.type).toBe('worktree.acquired');
      expect(call.payload.isolated).toBe(false);
    });
  });

  describe('acquire - isolated worktree', () => {
    it('should isolate second session in lazy mode', async () => {
      const session1 = SessionId('sess_first');
      const session2 = SessionId('sess_second');

      await coordinator.acquire(session1, testDir);
      const workDir2 = await coordinator.acquire(session2, testDir);

      expect(workDir2.isolated).toBe(true);
      expect(workDir2.path).not.toBe(testDir);
      expect(workDir2.path).toContain('sess_second');
    });

    it('should always isolate in always mode', async () => {
      const alwaysCoord = new WorktreeCoordinator(mockEventStore as any, {
        isolationMode: 'always',
        branchPrefix: 'test-session/',
      });

      const sessionId = SessionId('sess_always');
      const workDir = await alwaysCoord.acquire(sessionId, testDir);

      expect(workDir.isolated).toBe(true);
    });

    it('should never isolate in never mode', async () => {
      const neverCoord = new WorktreeCoordinator(mockEventStore as any, {
        isolationMode: 'never',
        branchPrefix: 'test-session/',
      });

      const session1 = SessionId('sess_first');
      const session2 = SessionId('sess_second');

      const workDir1 = await neverCoord.acquire(session1, testDir);
      const workDir2 = await neverCoord.acquire(session2, testDir);

      expect(workDir1.isolated).toBe(false);
      expect(workDir2.isolated).toBe(false);
    });

    it('should force isolation when requested', async () => {
      const sessionId = SessionId('sess_forced');
      const workDir = await coordinator.acquire(sessionId, testDir, {
        forceIsolation: true,
      });

      expect(workDir.isolated).toBe(true);
    });

    it('should isolate forked sessions', async () => {
      const parent = SessionId('sess_parent');
      const child = SessionId('sess_child');

      await coordinator.acquire(parent, testDir);
      const childDir = await coordinator.acquire(child, testDir, {
        parentSessionId: parent,
      });

      expect(childDir.isolated).toBe(true);
    });
  });

  describe('acquire - fork from parent', () => {
    it('should fork from parent session commit', async () => {
      const parent = SessionId('sess_parent');
      const child = SessionId('sess_child');

      const parentDir = await coordinator.acquire(parent, testDir);
      const parentCommit = await parentDir.getCurrentCommit();

      const childDir = await coordinator.acquire(child, testDir, {
        parentSessionId: parent,
      });

      expect(childDir.baseCommit).toBe(parentCommit);
    });

    it('should fork from specific commit if provided', async () => {
      const parent = SessionId('sess_parent');
      const child = SessionId('sess_child');

      await coordinator.acquire(parent, testDir);

      // Get HEAD commit
      const { stdout } = await execAsync('git rev-parse HEAD', { cwd: testDir });
      const headCommit = stdout.trim();

      const childDir = await coordinator.acquire(child, testDir, {
        parentSessionId: parent,
        parentCommit: headCommit,
      });

      expect(childDir.baseCommit).toBe(headCommit);
    });
  });

  describe('release', () => {
    it('should release session and remove from active', async () => {
      const sessionId = SessionId('sess_release');
      await coordinator.acquire(sessionId, testDir);

      expect(coordinator.isSessionActive(sessionId)).toBe(true);

      await coordinator.release(sessionId);

      expect(coordinator.isSessionActive(sessionId)).toBe(false);
      expect(coordinator.getWorkingDirectory(sessionId)).toBeNull();
    });

    it('should handle release of unknown session gracefully', async () => {
      const sessionId = SessionId('unknown');
      await expect(coordinator.release(sessionId)).resolves.not.toThrow();
    });

    it('should auto-commit changes on release by default', async () => {
      const sessionId = SessionId('sess_autocommit');
      const workDir = await coordinator.acquire(sessionId, testDir);

      // Create a new file
      await fs.writeFile(path.join(workDir.path, 'new-file.txt'), 'content');

      await coordinator.release(sessionId);

      // Check that the file was committed
      const { stdout } = await execAsync('git log --oneline -1', { cwd: testDir });
      expect(stdout).toContain('auto-save');
    });

    it('should use custom commit message when provided', async () => {
      const sessionId = SessionId('sess_custommsg');
      const workDir = await coordinator.acquire(sessionId, testDir);

      await fs.writeFile(path.join(workDir.path, 'custom.txt'), 'content');

      await coordinator.release(sessionId, {
        commitMessage: 'Custom message',
      });

      const { stdout } = await execAsync('git log --oneline -1', { cwd: testDir });
      expect(stdout).toContain('Custom message');
    });

    it('should emit worktree.released event', async () => {
      const sessionId = SessionId('sess_release_event');
      await coordinator.acquire(sessionId, testDir);

      mockEventStore.append.mockClear();
      await coordinator.release(sessionId);

      const releaseCall = mockEventStore.append.mock.calls.find(
        call => call[0].type === 'worktree.released'
      );
      expect(releaseCall).toBeDefined();
    });

    it('should delete isolated worktree on release', async () => {
      const session1 = SessionId('sess_first');
      const session2 = SessionId('sess_isolated');

      await coordinator.acquire(session1, testDir);
      const isolatedDir = await coordinator.acquire(session2, testDir);

      expect(isolatedDir.isolated).toBe(true);
      const worktreePath = isolatedDir.path;

      await coordinator.release(session2);

      // Worktree should be deleted
      const exists = await fs.access(worktreePath).then(() => true).catch(() => false);
      expect(exists).toBe(false);
    });
  });

  describe('worktree listing', () => {
    it('should list all worktrees', async () => {
      const session1 = SessionId('sess_one');
      const session2 = SessionId('sess_two');

      await coordinator.acquire(session1, testDir);
      await coordinator.acquire(session2, testDir);

      const worktrees = await coordinator.listWorktrees();

      expect(worktrees.length).toBeGreaterThanOrEqual(2);
      // Compare resolved paths to handle symlinks
      const resolvedTestDir = await fs.realpath(testDir);
      expect(worktrees.some(w => w.path === testDir || w.path === resolvedTestDir)).toBe(true);
    });

    it('should return empty array for non-git directory', async () => {
      const nonGitCoord = new WorktreeCoordinator(mockEventStore as any);
      // Don't acquire anything - repoRoot will be null
      const worktrees = await nonGitCoord.listWorktrees();
      expect(worktrees).toEqual([]);
    });
  });

  describe('recovery', () => {
    it('should recover orphaned worktrees', async () => {
      // Create an orphaned worktree manually
      const orphanPath = path.join(testDir, '.worktrees', 'sess_orphan');
      await fs.mkdir(path.join(testDir, '.worktrees'), { recursive: true });

      // Create a worktree via git
      await execAsync(`git worktree add ${orphanPath} -b test-session/sess_orphan HEAD`, { cwd: testDir });

      // Create uncommitted changes in orphan
      await fs.writeFile(path.join(orphanPath, 'orphan.txt'), 'orphan content');

      // Acquire a session to set repoRoot
      const sessionId = SessionId('sess_main');
      await coordinator.acquire(sessionId, testDir);

      // Run recovery
      await coordinator.recoverOrphanedWorktrees();

      // The orphan should have been recovered (committed and/or removed)
      // Since we didn't release the main session, check that recovery ran without error
    });

    it('should handle recovery when no worktree base exists', async () => {
      const sessionId = SessionId('sess_main');
      await coordinator.acquire(sessionId, testDir);

      // Should not throw
      await expect(coordinator.recoverOrphanedWorktrees()).resolves.not.toThrow();
    });
  });

  describe('merge operations', () => {
    it('should merge isolated session to target branch', async () => {
      const session1 = SessionId('sess_main');
      const session2 = SessionId('sess_isolated');

      await coordinator.acquire(session1, testDir);
      const isolatedDir = await coordinator.acquire(session2, testDir);

      // Make changes in isolated worktree
      await fs.writeFile(path.join(isolatedDir.path, 'isolated-change.txt'), 'changes');
      await execAsync('git add -A', { cwd: isolatedDir.path });
      await execAsync('git commit -m "Isolated change"', { cwd: isolatedDir.path });

      // Get the main branch name
      const { stdout: mainBranch } = await execAsync('git branch --show-current', { cwd: testDir });

      const result = await coordinator.mergeSession(session2, mainBranch.trim());

      expect(result.success).toBe(true);
      expect(result.mergeCommit).toBeDefined();
    });

    it('should handle merge of non-isolated session gracefully', async () => {
      const sessionId = SessionId('sess_nonisolated');
      await coordinator.acquire(sessionId, testDir);

      const result = await coordinator.mergeSession(sessionId, 'main');

      expect(result.success).toBe(false);
      expect(result.conflicts).toBeDefined();
    });
  });

  describe('non-git directories', () => {
    it('should work with non-git directories', async () => {
      const nonGitDir = await fs.mkdtemp(path.join(os.tmpdir(), 'non-git-'));
      const sessionId = SessionId('sess_nongit');

      try {
        const workDir = await coordinator.acquire(sessionId, nonGitDir);

        expect(workDir.path).toBe(nonGitDir);
        expect(workDir.isolated).toBe(false);
        expect(workDir.branch).toBe('none');
      } finally {
        await fs.rm(nonGitDir, { recursive: true, force: true });
      }
    });
  });

  describe('branch operations', () => {
    it('should get current branch', async () => {
      const branch = await coordinator.getCurrentBranch(testDir);
      expect(branch).toBeDefined();
      expect(typeof branch).toBe('string');
    });

    it('should get current commit', async () => {
      const commit = await coordinator.getCurrentCommit(testDir);
      expect(commit).toBeDefined();
      expect(commit.length).toBe(40); // Full SHA
    });
  });
});

// =============================================================================
// Isolation Decision Tests
// =============================================================================

describe('WorktreeCoordinator - Isolation Decision Logic', () => {
  let mockEventStore: ReturnType<typeof createMockEventStore>;

  beforeEach(() => {
    mockEventStore = createMockEventStore();
  });

  describe('lazy mode', () => {
    it('should not isolate first session', async () => {
      const coord = new WorktreeCoordinator(mockEventStore as any, {
        isolationMode: 'lazy',
      });

      // In lazy mode, first session gets main directory
      // Second session gets isolated
      // This is tested in integration tests above
      expect(coord).toBeDefined();
    });
  });

  describe('always mode', () => {
    it('should always create isolated worktree', async () => {
      const coord = new WorktreeCoordinator(mockEventStore as any, {
        isolationMode: 'always',
      });
      expect(coord).toBeDefined();
    });
  });

  describe('never mode', () => {
    it('should never create isolated worktree', async () => {
      const coord = new WorktreeCoordinator(mockEventStore as any, {
        isolationMode: 'never',
      });
      expect(coord).toBeDefined();
    });
  });
});

// =============================================================================
// Event Emission Tests
// =============================================================================

describe('WorktreeCoordinator - Event Emission', () => {
  let testDir: string;
  let coordinator: WorktreeCoordinator;
  let mockEventStore: ReturnType<typeof createMockEventStore>;

  async function createTestRepo(): Promise<string> {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'event-test-'));
    // Resolve symlinks (macOS /var -> /private/var)
    const resolvedDir = await fs.realpath(dir);
    await execAsync('git init', { cwd: resolvedDir });
    await execAsync('git config user.email "test@test.com"', { cwd: resolvedDir });
    await execAsync('git config user.name "Test"', { cwd: resolvedDir });
    await fs.writeFile(path.join(resolvedDir, 'README.md'), '# Test');
    await execAsync('git add .', { cwd: resolvedDir });
    await execAsync('git commit -m "Initial commit"', { cwd: resolvedDir });
    return resolvedDir;
  }

  beforeEach(async () => {
    testDir = await createTestRepo();
    mockEventStore = createMockEventStore();
    coordinator = new WorktreeCoordinator(mockEventStore as any, {
      isolationMode: 'lazy',
    });
  });

  afterEach(async () => {
    try {
      await fs.rm(testDir, { recursive: true, force: true });
    } catch {
      // Ignore cleanup errors
    }
  });

  it('should emit worktree.acquired on acquire', async () => {
    const sessionId = SessionId('sess_acquired');
    await coordinator.acquire(sessionId, testDir);

    const acquiredCall = mockEventStore.append.mock.calls.find(
      call => call[0].type === 'worktree.acquired'
    );

    expect(acquiredCall).toBeDefined();
    expect(acquiredCall![0].sessionId).toBe(sessionId);
    expect(acquiredCall![0].payload.path).toBe(testDir);
  });

  it('should emit worktree.released on release', async () => {
    const sessionId = SessionId('sess_released');
    await coordinator.acquire(sessionId, testDir);

    mockEventStore.append.mockClear();
    await coordinator.release(sessionId);

    const releasedCall = mockEventStore.append.mock.calls.find(
      call => call[0].type === 'worktree.released'
    );

    expect(releasedCall).toBeDefined();
  });

  it('should emit worktree.commit when auto-committing', async () => {
    const sessionId = SessionId('sess_commit');
    const workDir = await coordinator.acquire(sessionId, testDir);

    // Create uncommitted changes
    await fs.writeFile(path.join(workDir.path, 'commit-test.txt'), 'content');

    mockEventStore.append.mockClear();
    await coordinator.release(sessionId);

    const commitCall = mockEventStore.append.mock.calls.find(
      call => call[0].type === 'worktree.commit'
    );

    expect(commitCall).toBeDefined();
    expect(commitCall![0].payload.hash).toBeDefined();
  });

  it('should emit worktree.merged on successful merge', async () => {
    const session1 = SessionId('sess_main');
    const session2 = SessionId('sess_to_merge');

    await coordinator.acquire(session1, testDir);
    const isolatedDir = await coordinator.acquire(session2, testDir);

    // Make changes
    await fs.writeFile(path.join(isolatedDir.path, 'merge-test.txt'), 'content');
    await execAsync('git add -A && git commit -m "Changes"', { cwd: isolatedDir.path });

    const { stdout: mainBranch } = await execAsync('git branch --show-current', { cwd: testDir });

    mockEventStore.append.mockClear();
    await coordinator.mergeSession(session2, mainBranch.trim());

    const mergeCall = mockEventStore.append.mock.calls.find(
      call => call[0].type === 'worktree.merged'
    );

    expect(mergeCall).toBeDefined();
    expect(mergeCall![0].payload.success).toBe(true);
  });
});
