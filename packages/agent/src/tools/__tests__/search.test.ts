/**
 * @fileoverview Tests for unified Search tool
 *
 * TDD: Tests for unified text + AST search with auto-detection
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { SearchTool } from '../search/search.js';
import * as fs from 'fs/promises';
import { spawn } from 'child_process';

// Mock dependencies
vi.mock('fs/promises');
vi.mock('child_process');

describe('SearchTool', () => {
  let searchTool: SearchTool;

  beforeEach(() => {
    searchTool = new SearchTool({ workingDirectory: '/test/project' });
    vi.resetAllMocks();
  });

  describe('tool definition', () => {
    it('should have correct name and description', () => {
      expect(searchTool.name).toBe('Search');
      expect(searchTool.description).toContain('search');
    });

    it('should define pattern as required parameter', () => {
      const params = searchTool.parameters;
      expect(params.properties).toHaveProperty('pattern');
      expect(params.required).toContain('pattern');
    });

    it('should have search category', () => {
      expect(searchTool.category).toBe('search');
    });

    it('should accept type parameter to force search mode', () => {
      const params = searchTool.parameters;
      expect(params.properties).toHaveProperty('type');
    });
  });

  describe('mode detection', () => {
    it('should use text search by default', async () => {
      vi.mocked(fs.stat).mockResolvedValue({ isDirectory: () => true } as any);
      vi.mocked(fs.readdir).mockResolvedValue([]);

      const result = await searchTool.execute({ pattern: 'test' });

      expect(result.isError).toBeFalsy();
      expect(result.details).toHaveProperty('mode', 'text');
    });

    it('should detect AST mode from $VAR pattern', async () => {
      const mockProcess = {
        stdout: { on: vi.fn() },
        stderr: { on: vi.fn() },
        on: vi.fn((event, handler) => {
          if (event === 'close') handler(0);
        }),
      };
      vi.mocked(spawn).mockReturnValue(mockProcess as any);

      const result = await searchTool.execute({ pattern: 'function $NAME() {}' });

      expect(result.details).toHaveProperty('mode', 'ast');
    });

    it('should detect AST mode from $$$ pattern', async () => {
      const mockProcess = {
        stdout: { on: vi.fn() },
        stderr: { on: vi.fn() },
        on: vi.fn((event, handler) => {
          if (event === 'close') handler(0);
        }),
      };
      vi.mocked(spawn).mockReturnValue(mockProcess as any);

      const result = await searchTool.execute({ pattern: 'class { $$$ }' });

      expect(result.details).toHaveProperty('mode', 'ast');
    });

    it('should force text mode when type=text', async () => {
      vi.mocked(fs.stat).mockResolvedValue({ isDirectory: () => true } as any);
      vi.mocked(fs.readdir).mockResolvedValue([]);

      const result = await searchTool.execute({
        pattern: '$VAR',  // Would normally trigger AST
        type: 'text',     // But force text mode
      });

      expect(result.details).toHaveProperty('mode', 'text');
    });

    it('should force AST mode when type=ast', async () => {
      const mockProcess = {
        stdout: { on: vi.fn() },
        stderr: { on: vi.fn() },
        on: vi.fn((event, handler) => {
          if (event === 'close') handler(0);
        }),
      };
      vi.mocked(spawn).mockReturnValue(mockProcess as any);

      const result = await searchTool.execute({
        pattern: 'simple text',  // Would normally use text search
        type: 'ast',              // But force AST mode
      });

      expect(result.details).toHaveProperty('mode', 'ast');
    });
  });

  describe('text search', () => {
    it('should search file contents for pattern', async () => {
      vi.mocked(fs.stat).mockResolvedValue({ isDirectory: () => true } as any);
      vi.mocked(fs.readdir).mockResolvedValue([
        { name: 'file1.ts', isDirectory: () => false, isFile: () => true, isSymbolicLink: () => false },
      ] as any);
      vi.mocked(fs.readFile).mockResolvedValue('function test() {\n  return true;\n}');

      const result = await searchTool.execute({ pattern: 'test' });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('file1.ts');
      expect(result.content).toContain('test');
    });

    it('should support glob filtering', async () => {
      vi.mocked(fs.stat).mockResolvedValue({ isDirectory: () => true } as any);
      vi.mocked(fs.readdir).mockResolvedValue([
        { name: 'test.ts', isDirectory: () => false, isFile: () => true, isSymbolicLink: () => false },
        { name: 'test.js', isDirectory: () => false, isFile: () => true, isSymbolicLink: () => false },
      ] as any);
      vi.mocked(fs.readFile).mockResolvedValue('test content');

      const result = await searchTool.execute({
        pattern: 'test',
        filePattern: '*.ts',
      });

      expect(result.isError).toBeFalsy();
      // Should only search .ts files
    });

    it('should support context lines', async () => {
      vi.mocked(fs.stat).mockResolvedValue({ isDirectory: () => true } as any);
      vi.mocked(fs.readdir).mockResolvedValue([
        { name: 'file1.ts', isDirectory: () => false, isFile: () => true, isSymbolicLink: () => false },
      ] as any);
      vi.mocked(fs.readFile).mockResolvedValue('line 1\nline 2\nmatch\nline 4\nline 5');

      const result = await searchTool.execute({
        pattern: 'match',
        context: 1,
      });

      expect(result.isError).toBeFalsy();
      expect(result.content).toContain('line 2');
      expect(result.content).toContain('match');
      expect(result.content).toContain('line 4');
    });
  });

  describe('error handling', () => {
    it('should handle invalid path', async () => {
      const error = new Error('ENOENT') as NodeJS.ErrnoException;
      error.code = 'ENOENT';
      vi.mocked(fs.stat).mockRejectedValue(error);

      const result = await searchTool.execute({ pattern: 'test', path: 'nonexistent' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('not found');
    });

    it('should handle permission denied', async () => {
      const error = new Error('EACCES') as NodeJS.ErrnoException;
      error.code = 'EACCES';
      vi.mocked(fs.stat).mockRejectedValue(error);

      const result = await searchTool.execute({ pattern: 'test', path: 'protected' });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Permission denied');
    });
  });
});
