/**
 * @fileoverview Tests for Filesystem RPC Handlers
 *
 * Tests filesystem.listDir, filesystem.getHome, and filesystem.createDir handlers
 * using the registry dispatch pattern.
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';
import { createFilesystemHandlers } from '../filesystem.handler.js';
import type { RpcRequest } from '../../types.js';
import type { RpcContext } from '../../handler.js';
import { MethodRegistry } from '../../registry.js';

describe('Filesystem Handlers', () => {
  let registry: MethodRegistry;
  let mockContext: RpcContext;
  let testDir: string;

  beforeEach(async () => {
    registry = new MethodRegistry();
    registry.registerAll(createFilesystemHandlers());

    mockContext = {
      sessionManager: {} as any,
      agentManager: {} as any,
      memoryStore: {} as any,
    };

    // Create a temp directory for testing
    testDir = path.join(os.tmpdir(), `fs-handler-test-${Date.now()}`);
    await fs.mkdir(testDir, { recursive: true });
  });

  afterEach(async () => {
    // Clean up test directory
    try {
      await fs.rm(testDir, { recursive: true, force: true });
    } catch {
      // Ignore cleanup errors
    }
  });

  describe('filesystem.listDir', () => {
    it('should list directory contents', async () => {
      // Create test files
      await fs.writeFile(path.join(testDir, 'file1.txt'), 'content');
      await fs.writeFile(path.join(testDir, 'file2.txt'), 'content');
      await fs.mkdir(path.join(testDir, 'subdir'));

      const request: RpcRequest = {
        id: '1',
        method: 'filesystem.listDir',
        params: { path: testDir },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      const result = response.result as { path: string; entries: any[] };
      expect(result.path).toBe(testDir);
      expect(result.entries).toHaveLength(3);

      // Check that directories come first
      expect(result.entries[0].name).toBe('subdir');
      expect(result.entries[0].isDirectory).toBe(true);
    });

    it('should filter hidden files by default', async () => {
      await fs.writeFile(path.join(testDir, '.hidden'), 'content');
      await fs.writeFile(path.join(testDir, 'visible.txt'), 'content');

      const request: RpcRequest = {
        id: '1',
        method: 'filesystem.listDir',
        params: { path: testDir },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      const result = response.result as { entries: any[] };
      expect(result.entries).toHaveLength(1);
      expect(result.entries[0].name).toBe('visible.txt');
    });

    it('should show hidden files when showHidden is true', async () => {
      await fs.writeFile(path.join(testDir, '.hidden'), 'content');
      await fs.writeFile(path.join(testDir, 'visible.txt'), 'content');

      const request: RpcRequest = {
        id: '1',
        method: 'filesystem.listDir',
        params: { path: testDir, showHidden: true },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      const result = response.result as { entries: any[] };
      expect(result.entries).toHaveLength(2);
    });

    it('should default to home directory when no path specified', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'filesystem.listDir',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      const result = response.result as { path: string };
      expect(result.path).toBe(os.homedir());
    });

    it('should return error for non-existent directory', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'filesystem.listDir',
        params: { path: '/non/existent/path' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('FILESYSTEM_ERROR');
    });
  });

  describe('filesystem.getHome', () => {
    it('should return home path', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'filesystem.getHome',
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      const result = response.result as { homePath: string };
      expect(result.homePath).toBe(os.homedir());
    });

    it('should return suggested paths', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'filesystem.getHome',
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      const result = response.result as { suggestedPaths: any[] };
      expect(result.suggestedPaths).toBeDefined();
      expect(Array.isArray(result.suggestedPaths)).toBe(true);
      // Home should always be included
      expect(result.suggestedPaths.some(p => p.name === 'Home')).toBe(true);
    });
  });

  describe('filesystem.createDir', () => {
    it('should create a directory', async () => {
      const newDir = path.join(testDir, 'newdir');
      const request: RpcRequest = {
        id: '1',
        method: 'filesystem.createDir',
        params: { path: newDir },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      const result = response.result as { created: boolean; path: string };
      expect(result.created).toBe(true);

      // Verify directory exists
      const stat = await fs.stat(newDir);
      expect(stat.isDirectory()).toBe(true);
    });

    it('should return error for missing path', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'filesystem.createDir',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
    });

    it('should reject path traversal', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'filesystem.createDir',
        // Use string concatenation to preserve .. (path.join normalizes it away)
        params: { path: testDir + '/../escape' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('traversal');
    });

    it('should reject hidden folders', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'filesystem.createDir',
        params: { path: path.join(testDir, '.hidden') },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('Hidden');
    });

    it('should return error when directory already exists', async () => {
      const existingDir = path.join(testDir, 'existing');
      await fs.mkdir(existingDir);

      const request: RpcRequest = {
        id: '1',
        method: 'filesystem.createDir',
        params: { path: existingDir },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('ALREADY_EXISTS');
    });

    it('should create nested directories with recursive option', async () => {
      const nestedPath = path.join(testDir, 'a', 'b', 'c');
      const request: RpcRequest = {
        id: '1',
        method: 'filesystem.createDir',
        params: { path: nestedPath, recursive: true },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);

      // Verify nested directory exists
      const stat = await fs.stat(nestedPath);
      expect(stat.isDirectory()).toBe(true);
    });

    it('should fail on nested directories without recursive option', async () => {
      const nestedPath = path.join(testDir, 'x', 'y', 'z');
      const request: RpcRequest = {
        id: '1',
        method: 'filesystem.createDir',
        params: { path: nestedPath, recursive: false },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('PARENT_NOT_FOUND');
    });
  });

  describe('createFilesystemHandlers', () => {
    it('should create handlers for registration', () => {
      const handlers = createFilesystemHandlers();

      expect(handlers).toHaveLength(3);
      expect(handlers.map(h => h.method)).toContain('filesystem.listDir');
      expect(handlers.map(h => h.method)).toContain('filesystem.getHome');
      expect(handlers.map(h => h.method)).toContain('filesystem.createDir');
    });
  });

  describe('Registry Integration', () => {
    it('should register and dispatch filesystem handlers', async () => {
      expect(registry.has('filesystem.listDir')).toBe(true);
      expect(registry.has('filesystem.getHome')).toBe(true);
      expect(registry.has('filesystem.createDir')).toBe(true);

      // Test getHome through registry
      const request: RpcRequest = {
        id: '1',
        method: 'filesystem.getHome',
      };

      const response = await registry.dispatch(request, mockContext);
      expect(response.success).toBe(true);
      expect(response.result).toHaveProperty('homePath');
    });
  });
});
