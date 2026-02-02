/**
 * @fileoverview Tests for File RPC Handlers
 *
 * Tests file.read handler using the registry dispatch pattern.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import * as fs from 'fs/promises';
import * as os from 'os';
import * as path from 'path';
import { createFileHandlers } from '../file.handler.js';
import type { RpcRequest } from '../../types.js';
import type { RpcContext } from '../../handler.js';
import { MethodRegistry } from '../../registry.js';

// Mock fs module
vi.mock('fs/promises');

describe('File Handlers', () => {
  let registry: MethodRegistry;
  let mockContext: RpcContext;
  let homeDir: string;

  beforeEach(() => {
    registry = new MethodRegistry();
    registry.registerAll(createFileHandlers());

    mockContext = {} as RpcContext;
    homeDir = os.homedir();
    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe('file.read', () => {
    it('should return error when path is missing', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'file.read',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('path');
    });

    it('should return error when path is outside home directory', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'file.read',
        params: { path: '/etc/passwd' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('PERMISSION_DENIED');
      expect(response.error?.message).toBe('Can only read files within home directory');
    });

    it('should prevent directory traversal attacks', async () => {
      const maliciousPath = path.join(homeDir, '..', 'etc', 'passwd');
      const request: RpcRequest = {
        id: '1',
        method: 'file.read',
        params: { path: maliciousPath },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('PERMISSION_DENIED');
    });

    it('should read file successfully when path is within home directory', async () => {
      const filePath = path.join(homeDir, 'documents', 'test.txt');
      const fileContent = 'Hello, World!';

      vi.mocked(fs.readFile).mockResolvedValue(fileContent);

      const request: RpcRequest = {
        id: '1',
        method: 'file.read',
        params: { path: filePath },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual({ content: fileContent });
      expect(fs.readFile).toHaveBeenCalledWith(filePath, 'utf-8');
    });

    it('should return FILE_NOT_FOUND when file does not exist', async () => {
      const filePath = path.join(homeDir, 'nonexistent.txt');
      const error = new Error('ENOENT: no such file or directory') as NodeJS.ErrnoException;
      error.code = 'ENOENT';

      vi.mocked(fs.readFile).mockRejectedValue(error);

      const request: RpcRequest = {
        id: '1',
        method: 'file.read',
        params: { path: filePath },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('FILE_NOT_FOUND');
      expect(response.error?.message).toContain('File not found');
    });

    it('should return FILE_ERROR for other read errors', async () => {
      const filePath = path.join(homeDir, 'restricted.txt');

      vi.mocked(fs.readFile).mockRejectedValue(new Error('Permission denied'));

      const request: RpcRequest = {
        id: '1',
        method: 'file.read',
        params: { path: filePath },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('FILE_ERROR');
      expect(response.error?.message).toBe('Permission denied');
    });

    it('should normalize paths with dots', async () => {
      // A path like ~/./documents/../documents/file.txt should normalize to ~/documents/file.txt
      const filePath = path.join(homeDir, '.', 'documents', '..', 'documents', 'test.txt');
      const fileContent = 'Test content';

      vi.mocked(fs.readFile).mockResolvedValue(fileContent);

      const request: RpcRequest = {
        id: '1',
        method: 'file.read',
        params: { path: filePath },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual({ content: fileContent });
    });
  });

  describe('createFileHandlers', () => {
    it('should create handler registrations', () => {
      const registrations = createFileHandlers();

      expect(registrations).toHaveLength(1);
      expect(registrations[0].method).toBe('file.read');
      expect(registrations[0].options?.requiredParams).toContain('path');
      expect(registrations[0].options?.description).toBe('Read a file from the filesystem');
    });
  });
});
