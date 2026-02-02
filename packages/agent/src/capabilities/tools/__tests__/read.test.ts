/**
 * @fileoverview Tests for Read tool
 *
 * TDD: Tests for file reading operations
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import * as fs from 'fs/promises';
import * as path from 'path';
import { ReadTool } from '../fs/read.js';
import type { TronToolResult } from '@core/types/index.js';

// Mock fs/promises
vi.mock('fs/promises');

describe('ReadTool', () => {
  let readTool: ReadTool;

  beforeEach(() => {
    readTool = new ReadTool({ workingDirectory: '/test/project' });
    vi.resetAllMocks();
  });

  describe('tool definition', () => {
    it('should have correct name and description', () => {
      expect(readTool.name).toBe('Read');
      expect(readTool.description).toContain('file');
    });

    it('should define required parameters', () => {
      const params = readTool.parameters;
      expect(params.properties).toHaveProperty('file_path');
      expect(params.required).toContain('file_path');
    });

    it('should support optional offset and limit', () => {
      const params = readTool.parameters;
      expect(params.properties).toHaveProperty('offset');
      expect(params.properties).toHaveProperty('limit');
    });
  });

  describe('execute', () => {
    it('should read entire file by default', async () => {
      const content = 'line 1\nline 2\nline 3';
      vi.mocked(fs.readFile).mockResolvedValue(content);
      vi.mocked(fs.stat).mockResolvedValue({ size: content.length } as any);

      const result = await readTool.execute({ file_path: '/test/file.txt' });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('line 1');
      expect(result.content).toContain('line 2');
      expect(result.content).toContain('line 3');
    });

    it('should add line numbers to output', async () => {
      const content = 'first\nsecond\nthird';
      vi.mocked(fs.readFile).mockResolvedValue(content);
      vi.mocked(fs.stat).mockResolvedValue({ size: content.length } as any);

      const result = await readTool.execute({ file_path: '/test/file.txt' });

      // Output should include line numbers
      expect(result.content).toMatch(/1.*first/);
      expect(result.content).toMatch(/2.*second/);
      expect(result.content).toMatch(/3.*third/);
    });

    it('should support offset parameter', async () => {
      const content = 'line 1\nline 2\nline 3\nline 4\nline 5';
      vi.mocked(fs.readFile).mockResolvedValue(content);
      vi.mocked(fs.stat).mockResolvedValue({ size: content.length } as any);

      const result = await readTool.execute({
        file_path: '/test/file.txt',
        offset: 2,
      });

      // Should skip first 2 lines (0-indexed), starting from line 3
      expect(result.content).not.toContain('line 1');
      expect(result.content).not.toContain('line 2');
      expect(result.content).toContain('line 3');
    });

    it('should support limit parameter', async () => {
      const content = 'line 1\nline 2\nline 3\nline 4\nline 5';
      vi.mocked(fs.readFile).mockResolvedValue(content);
      vi.mocked(fs.stat).mockResolvedValue({ size: content.length } as any);

      const result = await readTool.execute({
        file_path: '/test/file.txt',
        limit: 2,
      });

      expect(result.content).toContain('line 1');
      expect(result.content).toContain('line 2');
      expect(result.content).not.toContain('line 3');
    });

    it('should handle file not found', async () => {
      const error = new Error('ENOENT: no such file or directory');
      (error as any).code = 'ENOENT';
      vi.mocked(fs.readFile).mockRejectedValue(error);

      const result = await readTool.execute({ file_path: '/test/missing.txt' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('not found');
    });

    it('should handle permission denied', async () => {
      const error = new Error('EACCES: permission denied');
      (error as any).code = 'EACCES';
      vi.mocked(fs.readFile).mockRejectedValue(error);

      const result = await readTool.execute({ file_path: '/test/protected.txt' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Permission denied');
    });

    it('should resolve relative paths against working directory', async () => {
      vi.mocked(fs.readFile).mockResolvedValue('content');
      vi.mocked(fs.stat).mockResolvedValue({ size: 7 } as any);

      await readTool.execute({ file_path: 'relative/file.txt' });

      expect(fs.readFile).toHaveBeenCalledWith(
        '/test/project/relative/file.txt',
        'utf-8'
      );
    });

    it('should include file path in details', async () => {
      vi.mocked(fs.readFile).mockResolvedValue('content');
      vi.mocked(fs.stat).mockResolvedValue({ size: 7 } as any);

      const result = await readTool.execute({ file_path: '/test/file.txt' });

      expect(result.details).toHaveProperty('filePath', '/test/file.txt');
    });

    it('should include line count in details', async () => {
      const content = 'line 1\nline 2\nline 3';
      vi.mocked(fs.readFile).mockResolvedValue(content);
      vi.mocked(fs.stat).mockResolvedValue({ size: content.length } as any);

      const result = await readTool.execute({ file_path: '/test/file.txt' });

      expect(result.details).toHaveProperty('totalLines', 3);
    });

    it('should truncate long lines', async () => {
      const longLine = 'a'.repeat(3000);
      vi.mocked(fs.readFile).mockResolvedValue(longLine);
      vi.mocked(fs.stat).mockResolvedValue({ size: 3000 } as any);

      const result = await readTool.execute({ file_path: '/test/file.txt' });

      // Should truncate to 2000 chars by default
      expect(result.content.length).toBeLessThan(3000);
    });
  });
});
