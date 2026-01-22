/**
 * @fileoverview Tests for Grep tool
 *
 * TDD: Tests for content pattern search operations
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import * as fs from 'fs/promises';
import { GrepTool } from './grep.js';

// Mock fs/promises
vi.mock('fs/promises');

// Helper to create mock stat object
const mockStat = (opts: { isDir?: boolean; isFile?: boolean; size?: number }) => ({
  isDirectory: () => opts.isDir ?? false,
  isFile: () => opts.isFile ?? !opts.isDir,
  size: opts.size ?? 0,
});

// Helper to create mock dirent
const mockDirent = (name: string, opts: { isDir?: boolean; isFile?: boolean } = {}) => ({
  name,
  isDirectory: () => opts.isDir ?? false,
  isFile: () => opts.isFile ?? !opts.isDir,
});

describe('GrepTool', () => {
  let grepTool: GrepTool;

  beforeEach(() => {
    grepTool = new GrepTool({ workingDirectory: '/test/project' });
    vi.resetAllMocks();
  });

  describe('tool definition', () => {
    it('should have correct name and description', () => {
      expect(grepTool.name).toBe('Grep');
      expect(grepTool.description.toLowerCase()).toContain('search');
    });

    it('should define required parameters', () => {
      const params = grepTool.parameters;
      expect(params.properties).toHaveProperty('pattern');
      expect(params.required).toContain('pattern');
    });

    it('should support optional path parameter', () => {
      const params = grepTool.parameters;
      expect(params.properties).toHaveProperty('path');
    });

    it('should support glob filter parameter', () => {
      const params = grepTool.parameters;
      expect(params.properties).toHaveProperty('glob');
    });

    it('should support case insensitive flag', () => {
      const params = grepTool.parameters;
      expect(params.properties).toHaveProperty('ignoreCase');
    });

    it('should have search category', () => {
      expect(grepTool.category).toBe('search');
    });
  });

  describe('execute', () => {
    it('should search for pattern in single file', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isFile: true, size: 100 }) as any);
      vi.mocked(fs.readFile).mockResolvedValue('line 1\nfoo bar\nline 3\nfoo baz');

      const result = await grepTool.execute({
        pattern: 'foo',
        path: 'test.txt',
      });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('foo bar');
      expect(result.content).toContain('foo baz');
    });

    it('should show line numbers in results', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isFile: true, size: 100 }) as any);
      vi.mocked(fs.readFile).mockResolvedValue('line 1\nfoo bar\nline 3');

      const result = await grepTool.execute({
        pattern: 'foo',
        path: 'test.txt',
      });

      expect(result.content).toMatch(/2.*foo bar/);
    });

    it('should search directory recursively', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isDir: true }) as any);
      vi.mocked(fs.readdir).mockResolvedValue([
        mockDirent('file1.ts', { isFile: true }),
        mockDirent('file2.ts', { isFile: true }),
      ] as any);
      vi.mocked(fs.readFile)
        .mockResolvedValueOnce('const foo = 1;')
        .mockResolvedValueOnce('let bar = 2;');

      const result = await grepTool.execute({
        pattern: 'foo',
        path: '.',
      });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('foo');
    });

    it('should filter by glob pattern', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isDir: true }) as any);
      vi.mocked(fs.readdir).mockResolvedValue([
        mockDirent('file.ts', { isFile: true }),
        mockDirent('file.js', { isFile: true }),
        mockDirent('file.md', { isFile: true }),
      ] as any);
      vi.mocked(fs.readFile).mockResolvedValue('const foo = 1;');

      const result = await grepTool.execute({
        pattern: 'const',
        glob: '*.ts',
      });

      expect(result.isError).toBeFalsy();
    });

    it('should support case insensitive search', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isFile: true, size: 100 }) as any);
      vi.mocked(fs.readFile).mockResolvedValue('FOO BAR\nfoo bar');

      const result = await grepTool.execute({
        pattern: 'foo',
        path: 'test.txt',
        ignoreCase: true,
      });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('FOO BAR');
      expect(result.content).toContain('foo bar');
    });

    it('should support regex patterns', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isFile: true, size: 100 }) as any);
      vi.mocked(fs.readFile).mockResolvedValue('foo123\nfoo456\nbar789');

      const result = await grepTool.execute({
        pattern: 'foo\\d+',
        path: 'test.txt',
      });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('foo123');
      expect(result.content).toContain('foo456');
      expect(result.content).not.toContain('bar789');
    });

    it('should show context lines when requested', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isFile: true, size: 100 }) as any);
      vi.mocked(fs.readFile).mockResolvedValue('line 1\nline 2\nmatch here\nline 4\nline 5');

      const result = await grepTool.execute({
        pattern: 'match',
        path: 'test.txt',
        context: 1,
      });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('line 2');
      expect(result.content).toContain('match here');
      expect(result.content).toContain('line 4');
    });

    it('should handle no matches found', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isFile: true, size: 100 }) as any);
      vi.mocked(fs.readFile).mockResolvedValue('line 1\nline 2');

      const result = await grepTool.execute({
        pattern: 'nonexistent',
        path: 'test.txt',
      });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('No matches');
    });

    it('should handle file not found', async () => {
      const error = new Error('ENOENT') as NodeJS.ErrnoException;
      error.code = 'ENOENT';
      vi.mocked(fs.stat).mockRejectedValue(error);

      const result = await grepTool.execute({
        pattern: 'foo',
        path: 'missing.txt',
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('not found');
    });

    it('should limit results to prevent output overflow', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isFile: true, size: 100 }) as any);
      const lines = Array.from({ length: 200 }, (_, i) => `foo line ${i}`).join('\n');
      vi.mocked(fs.readFile).mockResolvedValue(lines);

      const result = await grepTool.execute({
        pattern: 'foo',
        path: 'test.txt',
        maxResults: 50,
      });

      expect(result.isError).toBeFalsy();
      expect(result.details?.truncated).toBe(true);
    });

    it('should skip binary files', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isDir: true }) as any);
      vi.mocked(fs.readdir).mockResolvedValue([
        mockDirent('text.txt', { isFile: true }),
        mockDirent('image.png', { isFile: true }),
      ] as any);
      vi.mocked(fs.readFile).mockResolvedValue('foo bar');

      const result = await grepTool.execute({
        pattern: 'foo',
      });

      expect(result.isError).toBeFalsy();
    });

    it('should resolve relative paths against working directory', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isFile: true, size: 100 }) as any);
      vi.mocked(fs.readFile).mockResolvedValue('foo');

      await grepTool.execute({
        pattern: 'foo',
        path: 'relative/file.txt',
      });

      expect(fs.stat).toHaveBeenCalledWith('/test/project/relative/file.txt');
    });

    it('should include match count in details', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isFile: true, size: 100 }) as any);
      vi.mocked(fs.readFile).mockResolvedValue('foo\nfoo\nfoo');

      const result = await grepTool.execute({
        pattern: 'foo',
        path: 'test.txt',
      });

      expect(result.details).toHaveProperty('matchCount', 3);
    });
  });
});
