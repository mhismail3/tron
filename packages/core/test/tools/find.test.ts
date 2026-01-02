/**
 * @fileoverview Tests for Find tool
 *
 * TDD: Tests for file search operations using glob patterns
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import * as fs from 'fs/promises';
import { FindTool } from '../../src/tools/find.js';

// Mock fs/promises
vi.mock('fs/promises');

// Helper to create mock stat object
const mockStat = (opts: { isDir?: boolean; isFile?: boolean; size?: number; mtime?: Date }) => ({
  isDirectory: () => opts.isDir ?? false,
  isFile: () => opts.isFile ?? !opts.isDir,
  size: opts.size ?? 0,
  mtime: opts.mtime ?? new Date(),
});

// Helper to create mock dirent
const mockDirent = (name: string, opts: { isDir?: boolean; isFile?: boolean } = {}) => ({
  name,
  isDirectory: () => opts.isDir ?? false,
  isFile: () => opts.isFile ?? !opts.isDir,
});

describe('FindTool', () => {
  let findTool: FindTool;

  beforeEach(() => {
    findTool = new FindTool({ workingDirectory: '/test/project' });
    vi.resetAllMocks();
  });

  describe('tool definition', () => {
    it('should have correct name and description', () => {
      expect(findTool.name).toBe('Find');
      expect(findTool.description).toContain('file');
    });

    it('should define required parameters', () => {
      const params = findTool.parameters;
      expect(params.properties).toHaveProperty('pattern');
      expect(params.required).toContain('pattern');
    });

    it('should support optional path parameter', () => {
      const params = findTool.parameters;
      expect(params.properties).toHaveProperty('path');
    });

    it('should support type filter parameter', () => {
      const params = findTool.parameters;
      expect(params.properties).toHaveProperty('type');
    });

    it('should have search category', () => {
      expect(findTool.category).toBe('search');
    });
  });

  describe('execute', () => {
    it('should find files matching glob pattern', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isDir: true }) as any);
      vi.mocked(fs.readdir).mockResolvedValue([
        mockDirent('file1.ts', { isFile: true }),
        mockDirent('file2.ts', { isFile: true }),
        mockDirent('file3.js', { isFile: true }),
      ] as any);

      const result = await findTool.execute({
        pattern: '*.ts',
      });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('file1.ts');
      expect(result.content).toContain('file2.ts');
      expect(result.content).not.toContain('file3.js');
    });

    it('should search recursively with ** pattern', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isDir: true }) as any);
      vi.mocked(fs.readdir)
        .mockResolvedValueOnce([
          mockDirent('src', { isDir: true }),
          mockDirent('root.ts', { isFile: true }),
        ] as any)
        .mockResolvedValueOnce([
          mockDirent('nested.ts', { isFile: true }),
        ] as any);

      const result = await findTool.execute({
        pattern: '**/*.ts',
      });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('root.ts');
      expect(result.content).toContain('nested.ts');
    });

    it('should filter by file type', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isDir: true }) as any);
      vi.mocked(fs.readdir).mockResolvedValue([
        mockDirent('dir1', { isDir: true }),
        mockDirent('file1.ts', { isFile: true }),
      ] as any);

      const result = await findTool.execute({
        pattern: '*',
        type: 'directory',
      });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('dir1');
      expect(result.content).not.toContain('file1.ts');
    });

    it('should respect maxDepth parameter', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isDir: true }) as any);
      vi.mocked(fs.readdir)
        .mockResolvedValueOnce([
          mockDirent('level1', { isDir: true }),
          mockDirent('root.ts', { isFile: true }),
        ] as any)
        .mockResolvedValueOnce([
          mockDirent('level2', { isDir: true }),
          mockDirent('deep.ts', { isFile: true }),
        ] as any);

      const result = await findTool.execute({
        pattern: '**/*.ts',
        maxDepth: 1,
      });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('root.ts');
    });

    it('should exclude patterns when specified', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isDir: true }) as any);
      vi.mocked(fs.readdir).mockResolvedValue([
        mockDirent('src', { isDir: true }),
        mockDirent('node_modules', { isDir: true }),
        mockDirent('file.ts', { isFile: true }),
      ] as any);

      const result = await findTool.execute({
        pattern: '*',
        exclude: ['node_modules'],
      });

      expect(result.isError).toBeFalsy();
      expect(result.content).not.toContain('node_modules');
    });

    it('should show file sizes when requested', async () => {
      vi.mocked(fs.stat)
        .mockResolvedValueOnce(mockStat({ isDir: true }) as any)
        .mockResolvedValueOnce(mockStat({ isFile: true, size: 1024 }) as any);
      vi.mocked(fs.readdir).mockResolvedValue([
        mockDirent('file.ts', { isFile: true }),
      ] as any);

      const result = await findTool.execute({
        pattern: '*.ts',
        showSize: true,
      });

      expect(result.isError).toBeFalsy();
      // Size is formatted as 1.0K for 1024 bytes
      expect(result.content).toMatch(/1\.0K|1024/);
    });

    it('should handle path not found', async () => {
      const error = new Error('ENOENT') as NodeJS.ErrnoException;
      error.code = 'ENOENT';
      vi.mocked(fs.stat).mockRejectedValue(error);

      const result = await findTool.execute({
        pattern: '*.ts',
        path: 'nonexistent',
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('not found');
    });

    it('should handle no matches found', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isDir: true }) as any);
      vi.mocked(fs.readdir).mockResolvedValue([
        mockDirent('file.js', { isFile: true }),
      ] as any);

      const result = await findTool.execute({
        pattern: '*.ts',
      });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('No files found');
    });

    it('should limit results to prevent overflow', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isDir: true }) as any);
      const files = Array.from({ length: 200 }, (_, i) =>
        mockDirent(`file${i}.ts`, { isFile: true })
      );
      vi.mocked(fs.readdir).mockResolvedValue(files as any);

      const result = await findTool.execute({
        pattern: '*.ts',
        maxResults: 50,
      });

      expect(result.isError).toBeFalsy();
      expect(result.details?.truncated).toBe(true);
    });

    it('should resolve relative paths against working directory', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isDir: true }) as any);
      vi.mocked(fs.readdir).mockResolvedValue([] as any);

      await findTool.execute({
        pattern: '*.ts',
        path: 'src',
      });

      expect(fs.stat).toHaveBeenCalledWith('/test/project/src');
    });

    it('should include file count in details', async () => {
      vi.mocked(fs.stat).mockResolvedValue(mockStat({ isDir: true }) as any);
      vi.mocked(fs.readdir).mockResolvedValue([
        mockDirent('file1.ts', { isFile: true }),
        mockDirent('file2.ts', { isFile: true }),
      ] as any);

      const result = await findTool.execute({
        pattern: '*.ts',
      });

      expect(result.details).toHaveProperty('fileCount', 2);
    });

    it('should sort results by modification time', async () => {
      vi.mocked(fs.stat)
        .mockResolvedValueOnce(mockStat({ isDir: true }) as any)
        .mockResolvedValueOnce(mockStat({ isFile: true, mtime: new Date('2024-01-01') }) as any)
        .mockResolvedValueOnce(mockStat({ isFile: true, mtime: new Date('2024-01-02') }) as any);
      vi.mocked(fs.readdir).mockResolvedValue([
        mockDirent('older.ts', { isFile: true }),
        mockDirent('newer.ts', { isFile: true }),
      ] as any);

      const result = await findTool.execute({
        pattern: '*.ts',
        sortByTime: true,
      });

      expect(result.isError).toBeFalsy();
      const content = result.content as string;
      expect(content.indexOf('newer.ts')).toBeLessThan(content.indexOf('older.ts'));
    });
  });
});
