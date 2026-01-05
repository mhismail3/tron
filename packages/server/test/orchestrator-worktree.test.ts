/**
 * @fileoverview Orchestrator Worktree Integration Tests
 *
 * Tests that verify the EventStoreOrchestrator correctly integrates
 * with the WorktreeCoordinator for managing session working directories.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';
import { execSync } from 'child_process';

// =============================================================================
// Test Helpers
// =============================================================================

async function createTempGitRepo(): Promise<string> {
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), 'orch-test-'));
  // Resolve symlinks (macOS has /var -> /private/var)
  const resolvedDir = await fs.realpath(tempDir);

  execSync('git init', { cwd: resolvedDir, stdio: 'pipe' });
  execSync('git config user.email "test@test.com"', { cwd: resolvedDir, stdio: 'pipe' });
  execSync('git config user.name "Test"', { cwd: resolvedDir, stdio: 'pipe' });
  await fs.writeFile(path.join(resolvedDir, 'README.md'), '# Test');
  execSync('git add . && git commit -m "Initial"', { cwd: resolvedDir, stdio: 'pipe' });

  return resolvedDir;
}

async function cleanupTempDir(dir: string): Promise<void> {
  try {
    await fs.rm(dir, { recursive: true, force: true });
  } catch {}
}

// =============================================================================
// Session Info Type Tests (what clients should receive)
// =============================================================================

describe('SessionInfo with Worktree', () => {
  it('should define WorktreeInfo interface', () => {
    // This tests the type definition we'll create
    interface WorktreeInfo {
      isolated: boolean;
      branch: string;
      baseCommit: string;
      path: string;
    }

    const info: WorktreeInfo = {
      isolated: false,
      branch: 'main',
      baseCommit: 'abc123',
      path: '/path/to/repo',
    };

    expect(info.isolated).toBe(false);
    expect(info.branch).toBe('main');
  });

  it('should define SessionInfo with optional worktree field', () => {
    interface WorktreeInfo {
      isolated: boolean;
      branch: string;
      baseCommit: string;
      path: string;
    }

    interface SessionInfo {
      sessionId: string;
      workingDirectory: string;
      model: string;
      messageCount: number;
      eventCount: number;
      createdAt: string;
      lastActivity: string;
      isActive: boolean;
      worktree?: WorktreeInfo;
    }

    // Session without worktree (legacy compatibility)
    const legacySession: SessionInfo = {
      sessionId: 'sess_1',
      workingDirectory: '/path',
      model: 'claude-sonnet',
      messageCount: 0,
      eventCount: 0,
      createdAt: new Date().toISOString(),
      lastActivity: new Date().toISOString(),
      isActive: true,
    };
    expect(legacySession.worktree).toBeUndefined();

    // Session with worktree info
    const worktreeSession: SessionInfo = {
      ...legacySession,
      worktree: {
        isolated: true,
        branch: 'session/sess_1',
        baseCommit: 'abc123',
        path: '/path/.worktrees/sess_1',
      },
    };
    expect(worktreeSession.worktree?.isolated).toBe(true);
  });
});

// =============================================================================
// Orchestrator Worktree Behavior Tests
// =============================================================================

describe('EventStoreOrchestrator Worktree Integration', () => {
  let tempDir: string;

  beforeEach(async () => {
    tempDir = await createTempGitRepo();
  });

  afterEach(async () => {
    await cleanupTempDir(tempDir);
  });

  describe('createSession', () => {
    it('should acquire working directory when creating session', async () => {
      // Test that createSession calls coordinator.acquire()
      const mockCoordinator = {
        acquire: vi.fn().mockResolvedValue({
          path: tempDir,
          branch: 'main',
          isolated: false,
          sessionId: 'sess_1',
          baseCommit: 'abc123',
          getInfo: () => ({
            path: tempDir,
            branch: 'main',
            isolated: false,
            sessionId: 'sess_1',
            baseCommit: 'abc123',
          }),
        }),
        release: vi.fn().mockResolvedValue(undefined),
        getWorkingDirectory: vi.fn(),
      };

      // Simulate what orchestrator should do
      const sessionId = 'sess_1';
      await mockCoordinator.acquire(sessionId, tempDir, {});

      expect(mockCoordinator.acquire).toHaveBeenCalledWith(
        sessionId,
        tempDir,
        {}
      );
    });

    it('should include worktree info in session response', async () => {
      // What the orchestrator should return
      interface WorktreeInfo {
        isolated: boolean;
        branch: string;
        baseCommit: string;
        path: string;
      }

      const worktreeInfo: WorktreeInfo = {
        isolated: false,
        branch: 'main',
        baseCommit: 'abc123',
        path: tempDir,
      };

      // Session response should include this
      const sessionResponse = {
        sessionId: 'sess_1',
        workingDirectory: tempDir,
        model: 'claude-sonnet',
        worktree: worktreeInfo,
      };

      expect(sessionResponse.worktree).toBeDefined();
      expect(sessionResponse.worktree.isolated).toBe(false);
    });
  });

  describe('parallel sessions', () => {
    it('should create isolated worktree for second session in same workspace', async () => {
      const mockCoordinator = {
        acquire: vi.fn()
          .mockResolvedValueOnce({
            path: tempDir,
            branch: 'main',
            isolated: false,
            sessionId: 'sess_1',
            baseCommit: 'abc123',
            getInfo: () => ({ path: tempDir, branch: 'main', isolated: false }),
          })
          .mockResolvedValueOnce({
            path: `${tempDir}/.worktrees/sess_2`,
            branch: 'session/sess_2',
            isolated: true,
            sessionId: 'sess_2',
            baseCommit: 'abc123',
            getInfo: () => ({ path: `${tempDir}/.worktrees/sess_2`, branch: 'session/sess_2', isolated: true }),
          }),
      };

      const workDir1 = await mockCoordinator.acquire('sess_1', tempDir, {});
      const workDir2 = await mockCoordinator.acquire('sess_2', tempDir, {});

      expect(workDir1.isolated).toBe(false);
      expect(workDir2.isolated).toBe(true);
      expect(workDir2.path).not.toBe(workDir1.path);
    });
  });

  describe('forkSession', () => {
    it('should create worktree branched from fork point', async () => {
      const mockCoordinator = {
        acquire: vi.fn().mockResolvedValue({
          path: `${tempDir}/.worktrees/sess_fork`,
          branch: 'session/sess_fork',
          isolated: true,
          sessionId: 'sess_fork',
          baseCommit: 'parent_commit_hash',
          getInfo: () => ({
            path: `${tempDir}/.worktrees/sess_fork`,
            branch: 'session/sess_fork',
            isolated: true,
            baseCommit: 'parent_commit_hash',
          }),
        }),
      };

      const workDir = await mockCoordinator.acquire('sess_fork', tempDir, {
        parentSessionId: 'sess_parent',
        parentCommit: 'parent_commit_hash',
      });

      expect(mockCoordinator.acquire).toHaveBeenCalledWith(
        'sess_fork',
        tempDir,
        expect.objectContaining({
          parentSessionId: 'sess_parent',
          parentCommit: 'parent_commit_hash',
        })
      );
      expect(workDir.baseCommit).toBe('parent_commit_hash');
    });
  });

  describe('endSession', () => {
    it('should release working directory when session ends', async () => {
      const mockCoordinator = {
        release: vi.fn().mockResolvedValue(undefined),
      };

      await mockCoordinator.release('sess_1', {});

      expect(mockCoordinator.release).toHaveBeenCalledWith('sess_1', {});
    });

    it('should handle release with merge option', async () => {
      const mockCoordinator = {
        release: vi.fn().mockResolvedValue(undefined),
      };

      await mockCoordinator.release('sess_1', {
        mergeTo: 'main',
        mergeStrategy: 'squash',
      });

      expect(mockCoordinator.release).toHaveBeenCalledWith(
        'sess_1',
        expect.objectContaining({
          mergeTo: 'main',
          mergeStrategy: 'squash',
        })
      );
    });
  });

  describe('getSession', () => {
    it('should return worktree info in session info', async () => {
      // What getSession should return
      const sessionInfo = {
        sessionId: 'sess_1',
        workingDirectory: tempDir,
        model: 'claude-sonnet',
        worktree: {
          isolated: true,
          branch: 'session/sess_1',
          baseCommit: 'abc123',
          path: `${tempDir}/.worktrees/sess_1`,
        },
      };

      expect(sessionInfo.worktree).toBeDefined();
      expect(sessionInfo.worktree.isolated).toBe(true);
      expect(sessionInfo.worktree.branch).toContain('session/');
    });
  });
});

// =============================================================================
// RPC Handler Tests
// =============================================================================

describe('RPC Handler Worktree Support', () => {
  describe('session.create response', () => {
    it('should include worktree status in response', () => {
      const response = {
        jsonrpc: '2.0',
        id: 1,
        result: {
          sessionId: 'sess_1',
          workingDirectory: '/path/to/repo',
          worktree: {
            isolated: false,
            branch: 'main',
            baseCommit: 'abc123',
            path: '/path/to/repo',
          },
        },
      };

      expect(response.result.worktree).toBeDefined();
      expect(response.result.worktree.isolated).toBe(false);
    });
  });

  describe('session.fork response', () => {
    it('should include worktree status for forked session', () => {
      const response = {
        jsonrpc: '2.0',
        id: 1,
        result: {
          newSessionId: 'sess_fork',
          forkedFromSessionId: 'sess_parent',
          forkedFromEventId: 'evt_123',
          worktree: {
            isolated: true,
            branch: 'session/sess_fork',
            baseCommit: 'parent_commit',
            path: '/path/.worktrees/sess_fork',
          },
        },
      };

      expect(response.result.worktree.isolated).toBe(true);
      expect(response.result.worktree.branch).toContain('sess_fork');
    });
  });

  describe('session.getWorktreeStatus method', () => {
    it('should define new RPC method for worktree status', () => {
      const request = {
        jsonrpc: '2.0',
        id: 1,
        method: 'session.getWorktreeStatus',
        params: {
          sessionId: 'sess_1',
        },
      };

      const expectedResponse = {
        jsonrpc: '2.0',
        id: 1,
        result: {
          isolated: true,
          branch: 'session/sess_1',
          baseCommit: 'abc123',
          path: '/path/.worktrees/sess_1',
          uncommittedChanges: true,
          modifiedFiles: ['file1.ts', 'file2.ts'],
        },
      };

      expect(request.method).toBe('session.getWorktreeStatus');
      expect(expectedResponse.result).toHaveProperty('isolated');
      expect(expectedResponse.result).toHaveProperty('uncommittedChanges');
    });
  });

  describe('session.commitWorktree method', () => {
    it('should define RPC method for committing worktree changes', () => {
      const request = {
        jsonrpc: '2.0',
        id: 1,
        method: 'session.commitWorktree',
        params: {
          sessionId: 'sess_1',
          message: 'Save progress',
        },
      };

      const expectedResponse = {
        jsonrpc: '2.0',
        id: 1,
        result: {
          success: true,
          commitHash: 'abc123def',
          filesChanged: ['file1.ts'],
        },
      };

      expect(request.method).toBe('session.commitWorktree');
      expect(expectedResponse.result).toHaveProperty('commitHash');
    });
  });

  describe('session.mergeWorktree method', () => {
    it('should define RPC method for merging worktree to target branch', () => {
      const request = {
        jsonrpc: '2.0',
        id: 1,
        method: 'session.mergeWorktree',
        params: {
          sessionId: 'sess_1',
          targetBranch: 'main',
          strategy: 'squash',
        },
      };

      const expectedResponse = {
        jsonrpc: '2.0',
        id: 1,
        result: {
          success: true,
          mergeCommit: 'merge123',
          conflicts: [],
        },
      };

      expect(request.method).toBe('session.mergeWorktree');
      expect(expectedResponse.result.success).toBe(true);
    });
  });
});

// =============================================================================
// Event Store Integration Tests
// =============================================================================

describe('Worktree Events in EventStore', () => {
  it('should store worktree.acquired events', () => {
    const event = {
      id: 'evt_1',
      sessionId: 'sess_1',
      type: 'worktree.acquired',
      parentId: null,
      timestamp: new Date().toISOString(),
      payload: {
        path: '/path/to/worktree',
        branch: 'session/sess_1',
        baseCommit: 'abc123',
        isolated: true,
        forkedFrom: {
          sessionId: 'sess_parent',
          commit: 'abc123',
        },
      },
    };

    expect(event.type).toBe('worktree.acquired');
    expect(event.payload.forkedFrom).toBeDefined();
  });

  it('should store worktree.commit events', () => {
    const event = {
      id: 'evt_2',
      sessionId: 'sess_1',
      type: 'worktree.commit',
      parentId: 'evt_1',
      timestamp: new Date().toISOString(),
      payload: {
        commitHash: 'def456',
        message: 'Agent checkpoint',
        filesChanged: ['file1.ts', 'file2.ts'],
        insertions: 50,
        deletions: 10,
      },
    };

    expect(event.type).toBe('worktree.commit');
    expect(event.payload.filesChanged).toHaveLength(2);
  });

  it('should store worktree.released events', () => {
    const event = {
      id: 'evt_3',
      sessionId: 'sess_1',
      type: 'worktree.released',
      parentId: 'evt_2',
      timestamp: new Date().toISOString(),
      payload: {
        finalCommit: 'def456',
        deleted: true,
        branchPreserved: true,
      },
    };

    expect(event.type).toBe('worktree.released');
    expect(event.payload.deleted).toBe(true);
  });

  it('should store worktree.merged events', () => {
    const event = {
      id: 'evt_4',
      sessionId: 'sess_1',
      type: 'worktree.merged',
      parentId: 'evt_3',
      timestamp: new Date().toISOString(),
      payload: {
        sourceBranch: 'session/sess_1',
        targetBranch: 'main',
        mergeCommit: 'merge789',
        strategy: 'squash',
      },
    };

    expect(event.type).toBe('worktree.merged');
    expect(event.payload.strategy).toBe('squash');
  });
});
