/**
 * @fileoverview Tests for Edit tool
 *
 * TDD: Tests for file editing with search/replace
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import * as fs from 'fs/promises';
import { EditTool } from '../fs/edit.js';

// Mock fs/promises
vi.mock('fs/promises');

describe('EditTool', () => {
  let editTool: EditTool;

  beforeEach(() => {
    editTool = new EditTool({ workingDirectory: '/test/project' });
    vi.resetAllMocks();
  });

  describe('tool definition', () => {
    it('should have correct name and description', () => {
      expect(editTool.name).toBe('Edit');
      expect(editTool.description).toContain('file');
    });

    it('should define required parameters', () => {
      const params = editTool.parameters;
      expect(params.properties).toHaveProperty('file_path');
      expect(params.properties).toHaveProperty('old_string');
      expect(params.properties).toHaveProperty('new_string');
      expect(params.required).toContain('file_path');
      expect(params.required).toContain('old_string');
      expect(params.required).toContain('new_string');
    });

    it('should support optional replace_all parameter', () => {
      const params = editTool.parameters;
      expect(params.properties).toHaveProperty('replace_all');
    });
  });

  describe('execute', () => {
    it('should replace old_string with new_string', async () => {
      vi.mocked(fs.readFile).mockResolvedValue('Hello, world!');
      vi.mocked(fs.writeFile).mockResolvedValue();

      const result = await editTool.execute({
        file_path: '/test/file.txt',
        old_string: 'world',
        new_string: 'universe',
      });

      expect(result.isError).toBeFalsy();
      expect(fs.writeFile).toHaveBeenCalledWith(
        '/test/file.txt',
        'Hello, universe!',
        'utf-8'
      );
    });

    it('should replace unique string successfully', async () => {
      vi.mocked(fs.readFile).mockResolvedValue('foo bar baz');
      vi.mocked(fs.writeFile).mockResolvedValue();

      await editTool.execute({
        file_path: '/test/file.txt',
        old_string: 'foo',
        new_string: 'qux',
      });

      expect(fs.writeFile).toHaveBeenCalledWith(
        '/test/file.txt',
        'qux bar baz',
        'utf-8'
      );
    });

    it('should replace all occurrences when replace_all is true', async () => {
      vi.mocked(fs.readFile).mockResolvedValue('foo bar foo bar');
      vi.mocked(fs.writeFile).mockResolvedValue();

      await editTool.execute({
        file_path: '/test/file.txt',
        old_string: 'foo',
        new_string: 'baz',
        replace_all: true,
      });

      expect(fs.writeFile).toHaveBeenCalledWith(
        '/test/file.txt',
        'baz bar baz bar',
        'utf-8'
      );
    });

    it('should error if old_string not found', async () => {
      vi.mocked(fs.readFile).mockResolvedValue('Hello, world!');

      const result = await editTool.execute({
        file_path: '/test/file.txt',
        old_string: 'not found',
        new_string: 'replacement',
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('not found');
    });

    it('should error if old_string appears multiple times without replace_all', async () => {
      vi.mocked(fs.readFile).mockResolvedValue('foo bar foo bar');

      const result = await editTool.execute({
        file_path: '/test/file.txt',
        old_string: 'foo',
        new_string: 'baz',
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('multiple');
    });

    it('should handle file not found', async () => {
      const error = new Error('ENOENT: no such file or directory');
      (error as any).code = 'ENOENT';
      vi.mocked(fs.readFile).mockRejectedValue(error);

      const result = await editTool.execute({
        file_path: '/test/missing.txt',
        old_string: 'old',
        new_string: 'new',
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('not found');
    });

    it('should preserve multiline content', async () => {
      const content = 'line 1\nline 2\nline 3';
      vi.mocked(fs.readFile).mockResolvedValue(content);
      vi.mocked(fs.writeFile).mockResolvedValue();

      await editTool.execute({
        file_path: '/test/file.txt',
        old_string: 'line 2',
        new_string: 'modified line',
      });

      expect(fs.writeFile).toHaveBeenCalledWith(
        '/test/file.txt',
        'line 1\nmodified line\nline 3',
        'utf-8'
      );
    });

    it('should handle multiline old_string', async () => {
      const content = 'function foo() {\n  return 42;\n}';
      vi.mocked(fs.readFile).mockResolvedValue(content);
      vi.mocked(fs.writeFile).mockResolvedValue();

      await editTool.execute({
        file_path: '/test/file.txt',
        old_string: 'function foo() {\n  return 42;\n}',
        new_string: 'function foo() {\n  return 24;\n}',
      });

      expect(fs.writeFile).toHaveBeenCalledWith(
        '/test/file.txt',
        'function foo() {\n  return 24;\n}',
        'utf-8'
      );
    });

    it('should resolve relative paths against working directory', async () => {
      vi.mocked(fs.readFile).mockResolvedValue('content');
      vi.mocked(fs.writeFile).mockResolvedValue();

      await editTool.execute({
        file_path: 'relative/file.txt',
        old_string: 'content',
        new_string: 'new content',
      });

      expect(fs.readFile).toHaveBeenCalledWith(
        '/test/project/relative/file.txt',
        'utf-8'
      );
    });

    it('should include replacement count in details', async () => {
      vi.mocked(fs.readFile).mockResolvedValue('foo bar foo bar');
      vi.mocked(fs.writeFile).mockResolvedValue();

      const result = await editTool.execute({
        file_path: '/test/file.txt',
        old_string: 'foo',
        new_string: 'baz',
        replace_all: true,
      });

      expect(result.details).toHaveProperty('replacements', 2);
    });

    it('should error if old_string equals new_string', async () => {
      vi.mocked(fs.readFile).mockResolvedValue('Hello, world!');

      const result = await editTool.execute({
        file_path: '/test/file.txt',
        old_string: 'world',
        new_string: 'world',
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('same');
    });
  });
});
