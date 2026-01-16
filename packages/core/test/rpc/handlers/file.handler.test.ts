/**
 * Tests for file.handler.ts
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import * as fs from 'fs/promises';
import * as os from 'os';
import * as path from 'path';
import {
  handleFileRead,
  createFileHandlers,
} from '../../../src/rpc/handlers/file.handler.js';
import type { RpcRequest, RpcResponse } from '../../../src/rpc/types.js';
import type { RpcContext } from '../../../src/rpc/handler.js';

// Mock fs module
vi.mock('fs/promises');

describe('file.handler', () => {
  let mockContext: RpcContext;
  let homeDir: string;

  beforeEach(() => {
    mockContext = {} as RpcContext;
    homeDir = os.homedir();
    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe('handleFileRead', () => {
    it('should return error when path is missing', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'file.read',
        params: {},
      };

      const response = await handleFileRead(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toBe('path is required');
    });

    it('should return error when path is outside home directory', async () => {
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'file.read',
        params: { path: '/etc/passwd' },
      };

      const response = await handleFileRead(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('PERMISSION_DENIED');
      expect(response.error?.message).toBe('Can only read files within home directory');
    });

    it('should prevent directory traversal attacks', async () => {
      const maliciousPath = path.join(homeDir, '..', 'etc', 'passwd');
      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'file.read',
        params: { path: maliciousPath },
      };

      const response = await handleFileRead(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('PERMISSION_DENIED');
    });

    it('should read file successfully when path is within home directory', async () => {
      const filePath = path.join(homeDir, 'documents', 'test.txt');
      const fileContent = 'Hello, World!';

      vi.mocked(fs.readFile).mockResolvedValue(fileContent);

      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'file.read',
        params: { path: filePath },
      };

      const response = await handleFileRead(request, mockContext);

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
        jsonrpc: '2.0',
        id: '1',
        method: 'file.read',
        params: { path: filePath },
      };

      const response = await handleFileRead(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('FILE_NOT_FOUND');
      expect(response.error?.message).toBe('File not found');
    });

    it('should return FILE_ERROR for other read errors', async () => {
      const filePath = path.join(homeDir, 'restricted.txt');

      vi.mocked(fs.readFile).mockRejectedValue(new Error('Permission denied'));

      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'file.read',
        params: { path: filePath },
      };

      const response = await handleFileRead(request, mockContext);

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
        jsonrpc: '2.0',
        id: '1',
        method: 'file.read',
        params: { path: filePath },
      };

      const response = await handleFileRead(request, mockContext);

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

    it('should create handler that returns result on success', async () => {
      const registrations = createFileHandlers();
      const handler = registrations[0].handler;

      const filePath = path.join(homeDir, 'test.txt');
      const fileContent = 'File content';

      vi.mocked(fs.readFile).mockResolvedValue(fileContent);

      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'file.read',
        params: { path: filePath },
      };

      const result = await handler(request, mockContext);

      expect(result).toEqual({ content: fileContent });
    });

    it('should create handler that throws on error', async () => {
      const registrations = createFileHandlers();
      const handler = registrations[0].handler;

      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'file.read',
        params: {},
      };

      await expect(handler(request, mockContext)).rejects.toThrow('path is required');
    });

    it('should create handler that throws on permission denied', async () => {
      const registrations = createFileHandlers();
      const handler = registrations[0].handler;

      const request: RpcRequest = {
        jsonrpc: '2.0',
        id: '1',
        method: 'file.read',
        params: { path: '/etc/passwd' },
      };

      await expect(handler(request, mockContext)).rejects.toThrow('Can only read files within home directory');
    });
  });
});
