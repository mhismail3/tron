/**
 * @fileoverview Tests for Tron tool types
 *
 * TDD: Tests for tool definitions and results.
 */

import { describe, it, expect } from 'vitest';
import type {
  Tool,
  TronTool,
  TronToolResult,
  ToolExecuteFunction,
} from '../../src/types/tools.js';

describe('Tool Types', () => {
  describe('Tool', () => {
    it('should define a basic tool schema', () => {
      const tool: Tool = {
        name: 'read',
        description: 'Read file contents',
        parameters: {
          type: 'object',
          properties: {
            path: { type: 'string', description: 'File path' },
          },
          required: ['path'],
        },
      };

      expect(tool.name).toBe('read');
      expect(tool.description).toBeTruthy();
      expect(tool.parameters).toBeDefined();
    });
  });

  describe('TronTool', () => {
    it('should define a tool with execute function', () => {
      const tool: TronTool<{ path: string }> = {
        name: 'read',
        label: 'Read File',
        description: 'Read file contents',
        parameters: {
          type: 'object',
          properties: {
            path: { type: 'string' },
          },
          required: ['path'],
        },
        execute: async (_toolCallId, _params, _signal) => {
          return {
            content: [{ type: 'text', text: 'file contents' }],
          };
        },
      };

      expect(tool.name).toBe('read');
      expect(tool.label).toBe('Read File');
      expect(typeof tool.execute).toBe('function');
    });

    it('should support details in result', () => {
      type ReadParams = { path: string };
      type ReadDetails = { totalLines: number; truncated: boolean };

      const tool: TronTool<ReadParams, ReadDetails> = {
        name: 'read',
        label: 'Read File',
        description: 'Read file contents',
        parameters: {
          type: 'object',
          properties: { path: { type: 'string' } },
          required: ['path'],
        },
        execute: async () => {
          return {
            content: [{ type: 'text', text: 'line1\nline2' }],
            details: { totalLines: 2, truncated: false },
          };
        },
      };

      expect(tool.name).toBe('read');
    });
  });

  describe('TronToolResult', () => {
    it('should define a successful result', () => {
      const result: TronToolResult = {
        content: [{ type: 'text', text: 'Success!' }],
      };

      expect(result.content.length).toBe(1);
      expect(result.isError).toBeUndefined();
    });

    it('should define an error result', () => {
      const result: TronToolResult = {
        content: [{ type: 'text', text: 'File not found' }],
        isError: true,
      };

      expect(result.isError).toBe(true);
    });

    it('should support image content in results', () => {
      const result: TronToolResult = {
        content: [
          { type: 'text', text: 'Screenshot:' },
          { type: 'image', data: 'base64data', mimeType: 'image/png' },
        ],
      };

      expect(result.content.length).toBe(2);
      expect(result.content[1]?.type).toBe('image');
    });

    it('should support typed details', () => {
      type FileDetails = { size: number; encoding: string };

      const result: TronToolResult<FileDetails> = {
        content: [{ type: 'text', text: 'content' }],
        details: { size: 1024, encoding: 'utf-8' },
      };

      expect(result.details?.size).toBe(1024);
    });
  });
});
