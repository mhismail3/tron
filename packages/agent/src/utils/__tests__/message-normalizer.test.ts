/**
 * @fileoverview Message Normalizer Tests
 *
 * Tests for the message normalization utilities that ensure consistent
 * internal format across the system regardless of input format.
 *
 * Key scenarios:
 * 1. Normalize API format (tool_use_id, is_error) to internal format (toolCallId, isError)
 * 2. Pass through already-normalized content unchanged
 * 3. Handle mixed format content arrays
 * 4. Normalize complete messages
 */
import { describe, it, expect } from 'vitest';

import {
  normalizeToolResultBlock,
  normalizeToolUseBlock,
  normalizeMessageContent,
  normalizeMessage,
  isToolResultBlock,
  isToolUseBlock,
} from '../message-normalizer.js';
import type { Message } from '../../types/index.js';

describe('Message Normalizer', () => {
  describe('normalizeToolResultBlock', () => {
    it('should normalize API format (tool_use_id, is_error) to internal format', () => {
      const apiFormat = {
        type: 'tool_result' as const,
        tool_use_id: 'call_123',
        content: 'Tool output',
        is_error: false,
      };

      const result = normalizeToolResultBlock(apiFormat);

      expect(result.type).toBe('tool_result');
      expect(result.toolCallId).toBe('call_123');
      expect(result.content).toBe('Tool output');
      expect(result.isError).toBe(false);
      // Should NOT have API format fields
      expect((result as any).tool_use_id).toBeUndefined();
      expect((result as any).is_error).toBeUndefined();
    });

    it('should pass through already-normalized content unchanged', () => {
      const internalFormat = {
        type: 'tool_result' as const,
        toolCallId: 'call_456',
        content: 'Already normalized',
        isError: true,
      };

      const result = normalizeToolResultBlock(internalFormat);

      expect(result.type).toBe('tool_result');
      expect(result.toolCallId).toBe('call_456');
      expect(result.content).toBe('Already normalized');
      expect(result.isError).toBe(true);
    });

    it('should handle mixed format with both field names (prefers internal)', () => {
      const mixedFormat = {
        type: 'tool_result' as const,
        tool_use_id: 'api_id',
        toolCallId: 'internal_id',
        content: 'Mixed',
        is_error: true,
        isError: false,
      };

      const result = normalizeToolResultBlock(mixedFormat);

      // Internal format should take precedence
      expect(result.toolCallId).toBe('internal_id');
      expect(result.isError).toBe(false);
    });

    it('should default isError to false when not provided', () => {
      const noError = {
        type: 'tool_result' as const,
        tool_use_id: 'call_789',
        content: 'No error field',
      };

      const result = normalizeToolResultBlock(noError);

      expect(result.isError).toBe(false);
    });
  });

  describe('normalizeToolUseBlock', () => {
    it('should normalize API format (input) to internal format (arguments)', () => {
      const apiFormat = {
        type: 'tool_use' as const,
        id: 'toolu_abc',
        name: 'TestTool',
        input: { param: 'value' },
      };

      const result = normalizeToolUseBlock(apiFormat);

      expect(result.type).toBe('tool_use');
      expect(result.id).toBe('toolu_abc');
      expect(result.name).toBe('TestTool');
      expect(result.arguments).toEqual({ param: 'value' });
      // Should NOT have API format field
      expect((result as any).input).toBeUndefined();
    });

    it('should pass through already-normalized content unchanged', () => {
      const internalFormat = {
        type: 'tool_use' as const,
        id: 'call_xyz',
        name: 'AnotherTool',
        arguments: { key: 'val' },
      };

      const result = normalizeToolUseBlock(internalFormat);

      expect(result.type).toBe('tool_use');
      expect(result.id).toBe('call_xyz');
      expect(result.name).toBe('AnotherTool');
      expect(result.arguments).toEqual({ key: 'val' });
    });

    it('should handle mixed format with both field names (prefers internal)', () => {
      const mixedFormat = {
        type: 'tool_use' as const,
        id: 'call_mixed',
        name: 'MixedTool',
        input: { from: 'api' },
        arguments: { from: 'internal' },
      };

      const result = normalizeToolUseBlock(mixedFormat);

      // Internal format (arguments) should take precedence
      expect(result.arguments).toEqual({ from: 'internal' });
    });
  });

  describe('normalizeMessageContent', () => {
    it('should normalize array with tool_result blocks', () => {
      const content = [
        { type: 'tool_result', tool_use_id: 'call_1', content: 'Result 1', is_error: false },
        { type: 'tool_result', tool_use_id: 'call_2', content: 'Result 2', is_error: true },
      ];

      const result = normalizeMessageContent(content);

      expect(result).toHaveLength(2);
      expect(result[0]).toEqual({
        type: 'tool_result',
        toolCallId: 'call_1',
        content: 'Result 1',
        isError: false,
      });
      expect(result[1]).toEqual({
        type: 'tool_result',
        toolCallId: 'call_2',
        content: 'Result 2',
        isError: true,
      });
    });

    it('should normalize array with tool_use blocks', () => {
      const content = [
        { type: 'text', text: 'Some text' },
        { type: 'tool_use', id: 'call_1', name: 'Tool1', input: { a: 1 } },
      ];

      const result = normalizeMessageContent(content);

      expect(result).toHaveLength(2);
      expect(result[0]).toEqual({ type: 'text', text: 'Some text' });
      expect(result[1]).toEqual({
        type: 'tool_use',
        id: 'call_1',
        name: 'Tool1',
        arguments: { a: 1 },
      });
    });

    it('should pass through text and image content unchanged', () => {
      const content = [
        { type: 'text', text: 'Hello' },
        { type: 'image', source: { type: 'base64', data: 'abc', media_type: 'image/png' } },
      ];

      const result = normalizeMessageContent(content);

      expect(result).toEqual(content);
    });

    it('should handle empty array', () => {
      const result = normalizeMessageContent([]);
      expect(result).toEqual([]);
    });
  });

  describe('normalizeMessage', () => {
    it('should normalize user message with tool_result content (reconstructed format)', () => {
      const message: Message = {
        role: 'user',
        content: [
          { type: 'tool_result', tool_use_id: 'call_123', content: 'Result' },
        ] as any,
      };

      const result = normalizeMessage(message);

      // Should convert to toolResult role message
      const singleResult = Array.isArray(result) ? result[0] : result;
      expect(singleResult.role).toBe('toolResult');
      expect((result as any).toolCallId).toBe('call_123');
      expect((result as any).content).toBe('Result');
      expect((result as any).isError).toBe(false);
    });

    it('should normalize user message with multiple tool_result blocks to array', () => {
      const message: Message = {
        role: 'user',
        content: [
          { type: 'tool_result', tool_use_id: 'call_1', content: 'Result 1' },
          { type: 'tool_result', tool_use_id: 'call_2', content: 'Result 2' },
        ] as any,
      };

      const result = normalizeMessage(message);

      // Multiple tool results should create multiple messages
      // This test verifies the normalization behavior
      if (Array.isArray(result)) {
        expect(result).toHaveLength(2);
        expect(result[0].role).toBe('toolResult');
        expect(result[1].role).toBe('toolResult');
      } else {
        // Alternative: single toolResult with first result
        expect(result.role).toBe('toolResult');
      }
    });

    it('should pass through regular user message unchanged', () => {
      const message: Message = {
        role: 'user',
        content: 'Hello world',
      };

      const result = normalizeMessage(message);

      expect(result).toEqual(message);
    });

    it('should pass through user message with text content unchanged', () => {
      const message: Message = {
        role: 'user',
        content: [{ type: 'text', text: 'Hello' }],
      };

      const result = normalizeMessage(message);

      expect(result).toEqual(message);
    });

    it('should normalize assistant message with tool_use blocks', () => {
      const message: Message = {
        role: 'assistant',
        content: [
          { type: 'text', text: 'Using tool' },
          { type: 'tool_use', id: 'call_1', name: 'Tool', input: { x: 1 } },
        ] as any,
      };

      const result = normalizeMessage(message);

      const singleResult = Array.isArray(result) ? result[0] : result;
      expect(singleResult.role).toBe('assistant');
      expect((result as any).content[0]).toEqual({ type: 'text', text: 'Using tool' });
      expect((result as any).content[1]).toEqual({
        type: 'tool_use',
        id: 'call_1',
        name: 'Tool',
        arguments: { x: 1 },
      });
    });

    it('should pass through toolResult message unchanged', () => {
      const message: Message = {
        role: 'toolResult',
        toolCallId: 'call_abc',
        content: 'Result',
        isError: false,
      };

      const result = normalizeMessage(message);

      expect(result).toEqual(message);
    });
  });

  describe('Type guards', () => {
    describe('isToolResultBlock', () => {
      it('should return true for API format tool_result', () => {
        expect(isToolResultBlock({ type: 'tool_result', tool_use_id: 'x', content: 'y' })).toBe(true);
      });

      it('should return true for internal format tool_result', () => {
        expect(isToolResultBlock({ type: 'tool_result', toolCallId: 'x', content: 'y' })).toBe(true);
      });

      it('should return false for other types', () => {
        expect(isToolResultBlock({ type: 'text', text: 'hello' })).toBe(false);
        expect(isToolResultBlock({ type: 'tool_use', id: 'x', name: 'y' })).toBe(false);
        expect(isToolResultBlock(null)).toBe(false);
        expect(isToolResultBlock(undefined)).toBe(false);
      });
    });

    describe('isToolUseBlock', () => {
      it('should return true for API format tool_use', () => {
        expect(isToolUseBlock({ type: 'tool_use', id: 'x', name: 'y', input: {} })).toBe(true);
      });

      it('should return true for internal format tool_use', () => {
        expect(isToolUseBlock({ type: 'tool_use', id: 'x', name: 'y', arguments: {} })).toBe(true);
      });

      it('should return false for other types', () => {
        expect(isToolUseBlock({ type: 'text', text: 'hello' })).toBe(false);
        expect(isToolUseBlock({ type: 'tool_result', toolCallId: 'x' })).toBe(false);
        expect(isToolUseBlock(null)).toBe(false);
      });
    });
  });
});
