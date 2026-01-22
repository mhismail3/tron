/**
 * @fileoverview Tests for Tron message types
 *
 * TDD: Write tests first, then implement types to make them pass.
 * These tests verify the structure and type safety of all message types
 * used in the Tron agent system.
 */

import { describe, it, expect } from 'vitest';
import type {
  Message,
  UserMessage,
  AssistantMessage,
  ToolResultMessage,
  TextContent,
  ImageContent,
  ThinkingContent,
  ToolCall,
  TokenUsage,
  Cost,
  StopReason,
  ApiToolUseBlock,
  ApiToolResultBlock,
} from '../messages.js';
import {
  toApiToolUse,
  fromApiToolUse,
  normalizeToolArguments,
  normalizeToolResultId,
  normalizeIsError,
  isApiToolResultBlock,
  isApiToolUseBlock,
} from '../messages.js';

describe('Message Types', () => {
  describe('UserMessage', () => {
    it('should define a user message with string content', () => {
      const msg: UserMessage = {
        role: 'user',
        content: 'Hello, Tron!',
      };

      expect(msg.role).toBe('user');
      expect(msg.content).toBe('Hello, Tron!');
    });

    it('should define a user message with content array', () => {
      const textContent: TextContent = { type: 'text', text: 'Describe this image' };
      const imageContent: ImageContent = {
        type: 'image',
        data: 'base64encodeddata',
        mimeType: 'image/png',
      };

      const msg: UserMessage = {
        role: 'user',
        content: [textContent, imageContent],
      };

      expect(msg.role).toBe('user');
      expect(Array.isArray(msg.content)).toBe(true);
      expect((msg.content as Array<TextContent | ImageContent>).length).toBe(2);
    });

    it('should support optional timestamp', () => {
      const msg: UserMessage = {
        role: 'user',
        content: 'Test',
        timestamp: Date.now(),
      };

      expect(msg.timestamp).toBeDefined();
      expect(typeof msg.timestamp).toBe('number');
    });
  });

  describe('AssistantMessage', () => {
    it('should define an assistant message with text content', () => {
      const textContent: TextContent = { type: 'text', text: 'Hello, user!' };

      const msg: AssistantMessage = {
        role: 'assistant',
        content: [textContent],
      };

      expect(msg.role).toBe('assistant');
      expect(msg.content.length).toBe(1);
      expect(msg.content[0]?.type).toBe('text');
    });

    it('should support thinking content', () => {
      const thinkingContent: ThinkingContent = {
        type: 'thinking',
        thinking: 'Let me analyze this...',
      };

      const msg: AssistantMessage = {
        role: 'assistant',
        content: [thinkingContent, { type: 'text', text: 'Here is my response' }],
      };

      expect(msg.content[0]?.type).toBe('thinking');
    });

    it('should support tool calls', () => {
      const toolCall: ToolCall = {
        type: 'tool_use',
        id: 'call_123',
        name: 'read_file',
        arguments: { path: '/test.txt' },
      };

      const msg: AssistantMessage = {
        role: 'assistant',
        content: [toolCall],
      };

      expect(msg.content[0]?.type).toBe('tool_use');
      expect((msg.content[0] as ToolCall).name).toBe('read_file');
    });

    it('should track token usage', () => {
      const usage: TokenUsage = {
        inputTokens: 100,
        outputTokens: 50,
        cacheReadTokens: 20,
        cacheCreationTokens: 10,
      };

      const msg: AssistantMessage = {
        role: 'assistant',
        content: [{ type: 'text', text: 'Response' }],
        usage,
      };

      expect(msg.usage?.inputTokens).toBe(100);
      expect(msg.usage?.outputTokens).toBe(50);
    });

    it('should track cost', () => {
      const cost: Cost = {
        inputCost: 0.003,
        outputCost: 0.015,
        total: 0.018,
        currency: 'USD',
      };

      const msg: AssistantMessage = {
        role: 'assistant',
        content: [{ type: 'text', text: 'Response' }],
        cost,
      };

      expect(msg.cost?.total).toBe(0.018);
    });

    it('should have stop reason', () => {
      const stopReasons: StopReason[] = ['end_turn', 'tool_use', 'max_tokens', 'stop_sequence'];

      stopReasons.forEach(reason => {
        const msg: AssistantMessage = {
          role: 'assistant',
          content: [{ type: 'text', text: 'Test' }],
          stopReason: reason,
        };

        expect(msg.stopReason).toBe(reason);
      });
    });
  });

  describe('ToolResultMessage', () => {
    it('should define a tool result message', () => {
      const msg: ToolResultMessage = {
        role: 'toolResult',
        toolCallId: 'call_123',
        content: 'File contents here',
      };

      expect(msg.role).toBe('toolResult');
      expect(msg.toolCallId).toBe('call_123');
    });

    it('should support content array with text and images', () => {
      const msg: ToolResultMessage = {
        role: 'toolResult',
        toolCallId: 'call_123',
        content: [
          { type: 'text', text: 'Screenshot captured' },
          { type: 'image', data: 'base64data', mimeType: 'image/png' },
        ],
      };

      expect(Array.isArray(msg.content)).toBe(true);
    });

    it('should track error state', () => {
      const msg: ToolResultMessage = {
        role: 'toolResult',
        toolCallId: 'call_123',
        content: 'File not found',
        isError: true,
      };

      expect(msg.isError).toBe(true);
    });
  });

  describe('Message union type', () => {
    it('should discriminate by role', () => {
      const messages: Message[] = [
        { role: 'user', content: 'Hello' },
        { role: 'assistant', content: [{ type: 'text', text: 'Hi' }] },
        { role: 'toolResult', toolCallId: 'call_1', content: 'result' },
      ];

      expect(messages.length).toBe(3);
      expect(messages[0]?.role).toBe('user');
      expect(messages[1]?.role).toBe('assistant');
      expect(messages[2]?.role).toBe('toolResult');
    });
  });

  describe('API Format Conversion Utilities', () => {
    describe('toApiToolUse', () => {
      it('should convert ToolCall to ApiToolUseBlock', () => {
        const toolCall: ToolCall = {
          type: 'tool_use',
          id: 'call_123',
          name: 'read_file',
          arguments: { path: '/test.txt', encoding: 'utf-8' },
        };

        const apiBlock = toApiToolUse(toolCall);

        expect(apiBlock.type).toBe('tool_use');
        expect(apiBlock.id).toBe('call_123');
        expect(apiBlock.name).toBe('read_file');
        expect(apiBlock.input).toEqual({ path: '/test.txt', encoding: 'utf-8' });
        // Verify 'arguments' is not present (should be 'input')
        expect('arguments' in apiBlock).toBe(false);
      });

      it('should handle empty arguments', () => {
        const toolCall: ToolCall = {
          type: 'tool_use',
          id: 'call_456',
          name: 'list_files',
          arguments: {},
        };

        const apiBlock = toApiToolUse(toolCall);

        expect(apiBlock.input).toEqual({});
      });
    });

    describe('fromApiToolUse', () => {
      it('should convert ApiToolUseBlock to ToolCall', () => {
        const apiBlock = {
          id: 'call_789',
          name: 'write_file',
          input: { path: '/output.txt', content: 'Hello' },
        };

        const toolCall = fromApiToolUse(apiBlock);

        expect(toolCall.type).toBe('tool_use');
        expect(toolCall.id).toBe('call_789');
        expect(toolCall.name).toBe('write_file');
        expect(toolCall.arguments).toEqual({ path: '/output.txt', content: 'Hello' });
        // Verify 'input' is not present (should be 'arguments')
        expect('input' in toolCall).toBe(false);
      });
    });

    describe('normalizeToolArguments', () => {
      it('should return input when present', () => {
        const args = normalizeToolArguments({ input: { foo: 'bar' } });
        expect(args).toEqual({ foo: 'bar' });
      });

      it('should return arguments when input is missing', () => {
        const args = normalizeToolArguments({ arguments: { baz: 'qux' } });
        expect(args).toEqual({ baz: 'qux' });
      });

      it('should prefer input over arguments', () => {
        const args = normalizeToolArguments({
          input: { fromInput: true },
          arguments: { fromArgs: true },
        });
        expect(args).toEqual({ fromInput: true });
      });

      it('should return empty object when neither present', () => {
        const args = normalizeToolArguments({});
        expect(args).toEqual({});
      });
    });

    describe('normalizeToolResultId', () => {
      it('should return tool_use_id when present', () => {
        const id = normalizeToolResultId({ tool_use_id: 'api_id' });
        expect(id).toBe('api_id');
      });

      it('should return toolCallId when tool_use_id is missing', () => {
        const id = normalizeToolResultId({ toolCallId: 'internal_id' });
        expect(id).toBe('internal_id');
      });

      it('should prefer tool_use_id over toolCallId', () => {
        const id = normalizeToolResultId({
          tool_use_id: 'api_id',
          toolCallId: 'internal_id',
        });
        expect(id).toBe('api_id');
      });

      it('should return empty string when neither present', () => {
        const id = normalizeToolResultId({});
        expect(id).toBe('');
      });
    });

    describe('normalizeIsError', () => {
      it('should return is_error when present', () => {
        expect(normalizeIsError({ is_error: true })).toBe(true);
        expect(normalizeIsError({ is_error: false })).toBe(false);
      });

      it('should return isError when is_error is missing', () => {
        expect(normalizeIsError({ isError: true })).toBe(true);
        expect(normalizeIsError({ isError: false })).toBe(false);
      });

      it('should prefer is_error over isError', () => {
        expect(normalizeIsError({ is_error: true, isError: false })).toBe(true);
        expect(normalizeIsError({ is_error: false, isError: true })).toBe(false);
      });

      it('should return false when neither present', () => {
        expect(normalizeIsError({})).toBe(false);
      });
    });
  });

  describe('API Format Type Guards', () => {
    describe('isApiToolResultBlock', () => {
      it('should return true for valid ApiToolResultBlock', () => {
        const block: ApiToolResultBlock = {
          type: 'tool_result',
          tool_use_id: 'call_123',
          content: 'result content',
        };

        expect(isApiToolResultBlock(block)).toBe(true);
      });

      it('should return true when is_error is present', () => {
        const block = {
          type: 'tool_result',
          tool_use_id: 'call_123',
          content: 'error message',
          is_error: true,
        };

        expect(isApiToolResultBlock(block)).toBe(true);
      });

      it('should return false for non-object', () => {
        expect(isApiToolResultBlock(null)).toBe(false);
        expect(isApiToolResultBlock('string')).toBe(false);
        expect(isApiToolResultBlock(123)).toBe(false);
      });

      it('should return false for wrong type', () => {
        expect(isApiToolResultBlock({ type: 'text', text: 'foo' })).toBe(false);
        expect(isApiToolResultBlock({ type: 'tool_use', id: '1', name: 'test', input: {} })).toBe(false);
      });

      it('should return false when tool_use_id is missing', () => {
        expect(isApiToolResultBlock({ type: 'tool_result', content: 'test' })).toBe(false);
      });
    });

    describe('isApiToolUseBlock', () => {
      it('should return true for valid ApiToolUseBlock', () => {
        const block: ApiToolUseBlock = {
          type: 'tool_use',
          id: 'call_123',
          name: 'test_tool',
          input: { arg: 'value' },
        };

        expect(isApiToolUseBlock(block)).toBe(true);
      });

      it('should return true for empty input', () => {
        const block = {
          type: 'tool_use',
          id: 'call_456',
          name: 'no_args_tool',
          input: {},
        };

        expect(isApiToolUseBlock(block)).toBe(true);
      });

      it('should return false for non-object', () => {
        expect(isApiToolUseBlock(null)).toBe(false);
        expect(isApiToolUseBlock('string')).toBe(false);
      });

      it('should return false for wrong type', () => {
        expect(isApiToolUseBlock({ type: 'text', text: 'foo' })).toBe(false);
        expect(isApiToolUseBlock({ type: 'tool_result', tool_use_id: '1', content: '' })).toBe(false);
      });

      it('should return false when id is missing', () => {
        expect(isApiToolUseBlock({ type: 'tool_use', name: 'test', input: {} })).toBe(false);
      });

      it('should return false when input is missing', () => {
        expect(isApiToolUseBlock({ type: 'tool_use', id: '1', name: 'test' })).toBe(false);
      });

      it('should return false for internal format with arguments instead of input', () => {
        const internalFormat = {
          type: 'tool_use',
          id: 'call_123',
          name: 'test_tool',
          arguments: { arg: 'value' },
        };

        expect(isApiToolUseBlock(internalFormat)).toBe(false);
      });
    });
  });
});
