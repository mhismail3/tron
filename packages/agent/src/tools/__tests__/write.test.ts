/**
 * @fileoverview Tests for Write tool
 *
 * TDD: Tests for file writing operations
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import * as fs from 'fs/promises';
import * as path from 'path';
import { WriteTool } from '../write.js';

// Mock fs/promises
vi.mock('fs/promises');

describe('WriteTool', () => {
  let writeTool: WriteTool;

  beforeEach(() => {
    writeTool = new WriteTool({ workingDirectory: '/test/project' });
    vi.resetAllMocks();
    vi.mocked(fs.mkdir).mockResolvedValue(undefined);
    vi.mocked(fs.writeFile).mockResolvedValue();
    vi.mocked(fs.access).mockRejectedValue(new Error('ENOENT')); // File doesn't exist by default
  });

  describe('tool definition', () => {
    it('should have correct name and description', () => {
      expect(writeTool.name).toBe('Write');
      expect(writeTool.description).toContain('file');
    });

    it('should define required parameters', () => {
      const params = writeTool.parameters;
      expect(params.properties).toHaveProperty('file_path');
      expect(params.properties).toHaveProperty('content');
      expect(params.required).toContain('file_path');
      expect(params.required).toContain('content');
    });
  });

  describe('execute', () => {
    it('should write content to file', async () => {
      const result = await writeTool.execute({
        file_path: '/test/new-file.txt',
        content: 'Hello, world!',
      });

      expect(result.isError).toBeFalsy();
      expect(fs.writeFile).toHaveBeenCalledWith(
        '/test/new-file.txt',
        'Hello, world!',
        'utf-8'
      );
    });

    it('should create parent directories if they do not exist', async () => {
      const filePath = '/test/project/deep/nested/file.txt';

      await writeTool.execute({
        file_path: filePath,
        content: 'content',
      });

      expect(fs.mkdir).toHaveBeenCalledWith(
        path.dirname(filePath),
        { recursive: true }
      );
    });

    it('should confirm overwrite for existing files', async () => {
      // File exists
      vi.mocked(fs.access).mockResolvedValue(undefined);

      const result = await writeTool.execute({
        file_path: '/test/existing.txt',
        content: 'new content',
      });

      expect(result.isError).toBeFalsy();
      expect(fs.writeFile).toHaveBeenCalled();
    });

    it('should resolve relative paths against working directory', async () => {
      await writeTool.execute({
        file_path: 'relative/file.txt',
        content: 'content',
      });

      expect(fs.writeFile).toHaveBeenCalledWith(
        '/test/project/relative/file.txt',
        'content',
        'utf-8'
      );
    });

    it('should handle write errors gracefully', async () => {
      const error = new Error('EACCES: permission denied');
      (error as any).code = 'EACCES';
      vi.mocked(fs.writeFile).mockRejectedValue(error);

      const result = await writeTool.execute({
        file_path: '/test/protected.txt',
        content: 'content',
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Permission denied');
    });

    it('should include file path in details', async () => {
      const result = await writeTool.execute({
        file_path: '/test/file.txt',
        content: 'content',
      });

      expect(result.details).toHaveProperty('filePath', '/test/file.txt');
    });

    it('should include bytes written in details', async () => {
      const content = 'Hello, world!';
      const result = await writeTool.execute({
        file_path: '/test/file.txt',
        content,
      });

      expect(result.details).toHaveProperty('bytesWritten', Buffer.byteLength(content));
    });

    it('should report if file was created or overwritten', async () => {
      // New file
      vi.mocked(fs.access).mockRejectedValue(new Error('ENOENT'));

      let result = await writeTool.execute({
        file_path: '/test/new.txt',
        content: 'content',
      });

      expect(result.details).toHaveProperty('created', true);

      // Existing file
      vi.mocked(fs.access).mockResolvedValue(undefined);

      result = await writeTool.execute({
        file_path: '/test/existing.txt',
        content: 'content',
      });

      expect(result.details).toHaveProperty('created', false);
    });
  });
});
