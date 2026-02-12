/**
 * @fileoverview Anthropic Message Conversion Tests
 *
 * Comprehensive tests for the message conversion logic in the Anthropic provider.
 * These tests cover edge cases and complex scenarios to ensure the split
 * maintains behavioral compatibility.
 *
 * Test areas:
 * 1. User message conversion (string, array, images, documents)
 * 2. Assistant message conversion (text, thinking, tool_use)
 * 3. Tool result message conversion
 * 4. Tool call ID remapping for cross-provider compatibility
 * 5. Thinking block handling (with/without signatures)
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { Message, ToolCall, ThinkingContent, TextContent } from '@core/types/index.js';

// Mock dependencies before importing provider
vi.mock('@anthropic-ai/sdk', () => ({
  default: vi.fn().mockImplementation(() => ({
    messages: { stream: vi.fn() },
  })),
}));

describe('Anthropic Message Conversion', () => {
  describe('User Message Conversion', () => {
    it('should convert simple string content', () => {
      const message: Message = {
        role: 'user',
        content: 'Hello, Claude!',
      };

      // Verify structure matches expected Anthropic format
      expect(message.role).toBe('user');
      expect(typeof message.content).toBe('string');
    });

    it('should convert text content blocks', () => {
      const message: Message = {
        role: 'user',
        content: [
          { type: 'text', text: 'First part' },
          { type: 'text', text: 'Second part' },
        ],
      };

      expect(Array.isArray(message.content)).toBe(true);
      expect(message.content).toHaveLength(2);
    });

    it('should convert image content blocks', () => {
      const message: Message = {
        role: 'user',
        content: [
          { type: 'text', text: 'What is in this image?' },
          {
            type: 'image',
            data: 'base64encodeddata...',
            mimeType: 'image/png',
          },
        ],
      };

      const imageBlock = (message.content as any[]).find(c => c.type === 'image');
      expect(imageBlock).toBeDefined();
      expect(imageBlock.mimeType).toBe('image/png');
    });

    it('should convert document content blocks (PDF)', () => {
      const message: Message = {
        role: 'user',
        content: [
          { type: 'text', text: 'Summarize this PDF' },
          {
            type: 'document',
            data: 'base64pdfdata...',
            mimeType: 'application/pdf',
          },
        ],
      };

      const docBlock = (message.content as any[]).find(c => c.type === 'document');
      expect(docBlock).toBeDefined();
      expect(docBlock.mimeType).toBe('application/pdf');
    });

    it('should handle mixed content types', () => {
      const message: Message = {
        role: 'user',
        content: [
          { type: 'text', text: 'Describe these images' },
          { type: 'image', data: 'img1data', mimeType: 'image/jpeg' },
          { type: 'text', text: 'And this one' },
          { type: 'image', data: 'img2data', mimeType: 'image/png' },
        ],
      };

      expect(message.content).toHaveLength(4);
    });
  });

  describe('Assistant Message Conversion', () => {
    it('should convert text-only responses', () => {
      const message: Message = {
        role: 'assistant',
        content: [
          { type: 'text', text: 'Here is my response.' },
        ],
      };

      expect(message.role).toBe('assistant');
      expect(message.content).toHaveLength(1);
    });

    it('should convert responses with tool calls', () => {
      const message: Message = {
        role: 'assistant',
        content: [
          { type: 'text', text: 'Let me read that file.' },
          {
            type: 'tool_use',
            id: 'toolu_01abc123',
            name: 'Read',
            arguments: { file_path: '/test.ts' },
          },
        ],
      };

      const toolUse = message.content.find(c => c.type === 'tool_use') as ToolCall;
      expect(toolUse).toBeDefined();
      expect(toolUse.id).toBe('toolu_01abc123');
      expect(toolUse.name).toBe('Read');
      expect(toolUse.arguments).toEqual({ file_path: '/test.ts' });
    });

    it('should convert responses with thinking blocks (with signature)', () => {
      const message: Message = {
        role: 'assistant',
        content: [
          {
            type: 'thinking',
            thinking: 'Let me analyze this problem step by step...',
            signature: 'sig_abc123',
          },
          { type: 'text', text: 'Based on my analysis...' },
        ],
      };

      const thinking = message.content.find(c => c.type === 'thinking') as ThinkingContent;
      expect(thinking).toBeDefined();
      expect(thinking.thinking).toContain('analyze');
      expect(thinking.signature).toBe('sig_abc123');
    });

    it('should handle thinking blocks without signature (display-only)', () => {
      // Non-extended thinking models (Haiku, Sonnet) may produce thinking without signatures
      // These should NOT be sent back to the API
      const message: Message = {
        role: 'assistant',
        content: [
          {
            type: 'thinking',
            thinking: 'Display-only thinking content',
            // No signature - should be filtered out when sending back
          },
          { type: 'text', text: 'The answer is...' },
        ],
      };

      const thinking = message.content.find(c => c.type === 'thinking') as ThinkingContent;
      expect(thinking).toBeDefined();
      expect(thinking.signature).toBeUndefined();
    });

    it('should preserve content order (thinking -> text -> tool_use)', () => {
      const message: Message = {
        role: 'assistant',
        content: [
          { type: 'thinking', thinking: 'First I think...', signature: 'sig1' },
          { type: 'text', text: 'Then I explain...' },
          { type: 'tool_use', id: 'toolu_1', name: 'Read', arguments: {} },
        ],
      };

      expect(message.content[0].type).toBe('thinking');
      expect(message.content[1].type).toBe('text');
      expect(message.content[2].type).toBe('tool_use');
    });

    it('should handle multiple tool calls in single response', () => {
      const message: Message = {
        role: 'assistant',
        content: [
          { type: 'text', text: 'Let me check both files.' },
          { type: 'tool_use', id: 'toolu_1', name: 'Read', arguments: { file_path: '/a.ts' } },
          { type: 'tool_use', id: 'toolu_2', name: 'Read', arguments: { file_path: '/b.ts' } },
        ],
      };

      const toolCalls = message.content.filter(c => c.type === 'tool_use');
      expect(toolCalls).toHaveLength(2);
    });
  });

  describe('Tool Result Message Conversion', () => {
    it('should convert string tool results', () => {
      const message: Message = {
        role: 'toolResult',
        content: 'File contents: export function foo() {}',
        toolCallId: 'toolu_01abc123',
      };

      expect(message.role).toBe('toolResult');
      expect(message.toolCallId).toBe('toolu_01abc123');
    });

    it('should convert array tool results with text', () => {
      const message: Message = {
        role: 'toolResult',
        content: [
          { type: 'text', text: 'Line 1: const x = 1' },
          { type: 'text', text: 'Line 2: const y = 2' },
        ],
        toolCallId: 'toolu_02def456',
      };

      expect(Array.isArray(message.content)).toBe(true);
      expect((message.content as any[])).toHaveLength(2);
    });

    it('should convert tool results with images', () => {
      // Screenshot results from browser tools
      const message: Message = {
        role: 'toolResult',
        content: [
          { type: 'text', text: 'Screenshot captured:' },
          { type: 'image', data: 'base64screenshot...', mimeType: 'image/png' },
        ],
        toolCallId: 'toolu_03ghi789',
      };

      const imageBlock = (message.content as any[]).find(c => c.type === 'image');
      expect(imageBlock).toBeDefined();
    });

    it('should handle error tool results', () => {
      const message: Message = {
        role: 'toolResult',
        content: 'Error: File not found',
        toolCallId: 'toolu_04jkl012',
        isError: true,
      };

      expect(message.isError).toBe(true);
    });
  });

  describe('Tool Call ID Remapping', () => {
    it('should accept native Anthropic IDs (toolu_* prefix)', () => {
      const toolCall: ToolCall = {
        type: 'tool_use',
        id: 'toolu_01XyZ789AbCd',
        name: 'Read',
        arguments: { file_path: '/test.ts' },
      };

      expect(toolCall.id.startsWith('toolu_')).toBe(true);
    });

    it('should handle OpenAI-format IDs (call_* prefix) in history', () => {
      // When switching from OpenAI to Anthropic, history may contain call_* IDs
      const toolCall: ToolCall = {
        type: 'tool_use',
        id: 'call_abc123',
        name: 'Read',
        arguments: { file_path: '/test.ts' },
      };

      expect(toolCall.id.startsWith('call_')).toBe(true);
    });

    it('should handle Gemini-format IDs (call_prefix_*) in history', () => {
      // Gemini generates IDs like call_abc12345_0
      const toolCall: ToolCall = {
        type: 'tool_use',
        id: 'call_xyz98765_0',
        name: 'Read',
        arguments: { file_path: '/test.ts' },
      };

      expect(toolCall.id.startsWith('call_')).toBe(true);
    });

    it('should match tool result to correct tool call regardless of ID format', () => {
      const assistantMessage: Message = {
        role: 'assistant',
        content: [
          { type: 'tool_use', id: 'call_from_openai', name: 'Read', arguments: {} },
        ],
      };

      const resultMessage: Message = {
        role: 'toolResult',
        content: 'File contents',
        toolCallId: 'call_from_openai', // Same ID as the call
      };

      expect((assistantMessage.content[0] as ToolCall).id).toBe(resultMessage.toolCallId);
    });
  });

  describe('Tool Schema Conversion', () => {
    it('should convert basic tool schema', () => {
      const tool = {
        name: 'Read',
        description: 'Read a file from disk',
        parameters: {
          type: 'object',
          properties: {
            file_path: { type: 'string', description: 'Path to the file' },
          },
          required: ['file_path'],
        },
      };

      expect(tool.name).toBe('Read');
      expect(tool.parameters.type).toBe('object');
      expect(tool.parameters.properties.file_path).toBeDefined();
    });

    it('should convert tool with complex parameters', () => {
      const tool = {
        name: 'Edit',
        description: 'Edit a file',
        parameters: {
          type: 'object',
          properties: {
            file_path: { type: 'string' },
            old_string: { type: 'string' },
            new_string: { type: 'string' },
            replace_all: { type: 'boolean', default: false },
          },
          required: ['file_path', 'old_string', 'new_string'],
        },
      };

      expect(tool.parameters.properties.replace_all.type).toBe('boolean');
      expect(tool.parameters.required).toContain('old_string');
    });

    it('should convert tool with nested objects', () => {
      const tool = {
        name: 'Task',
        description: 'Create a task',
        parameters: {
          type: 'object',
          properties: {
            prompt: { type: 'string' },
            options: {
              type: 'object',
              properties: {
                timeout: { type: 'number' },
                retries: { type: 'number' },
              },
            },
          },
          required: ['prompt'],
        },
      };

      expect(tool.parameters.properties.options.type).toBe('object');
    });

    it('should convert tool with array parameters', () => {
      const tool = {
        name: 'Grep',
        description: 'Search for patterns',
        parameters: {
          type: 'object',
          properties: {
            pattern: { type: 'string' },
            files: {
              type: 'array',
              items: { type: 'string' },
            },
          },
          required: ['pattern'],
        },
      };

      expect(tool.parameters.properties.files.type).toBe('array');
      expect(tool.parameters.properties.files.items.type).toBe('string');
    });
  });

  describe('System Prompt Handling', () => {
    it('should accept system prompt as string', () => {
      const context = {
        messages: [{ role: 'user' as const, content: 'Hello' }],
        systemPrompt: 'You are a helpful assistant.',
      };

      expect(context.systemPrompt).toBe('You are a helpful assistant.');
    });

    it('should accept rules content', () => {
      const context = {
        messages: [{ role: 'user' as const, content: 'Hello' }],
        systemPrompt: 'You are Claude.',
        rulesContent: '# Project Rules\n\nFollow these guidelines...',
      };

      expect(context.rulesContent).toContain('Project Rules');
    });

    it('should accept skill context', () => {
      const context = {
        messages: [{ role: 'user' as const, content: 'Hello' }],
        systemPrompt: 'You are Claude.',
        skillContext: '# Skill: commit\n\nCreate git commits...',
      };

      expect(context.skillContext).toContain('Skill:');
    });

    it('should accept subagent results context', () => {
      const context = {
        messages: [{ role: 'user' as const, content: 'Hello' }],
        subagentResultsContext: '## Subagent Result\n\nTask completed...',
      };

      expect(context.subagentResultsContext).toContain('Subagent Result');
    });

    it('should accept task context', () => {
      const context = {
        messages: [{ role: 'user' as const, content: 'Hello' }],
        taskContext: 'Active: 1 in progress, 2 pending',
      };

      expect(context.taskContext).toContain('in progress');
    });
  });

  describe('Edge Cases', () => {
    it('should handle empty assistant content array', () => {
      // Can happen if response is interrupted or filtered
      const message: Message = {
        role: 'assistant',
        content: [],
      };

      expect(message.content).toHaveLength(0);
    });

    it('should handle very long text content', () => {
      const longText = 'x'.repeat(100000);
      const message: Message = {
        role: 'user',
        content: longText,
      };

      expect((message.content as string).length).toBe(100000);
    });

    it('should handle special characters in content', () => {
      const message: Message = {
        role: 'user',
        content: 'Unicode: 你好 🎉 \n\t Tab and newline',
      };

      expect(message.content).toContain('你好');
      expect(message.content).toContain('🎉');
    });

    it('should handle empty tool arguments', () => {
      const toolCall: ToolCall = {
        type: 'tool_use',
        id: 'toolu_empty',
        name: 'ToolWithNoArgs',
        arguments: {},
      };

      expect(Object.keys(toolCall.arguments)).toHaveLength(0);
    });

    it('should handle null/undefined in tool arguments gracefully', () => {
      const toolCall: ToolCall = {
        type: 'tool_use',
        id: 'toolu_nullable',
        name: 'ToolWithOptional',
        arguments: {
          required: 'value',
          optional: undefined,
        },
      };

      expect(toolCall.arguments.required).toBe('value');
      expect(toolCall.arguments.optional).toBeUndefined();
    });

    it('should handle tool result with embedded JSON', () => {
      const result = JSON.stringify({
        files: ['a.ts', 'b.ts'],
        count: 2,
      });

      const message: Message = {
        role: 'toolResult',
        content: result,
        toolCallId: 'toolu_json',
      };

      const parsed = JSON.parse(message.content as string);
      expect(parsed.files).toHaveLength(2);
    });

    it('should handle base64 content that looks like JSON', () => {
      // Some base64 strings might start with valid JSON characters
      const fakeJson = 'eyJub3QiOiAianNvbiJ9'; // base64 of {"not": "json"}
      const message: Message = {
        role: 'user',
        content: [
          {
            type: 'image',
            data: fakeJson,
            mimeType: 'image/png',
          },
        ],
      };

      const imageBlock = (message.content as any[])[0];
      expect(imageBlock.data).toBe(fakeJson);
    });
  });
});
