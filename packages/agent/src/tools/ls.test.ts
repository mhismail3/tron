/**
 * @fileoverview Tests for Ls tool
 *
 * TDD: Tests for directory listing operations
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import * as fs from 'fs/promises';
import { LsTool } from './ls.js';

// Mock fs/promises
vi.mock('fs/promises');

// Helper to create mock stat object
const mockStat = (opts: { isDir?: boolean; isFile?: boolean; size?: number; mtime?: Date }) => ({
  isDirectory: () => opts.isDir ?? false,
  isFile: () => opts.isFile ?? !opts.isDir,
  isSymbolicLink: () => false,
  size: opts.size ?? 0,
  mtime: opts.mtime ?? new Date(),
});

// Helper to create mock dirent
const mockDirent = (name: string, opts: { isDir?: boolean; isFile?: boolean; isSymlink?: boolean } = {}) => ({
  name,
  isDirectory: () => opts.isDir ?? false,
  isFile: () => opts.isFile ?? !opts.isDir,
  isSymbolicLink: () => opts.isSymlink ?? false,
});

describe('LsTool', () => {
  let lsTool: LsTool;

  beforeEach(() => {
    lsTool = new LsTool({ workingDirectory: '/test/project' });
    vi.resetAllMocks();
  });

  describe('tool definition', () => {
    it('should have correct name and description', () => {
      expect(lsTool.name).toBe('Ls');
      expect(lsTool.description).toContain('directory');
    });

    it('should define path as optional parameter', () => {
      const params = lsTool.parameters;
      expect(params.properties).toHaveProperty('path');
      expect(params.required || []).not.toContain('path');
    });

    it('should support all flag', () => {
      const params = lsTool.parameters;
      expect(params.properties).toHaveProperty('all');
    });

    it('should support long format flag', () => {
      const params = lsTool.parameters;
      expect(params.properties).toHaveProperty('long');
    });

    it('should have filesystem category', () => {
      expect(lsTool.category).toBe('filesystem');
    });
  });

  describe('execute', () => {
    it('should list directory contents', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isDir: true }) as any);
      vi.mocked(fs.readdir).mockResolvedValue([
        mockDirent('file1.ts', { isFile: true }),
        mockDirent('file2.ts', { isFile: true }),
        mockDirent('subdir', { isDir: true }),
      ] as any);

      const result = await lsTool.execute({});

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('file1.ts');
      expect(result.content).toContain('file2.ts');
      expect(result.content).toContain('subdir');
    });

    it('should list specific directory', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isDir: true }) as any);
      vi.mocked(fs.readdir).mockResolvedValue([
        mockDirent('src-file.ts', { isFile: true }),
      ] as any);

      const result = await lsTool.execute({ path: 'src' });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('src-file.ts');
    });

    it('should show hidden files when all flag is set', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isDir: true }) as any);
      vi.mocked(fs.readdir).mockResolvedValue([
        mockDirent('.hidden', { isFile: true }),
        mockDirent('visible.ts', { isFile: true }),
      ] as any);

      const result = await lsTool.execute({ all: true });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('.hidden');
      expect(result.content).toContain('visible.ts');
    });

    it('should hide hidden files by default', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isDir: true }) as any);
      vi.mocked(fs.readdir).mockResolvedValue([
        mockDirent('.hidden', { isFile: true }),
        mockDirent('visible.ts', { isFile: true }),
      ] as any);

      const result = await lsTool.execute({});

      expect(result.isError).toBeFalsy();
      expect(result.content).not.toContain('.hidden');
      expect(result.content).toContain('visible.ts');
    });

    it('should show long format with sizes and dates', async () => {
      const mtime = new Date('2024-01-15T10:30:00Z');
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isDir: true }) as any);
      vi.mocked(fs.readdir).mockResolvedValue([
        mockDirent('file.ts', { isFile: true }),
      ] as any);
      // Second stat call for file details
      vi.mocked(fs.stat).mockResolvedValueOnce(mockStat({ isDir: true }) as any);
      vi.mocked(fs.stat).mockResolvedValueOnce(mockStat({ isFile: true, size: 1024, mtime }) as any);

      const result = await lsTool.execute({ long: true });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('1024');
      expect(result.content).toContain('file.ts');
    });

    it('should indicate directories with trailing slash or marker', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isDir: true }) as any);
      vi.mocked(fs.readdir).mockResolvedValue([
        mockDirent('subdir', { isDir: true }),
        mockDirent('file.ts', { isFile: true }),
      ] as any);

      const result = await lsTool.execute({});

      expect(result.isError).toBeFalsy();
      const content = result.content as string;
      expect(content).toMatch(/subdir\//);
    });

    it('should handle path not found', async () => {
      const error = new Error('ENOENT') as NodeJS.ErrnoException;
      error.code = 'ENOENT';
      vi.mocked(fs.stat).mockRejectedValue(error);

      const result = await lsTool.execute({ path: 'nonexistent' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('not found');
    });

    it('should handle permission denied', async () => {
      const error = new Error('EACCES') as NodeJS.ErrnoException;
      error.code = 'EACCES';
      vi.mocked(fs.stat).mockRejectedValue(error);

      const result = await lsTool.execute({ path: 'protected' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Permission denied');
    });

    it('should handle file path (not directory)', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isFile: true, size: 100 }) as any);
      vi.mocked(fs.lstat).mockResolvedValue(mockStat({ isFile: true }) as any);

      const result = await lsTool.execute({ path: 'file.txt' });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('file.txt');
    });

    it('should handle empty directory', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isDir: true }) as any);
      vi.mocked(fs.readdir).mockResolvedValue([] as any);

      const result = await lsTool.execute({});

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('empty');
    });

    it('should sort entries alphabetically by default', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isDir: true }) as any);
      vi.mocked(fs.readdir).mockResolvedValue([
        mockDirent('zebra.ts', { isFile: true }),
        mockDirent('alpha.ts', { isFile: true }),
        mockDirent('beta.ts', { isFile: true }),
      ] as any);

      const result = await lsTool.execute({});

      expect(result.isError).toBeFalsy();
      const content = result.content as string;
      expect(content.indexOf('alpha.ts')).toBeLessThan(content.indexOf('beta.ts'));
      expect(content.indexOf('beta.ts')).toBeLessThan(content.indexOf('zebra.ts'));
    });

    it('should put directories first when requested', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isDir: true }) as any);
      vi.mocked(fs.readdir).mockResolvedValue([
        mockDirent('file.ts', { isFile: true }),
        mockDirent('subdir', { isDir: true }),
      ] as any);

      const result = await lsTool.execute({ groupDirectoriesFirst: true });

      expect(result.isError).toBeFalsy();
      const content = result.content as string;
      expect(content.indexOf('subdir')).toBeLessThan(content.indexOf('file.ts'));
    });

    it('should resolve relative paths against working directory', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isDir: true }) as any);
      vi.mocked(fs.readdir).mockResolvedValue([] as any);

      await lsTool.execute({ path: 'relative/path' });

      expect(fs.stat).toHaveBeenCalledWith('/test/project/relative/path');
    });

    it('should include entry count in details', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isDir: true }) as any);
      vi.mocked(fs.readdir).mockResolvedValue([
        mockDirent('file1.ts', { isFile: true }),
        mockDirent('file2.ts', { isFile: true }),
        mockDirent('subdir', { isDir: true }),
      ] as any);

      const result = await lsTool.execute({});

      expect(result.details).toHaveProperty('entryCount', 3);
      expect(result.details).toHaveProperty('fileCount', 2);
      expect(result.details).toHaveProperty('dirCount', 1);
    });

    it('should handle symbolic links', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isDir: true }) as any);
      vi.mocked(fs.readdir).mockResolvedValue([
        mockDirent('link', { isSymlink: true }),
      ] as any);
      vi.mocked(fs.readlink).mockResolvedValue('/target/path');

      const result = await lsTool.execute({ long: true });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('link');
    });

    it('should format human-readable sizes', async () => {
      vi.mocked(fs.stat)
        .mockResolvedValueOnce(mockStat({ isDir: true }) as any)
        .mockResolvedValueOnce(mockStat({ isFile: true, size: 1048576, mtime: new Date() }) as any);
      vi.mocked(fs.readdir).mockResolvedValue([
        mockDirent('large.bin', { isFile: true }),
      ] as any);

      const result = await lsTool.execute({ long: true, humanReadable: true });

      expect(result.isError).toBeFalsy();
      expect(result.content).toMatch(/1\.0M/i);
    });
  });
});
