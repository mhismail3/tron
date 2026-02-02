/**
 * @fileoverview Tests for tool parameter validation
 *
 * TDD: These tests validate that tools handle missing/truncated parameters gracefully
 * instead of crashing with "Cannot read properties of undefined".
 *
 * Background: When LLM hits max output token limit, tool call JSON gets truncated,
 * causing required parameters to be missing. Tools must handle this gracefully.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { WriteTool } from '../fs/write.js';
import { BashTool } from '../system/bash.js';
import { EditTool } from '../fs/edit.js';

// Mock fs for Write and Edit tools
vi.mock('fs/promises', () => ({
  readFile: vi.fn().mockResolvedValue('existing content'),
  writeFile: vi.fn().mockResolvedValue(undefined),
  access: vi.fn().mockResolvedValue(undefined),
  mkdir: vi.fn().mockResolvedValue(undefined),
}));

describe('Tool Parameter Validation', () => {
  describe('WriteTool', () => {
    let writeTool: WriteTool;

    beforeEach(() => {
      writeTool = new WriteTool({ workingDirectory: '/tmp' });
    });

    it('should return error when content parameter is missing', async () => {
      const result = await writeTool.execute({
        file_path: '/tmp/test.txt',
        // content is missing - simulates truncated tool call
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Missing required parameter');
      expect(result.content).toContain('content');
    });

    it('should return error when content parameter is undefined', async () => {
      const result = await writeTool.execute({
        file_path: '/tmp/test.txt',
        content: undefined,
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Missing required parameter');
    });

    it('should return error when content parameter is null', async () => {
      const result = await writeTool.execute({
        file_path: '/tmp/test.txt',
        content: null,
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Missing required parameter');
    });

    it('should return error when file_path parameter is missing', async () => {
      const result = await writeTool.execute({
        content: 'some content',
        // file_path is missing
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Missing required parameter');
      expect(result.content).toContain('file_path');
    });

    it('should return error when both parameters are missing', async () => {
      const result = await writeTool.execute({});

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Missing required parameter');
    });

    it('should accept empty string as valid content', async () => {
      const result = await writeTool.execute({
        file_path: '/tmp/test.txt',
        content: '',
      });

      // Empty string is valid content (creates empty file)
      expect(result.isError).toBeFalsy();
    });
  });

  describe('BashTool', () => {
    let bashTool: BashTool;

    beforeEach(() => {
      bashTool = new BashTool({ workingDirectory: '/tmp' });
    });

    it('should return error when command parameter is missing', async () => {
      const result = await bashTool.execute({
        // command is missing - simulates truncated tool call
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Missing required parameter');
      expect(result.content).toContain('command');
    });

    it('should return error when command parameter is undefined', async () => {
      const result = await bashTool.execute({
        command: undefined,
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Missing required parameter');
    });

    it('should return error when command parameter is null', async () => {
      const result = await bashTool.execute({
        command: null,
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Missing required parameter');
    });

    it('should execute successfully with valid command', async () => {
      const result = await bashTool.execute({
        command: 'echo "hello"',
      });

      // Should succeed (or at least not crash on missing params)
      // The actual execution may fail in test environment, but not due to missing params
      expect(result.content).not.toContain('Missing required parameter');
    });
  });

  describe('EditTool', () => {
    let editTool: EditTool;

    beforeEach(() => {
      editTool = new EditTool({ workingDirectory: '/tmp' });
    });

    it('should return error when old_string parameter is missing', async () => {
      const result = await editTool.execute({
        file_path: '/tmp/test.txt',
        new_string: 'replacement',
        // old_string is missing
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Missing required parameter');
      expect(result.content).toContain('old_string');
    });

    it('should return error when new_string parameter is missing', async () => {
      const result = await editTool.execute({
        file_path: '/tmp/test.txt',
        old_string: 'original',
        // new_string is missing
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Missing required parameter');
      expect(result.content).toContain('new_string');
    });

    it('should return error when file_path parameter is missing', async () => {
      const result = await editTool.execute({
        old_string: 'original',
        new_string: 'replacement',
        // file_path is missing
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Missing required parameter');
      expect(result.content).toContain('file_path');
    });

    it('should return error when all required parameters are missing', async () => {
      const result = await editTool.execute({});

      expect(result.isError).toBe(true);
      expect(result.content).toContain('Missing required parameter');
    });

    it('should accept empty string as valid new_string (deletion)', async () => {
      const result = await editTool.execute({
        file_path: '/tmp/test.txt',
        old_string: 'content to delete',
        new_string: '',
      });

      // Empty string is valid for new_string (represents deletion)
      // Should not fail on "Missing required parameter"
      expect(result.content).not.toContain('Missing required parameter');
    });
  });

  describe('Error Message Quality', () => {
    it('should provide helpful error message mentioning truncation', async () => {
      const writeTool = new WriteTool({ workingDirectory: '/tmp' });
      const result = await writeTool.execute({
        file_path: '/tmp/test.txt',
        // content missing
      });

      expect(result.isError).toBe(true);
      // Error message should hint at possible cause
      const content = typeof result.content === 'string' ? result.content : '';
      expect(
        content.toLowerCase().includes('truncat') ||
        content.toLowerCase().includes('missing')
      ).toBe(true);
    });
  });
});
