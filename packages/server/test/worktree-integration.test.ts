/**
 * @fileoverview Worktree Integration Tests
 *
 * TDD tests for worktree integration with the event session system.
 * These tests verify:
 * 1. Sessions acquire working directories correctly
 * 2. Parallel sessions get isolated worktrees
 * 3. Forked sessions branch from parent's commit
 * 4. Worktree info is included in session responses
 * 5. Events are emitted for worktree operations
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';
import { execSync } from 'child_process';
import {
  EventStore,
  WorktreeCoordinator,
  createWorktreeCoordinator,
  type SessionId,
} from '@tron/core';

// =============================================================================
// Test Helpers
// =============================================================================

async function createTempGitRepo(): Promise<string> {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), 'worktree-test-'));
  // Resolve symlinks (macOS has /var -> /private/var)
  const resolvedDir = await fs.realpath(tempDir);

  // Initialize git repo
  execSync('git init', { cwd: resolvedDir, stdio: 'pipe' });
  execSync('git config user.email "test@test.com"', { cwd: resolvedDir, stdio: 'pipe' });
  execSync('git config user.name "Test"', { cwd: resolvedDir, stdio: 'pipe' });

  // Create initial commit
  await fs.writeFile(path.join(resolvedDir, 'README.md'), '# Test Repo');
  execSync('git add .', { cwd: resolvedDir, stdio: 'pipe' });
  execSync('git commit -m "Initial commit"', { cwd: resolvedDir, stdio: 'pipe' });

  return resolvedDir;
}

async function cleanupTempDir(dir: string): Promise<void> {
  try {
    await fs.rm(dir, { recursive: true, force: true });
  } catch {
    // Ignore cleanup errors
  }
}

function createMockEventStore() {
  const events: Array<{ sessionId: string; type: string; payload: unknown }> = [];

  return {
    events,
    append: vi.fn().mockImplementation(async (opts) => {
      events.push({
        sessionId: opts.sessionId,
        type: opts.type,
        payload: opts.payload,
      });
      return { id: `evt_${Date.now()}` };
    }),
    getSession: vi.fn().mockResolvedValue(null),
    initialize: vi.fn().mockResolvedValue(undefined),
    createSession: vi.fn().mockImplementation(async (opts) => ({
      session: {
        id: `sess_${Date.now()}` as SessionId,
        workingDirectory: opts.workingDirectory,
        model: opts.model,
      },
      rootEvent: { id: `evt_${Date.now()}` },
    })),
    close: vi.fn().mockResolvedValue(undefined),
  };
}

// =============================================================================
// WorktreeCoordinator Unit Tests
// =============================================================================

describe('WorktreeCoordinator', () => {
  let tempDir: string;
  let mockEventStore: ReturnType<typeof createMockEventStore>;
  let coordinator: WorktreeCoordinator;

  beforeEach(async () => {
    tempDir = await createTempGitRepo();
    mockEventStore = createMockEventStore();
    coordinator = createWorktreeCoordinator(mockEventStore as any, {
      isolationMode: 'lazy',
      branchPrefix: 'test/',
      autoCommitOnRelease: false,
      deleteWorktreeOnRelease: true,
    });
  });

  afterEach(async () => {
    // Release all active sessions
    for (const [sessionId] of coordinator.getActiveSessions()) {
      try {
        await coordinator.release(sessionId as SessionId, { force: true });
      } catch {
        // Ignore release errors in cleanup
      }
    }
    await cleanupTempDir(tempDir);
  });

  describe('acquire - first session', () => {
    it('should acquire main directory for first session', async () => {
      const sessionId = 'sess_first' as SessionId;

      const workDir = await coordinator.acquire(sessionId, tempDir);

      expect(workDir).toBeDefined();
      expect(workDir.path).toBe(tempDir);
      expect(workDir.isolated).toBe(false);
      expect(workDir.sessionId).toBe(sessionId);
    });

    it('should emit worktree.acquired event', async () => {
      const sessionId = 'sess_first' as SessionId;

      await coordinator.acquire(sessionId, tempDir);

      const acquiredEvent = mockEventStore.events.find(e => e.type === 'worktree.acquired');
      expect(acquiredEvent).toBeDefined();
      expect(acquiredEvent?.payload).toMatchObject({
        path: tempDir,
        isolated: false,
      });
    });

    it('should return existing working directory if already acquired', async () => {
      const sessionId = 'sess_first' as SessionId;

      const workDir1 = await coordinator.acquire(sessionId, tempDir);
      const workDir2 = await coordinator.acquire(sessionId, tempDir);

      expect(workDir1).toBe(workDir2);
    });
  });

  describe('acquire - parallel sessions', () => {
    it('should create isolated worktree for second session', async () => {
      const session1 = 'sess_first' as SessionId;
      const session2 = 'sess_second' as SessionId;

      const workDir1 = await coordinator.acquire(session1, tempDir);
      const workDir2 = await coordinator.acquire(session2, tempDir);

      expect(workDir1.isolated).toBe(false);
      expect(workDir2.isolated).toBe(true);
      expect(workDir2.path).not.toBe(workDir1.path);
      expect(workDir2.branch).toContain('test/');
    });

    it('should create unique worktrees for each parallel session', async () => {
      const session1 = 'sess_1' as SessionId;
      const session2 = 'sess_2' as SessionId;
      const session3 = 'sess_3' as SessionId;

      const workDir1 = await coordinator.acquire(session1, tempDir);
      const workDir2 = await coordinator.acquire(session2, tempDir);
      const workDir3 = await coordinator.acquire(session3, tempDir);

      const paths = [workDir1.path, workDir2.path, workDir3.path];
      const uniquePaths = new Set(paths);
      expect(uniquePaths.size).toBe(3);
    });

    it('should emit events for each parallel session', async () => {
      const session1 = 'sess_1' as SessionId;
      const session2 = 'sess_2' as SessionId;

      await coordinator.acquire(session1, tempDir);
      await coordinator.acquire(session2, tempDir);

      const acquiredEvents = mockEventStore.events.filter(e => e.type === 'worktree.acquired');
      expect(acquiredEvents).toHaveLength(2);
    });
  });

  describe('acquire - forked sessions', () => {
    it('should create worktree branched from parent commit', async () => {
      const parentSession = 'sess_parent' as SessionId;
      const childSession = 'sess_child' as SessionId;

      const parentWorkDir = await coordinator.acquire(parentSession, tempDir);

      // Make a change in parent
      await fs.writeFile(path.join(parentWorkDir.path, 'parent-file.txt'), 'parent');
      execSync('git add . && git commit -m "Parent commit"', {
        cwd: parentWorkDir.path,
        stdio: 'pipe'
      });

      const parentCommit = await parentWorkDir.getCurrentCommit();

      // Fork from parent
      const childWorkDir = await coordinator.acquire(childSession, tempDir, {
        parentSessionId: parentSession,
        parentCommit,
      });

      expect(childWorkDir.isolated).toBe(true);
      expect(childWorkDir.baseCommit).toBe(parentCommit);
    });

    it('should include forkedFrom in acquired event', async () => {
      const parentSession = 'sess_parent' as SessionId;
      const childSession = 'sess_child' as SessionId;

      await coordinator.acquire(parentSession, tempDir);
      await coordinator.acquire(childSession, tempDir, {
        parentSessionId: parentSession,
      });

      const childAcquiredEvent = mockEventStore.events.find(
        e => e.type === 'worktree.acquired' && e.sessionId === childSession
      );
      expect(childAcquiredEvent?.payload).toHaveProperty('forkedFrom');
    });
  });

  describe('acquire - isolation modes', () => {
    it('should always use main directory in never mode', async () => {
      const neverCoordinator = createWorktreeCoordinator(mockEventStore as any, {
        isolationMode: 'never',
      });

      const session1 = 'sess_1' as SessionId;
      const session2 = 'sess_2' as SessionId;

      const workDir1 = await neverCoordinator.acquire(session1, tempDir);
      const workDir2 = await neverCoordinator.acquire(session2, tempDir);

      expect(workDir1.isolated).toBe(false);
      expect(workDir2.isolated).toBe(false);
      expect(workDir1.path).toBe(workDir2.path);
    });

    it('should always isolate in always mode', async () => {
      const alwaysCoordinator = createWorktreeCoordinator(mockEventStore as any, {
        isolationMode: 'always',
      });

      const session1 = 'sess_1' as SessionId;

      const workDir1 = await alwaysCoordinator.acquire(session1, tempDir);

      expect(workDir1.isolated).toBe(true);

      // Cleanup
      await alwaysCoordinator.release(session1, { force: true });
    });

    it('should respect forceIsolation option', async () => {
      const session1 = 'sess_1' as SessionId;

      const workDir1 = await coordinator.acquire(session1, tempDir, {
        forceIsolation: true,
      });

      expect(workDir1.isolated).toBe(true);
    });
  });

  describe('release', () => {
    it('should release main directory and allow reacquisition', async () => {
      const session1 = 'sess_1' as SessionId;
      const session2 = 'sess_2' as SessionId;

      await coordinator.acquire(session1, tempDir);
      await coordinator.release(session1);

      // Session 2 should now get main directory
      const workDir2 = await coordinator.acquire(session2, tempDir);
      expect(workDir2.isolated).toBe(false);
      expect(workDir2.path).toBe(tempDir);
    });

    it('should emit worktree.released event', async () => {
      const sessionId = 'sess_1' as SessionId;

      await coordinator.acquire(sessionId, tempDir);
      await coordinator.release(sessionId);

      const releasedEvent = mockEventStore.events.find(e => e.type === 'worktree.released');
      expect(releasedEvent).toBeDefined();
      expect(releasedEvent?.sessionId).toBe(sessionId);
    });

    it('should remove worktree directory when isolated', async () => {
      const session1 = 'sess_1' as SessionId;
      const session2 = 'sess_2' as SessionId;

      await coordinator.acquire(session1, tempDir);
      const workDir2 = await coordinator.acquire(session2, tempDir);
      const isolatedPath = workDir2.path;

      await coordinator.release(session2);

      // Check directory is removed
      await expect(fs.access(isolatedPath)).rejects.toThrow();
    });

    it('should auto-commit changes if configured', async () => {
      const autoCommitCoordinator = createWorktreeCoordinator(mockEventStore as any, {
        isolationMode: 'always',
        autoCommitOnRelease: true,
        deleteWorktreeOnRelease: true,
      });

      const sessionId = 'sess_1' as SessionId;
      const workDir = await autoCommitCoordinator.acquire(sessionId, tempDir);

      // Make uncommitted changes
      await fs.writeFile(path.join(workDir.path, 'new-file.txt'), 'content');

      await autoCommitCoordinator.release(sessionId);

      const commitEvent = mockEventStore.events.find(e => e.type === 'worktree.commit');
      expect(commitEvent).toBeDefined();
    });
  });

  describe('getWorkingDirectory', () => {
    it('should return working directory for active session', async () => {
      const sessionId = 'sess_1' as SessionId;
      const acquiredWorkDir = await coordinator.acquire(sessionId, tempDir);

      const retrievedWorkDir = coordinator.getWorkingDirectory(sessionId);

      expect(retrievedWorkDir).toBe(acquiredWorkDir);
    });

    it('should return null for unknown session', () => {
      const workDir = coordinator.getWorkingDirectory('unknown' as SessionId);
      expect(workDir).toBeNull();
    });

    it('should return null after session is released', async () => {
      const sessionId = 'sess_1' as SessionId;
      await coordinator.acquire(sessionId, tempDir);
      await coordinator.release(sessionId);

      const workDir = coordinator.getWorkingDirectory(sessionId);
      expect(workDir).toBeNull();
    });
  });

  describe('non-git directories', () => {
    it('should handle non-git directories gracefully', async () => {
      const nonGitDir = await fs.mkdtemp(path.join(os.tmpdir(), 'non-git-'));
      const sessionId = 'sess_1' as SessionId;

      try {
        const workDir = await coordinator.acquire(sessionId, nonGitDir);

        expect(workDir.path).toBe(nonGitDir);
        expect(workDir.branch).toBe('none');
        expect(workDir.isolated).toBe(false);
      } finally {
        await cleanupTempDir(nonGitDir);
      }
    });
  });

  describe('recovery', () => {
    it('should list all worktrees', async () => {
      const session1 = 'sess_1' as SessionId;
      const session2 = 'sess_2' as SessionId;

      await coordinator.acquire(session1, tempDir);
      await coordinator.acquire(session2, tempDir);

      const worktrees = await coordinator.listWorktrees();

      expect(worktrees.length).toBeGreaterThanOrEqual(2);
    });
  });
});

// =============================================================================
// WorkingDirectory Tests
// =============================================================================

describe('WorkingDirectory', () => {
  let tempDir: string;
  let mockEventStore: ReturnType<typeof createMockEventStore>;
  let coordinator: WorktreeCoordinator;

  beforeEach(async () => {
    tempDir = await createTempGitRepo();
    mockEventStore = createMockEventStore();
    coordinator = createWorktreeCoordinator(mockEventStore as any, {
      isolationMode: 'lazy',
    });
  });

  afterEach(async () => {
    for (const [sessionId] of coordinator.getActiveSessions()) {
      try {
        await coordinator.release(sessionId as SessionId, { force: true });
      } catch {}
    }
    await cleanupTempDir(tempDir);
  });

  describe('git operations', () => {
    it('should get current status', async () => {
      const sessionId = 'sess_1' as SessionId;
      const workDir = await coordinator.acquire(sessionId, tempDir);

      const status = await workDir.getStatus();

      expect(status).toHaveProperty('filesChanged');
      expect(status).toHaveProperty('isDirty');
      expect(status).toHaveProperty('branch');
      expect(status).toHaveProperty('commit');
    });

    it('should detect uncommitted changes', async () => {
      const sessionId = 'sess_1' as SessionId;
      const workDir = await coordinator.acquire(sessionId, tempDir);

      // Initially clean
      expect(await workDir.hasUncommittedChanges()).toBe(false);

      // Make a change
      await fs.writeFile(path.join(workDir.path, 'new-file.txt'), 'content');

      expect(await workDir.hasUncommittedChanges()).toBe(true);
    });

    it('should commit changes', async () => {
      const sessionId = 'sess_1' as SessionId;
      const workDir = await coordinator.acquire(sessionId, tempDir);

      await fs.writeFile(path.join(workDir.path, 'new-file.txt'), 'content');

      const result = await workDir.commit('Test commit', { addAll: true });

      expect(result).not.toBeNull();
      expect(result?.hash).toBeDefined();
      expect(result?.filesChanged).toContain('new-file.txt');
    });

    it('should get diff from base commit', async () => {
      const sessionId = 'sess_1' as SessionId;
      const workDir = await coordinator.acquire(sessionId, tempDir);

      await fs.writeFile(path.join(workDir.path, 'new-file.txt'), 'content');
      await workDir.commit('Test commit', { addAll: true });

      const diff = await workDir.getDiff();

      expect(diff).toContain('new-file.txt');
    });
  });

  describe('file modification tracking', () => {
    it('should track modifications', async () => {
      const sessionId = 'sess_1' as SessionId;
      const workDir = await coordinator.acquire(sessionId, tempDir);

      workDir.recordModification('file1.ts', 'create');
      workDir.recordModification('file2.ts', 'modify');

      const mods = workDir.getModifications();
      expect(mods).toHaveLength(2);
      expect(mods[0]).toMatchObject({ path: 'file1.ts', operation: 'create' });
    });

    it('should clear modifications after commit', async () => {
      const sessionId = 'sess_1' as SessionId;
      const workDir = await coordinator.acquire(sessionId, tempDir);

      await fs.writeFile(path.join(workDir.path, 'new-file.txt'), 'content');
      workDir.recordModification('new-file.txt', 'create');

      expect(workDir.getModifications()).toHaveLength(1);

      await workDir.commit('Test commit', { addAll: true });

      expect(workDir.getModifications()).toHaveLength(0);
    });
  });
});

// =============================================================================
// Event Recording Tests
// =============================================================================

describe('Worktree Event Recording', () => {
  let tempDir: string;
  let mockEventStore: ReturnType<typeof createMockEventStore>;
  let coordinator: WorktreeCoordinator;

  beforeEach(async () => {
    tempDir = await createTempGitRepo();
    mockEventStore = createMockEventStore();
    coordinator = createWorktreeCoordinator(mockEventStore as any, {
      isolationMode: 'lazy',
      autoCommitOnRelease: true,
    });
  });

  afterEach(async () => {
    for (const [sessionId] of coordinator.getActiveSessions()) {
      try {
        await coordinator.release(sessionId as SessionId, { force: true });
      } catch {}
    }
    await cleanupTempDir(tempDir);
  });

  it('should record complete lifecycle in events', async () => {
    const sessionId = 'sess_lifecycle' as SessionId;

    // Acquire
    const workDir = await coordinator.acquire(sessionId, tempDir);

    // Make changes and commit
    await fs.writeFile(path.join(workDir.path, 'lifecycle.txt'), 'test');
    await workDir.commit('Lifecycle test', { addAll: true });

    // Release
    await coordinator.release(sessionId);

    // Verify event sequence
    const eventTypes = mockEventStore.events.map(e => e.type);
    expect(eventTypes).toContain('worktree.acquired');
    expect(eventTypes).toContain('worktree.released');
  });

  it('should include correct metadata in events', async () => {
    const sessionId = 'sess_meta' as SessionId;

    await coordinator.acquire(sessionId, tempDir);

    const acquiredEvent = mockEventStore.events.find(e => e.type === 'worktree.acquired');
    expect(acquiredEvent?.payload).toMatchObject({
      path: expect.any(String),
      branch: expect.any(String),
      baseCommit: expect.any(String),
      isolated: expect.any(Boolean),
    });
  });
});
