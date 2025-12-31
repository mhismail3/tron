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
} from '../../src/types/messages.js';

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
});
