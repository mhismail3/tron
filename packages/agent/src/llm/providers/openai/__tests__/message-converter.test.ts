/**
 * @fileoverview Tests for OpenAI message converter
 */

import { describe, it, expect, vi } from 'vitest';

vi.mock('@infrastructure/logging/index.js', () => ({
  createLogger: vi.fn(() => ({
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
    debug: vi.fn(),
  })),
}));

import {
  convertToResponsesInput,
  convertTools,
  generateToolClarificationMessage,
} from '../message-converter.js';
import type { Context } from '@core/types/index.js';

describe('OpenAI Message Converter', () => {
  describe('convertToResponsesInput', () => {
    it('converts string user messages', () => {
      const context: Context = {
        messages: [{ role: 'user', content: 'Hello' }],
      };

      const result = convertToResponsesInput(context);

      expect(result).toEqual([{
        type: 'message',
        role: 'user',
        content: [{ type: 'input_text', text: 'Hello' }],
      }]);
    });

    it('converts user messages with text content blocks', () => {
      const context: Context = {
        messages: [{
          role: 'user',
          content: [
            { type: 'text', text: 'Part 1' },
            { type: 'text', text: 'Part 2' },
          ],
        }],
      };

      const result = convertToResponsesInput(context);

      expect(result).toHaveLength(1);
      expect(result[0].content).toHaveLength(2);
      expect(result[0].content[0]).toEqual({ type: 'input_text', text: 'Part 1' });
    });

    it('converts image content to input_image format', () => {
      const context: Context = {
        messages: [{
          role: 'user',
          content: [
            { type: 'image', mimeType: 'image/png', data: 'base64data' },
          ],
        }],
      };

      const result = convertToResponsesInput(context);

      expect(result[0].content[0]).toEqual({
        type: 'input_image',
        image_url: 'data:image/png;base64,base64data',
        detail: 'auto',
      });
    });

    it('converts document content to placeholder text', () => {
      const context: Context = {
        messages: [{
          role: 'user',
          content: [
            { type: 'document', mimeType: 'application/pdf', data: 'data', fileName: 'doc.pdf' },
          ],
        }],
      };

      const result = convertToResponsesInput(context);

      expect(result[0].content[0]).toEqual({
        type: 'input_text',
        text: '[Document: doc.pdf (application/pdf)]',
      });
    });

    it('converts assistant messages with text', () => {
      const context: Context = {
        messages: [{
          role: 'assistant',
          content: [{ type: 'text', text: 'Response' }],
          usage: { inputTokens: 10, outputTokens: 5 },
          stopReason: 'end_turn',
        }],
      };

      const result = convertToResponsesInput(context);

      expect(result).toEqual([{
        type: 'message',
        role: 'assistant',
        content: [{ type: 'output_text', text: 'Response' }],
      }]);
    });

    it('converts assistant tool calls to function_call items', () => {
      const context: Context = {
        messages: [{
          role: 'assistant',
          content: [{
            type: 'tool_use',
            id: 'call_abc',
            name: 'read_file',
            arguments: { path: '/test.txt' },
          }],
          usage: { inputTokens: 10, outputTokens: 5 },
          stopReason: 'tool_use',
        }],
      };

      const result = convertToResponsesInput(context);

      const funcCall = result.find(r => r.type === 'function_call');
      expect(funcCall).toBeDefined();
      expect(funcCall!.name).toBe('read_file');
      expect(funcCall!.arguments).toBe('{"path":"/test.txt"}');
    });

    it('converts tool results to function_call_output', () => {
      const context: Context = {
        messages: [{
          role: 'toolResult',
          toolCallId: 'call_abc',
          content: 'File contents here',
        }],
      };

      const result = convertToResponsesInput(context);

      expect(result).toEqual([{
        type: 'function_call_output',
        call_id: expect.any(String),
        output: 'File contents here',
      }]);
    });

    it('converts tool results with content blocks', () => {
      const context: Context = {
        messages: [{
          role: 'toolResult',
          toolCallId: 'call_abc',
          content: [
            { type: 'text', text: 'Line 1' },
            { type: 'text', text: 'Line 2' },
          ],
        }],
      };

      const result = convertToResponsesInput(context);

      expect(result[0].output).toBe('Line 1\nLine 2');
    });

    it('truncates long tool results at 16k', () => {
      const longOutput = 'x'.repeat(20000);
      const context: Context = {
        messages: [{
          role: 'toolResult',
          toolCallId: 'call_abc',
          content: longOutput,
        }],
      };

      const result = convertToResponsesInput(context);

      expect(result[0].output.length).toBeLessThanOrEqual(16020); // 16000 + truncation message
      expect(result[0].output).toContain('[truncated]');
    });

    it('handles mixed conversation with text, tool calls, and results', () => {
      const context: Context = {
        messages: [
          { role: 'user', content: 'Read file' },
          {
            role: 'assistant',
            content: [
              { type: 'text', text: 'Reading...' },
              { type: 'tool_use', id: 'call_1', name: 'read', arguments: { path: '/f.txt' } },
            ],
            usage: { inputTokens: 10, outputTokens: 15 },
            stopReason: 'tool_use',
          },
          { role: 'toolResult', toolCallId: 'call_1', content: 'file data' },
        ],
      };

      const result = convertToResponsesInput(context);

      // user message + assistant text + function_call + function_call_output
      expect(result).toHaveLength(4);
      expect(result[0].type).toBe('message');
      expect(result[1].type).toBe('message'); // assistant text
      expect(result[2].type).toBe('function_call');
      expect(result[3].type).toBe('function_call_output');
    });

    it('handles assistant with empty arguments', () => {
      const context: Context = {
        messages: [{
          role: 'assistant',
          content: [{
            type: 'tool_use',
            id: 'call_1',
            name: 'get_status',
            arguments: undefined as unknown as Record<string, unknown>,
          }],
          usage: { inputTokens: 10, outputTokens: 5 },
          stopReason: 'tool_use',
        }],
      };

      const result = convertToResponsesInput(context);

      const funcCall = result.find(r => r.type === 'function_call');
      expect(funcCall!.arguments).toBe('{}');
    });
  });

  describe('convertTools', () => {
    it('converts tools to Responses API format', () => {
      const tools = [
        {
          name: 'read_file',
          description: 'Read a file from disk',
          parameters: {
            type: 'object',
            properties: { path: { type: 'string' } },
            required: ['path'],
          },
        },
      ];

      const result = convertTools(tools);

      expect(result).toEqual([{
        type: 'function',
        name: 'read_file',
        description: 'Read a file from disk',
        parameters: {
          type: 'object',
          properties: { path: { type: 'string' } },
          required: ['path'],
        },
      }]);
    });

    it('converts multiple tools', () => {
      const tools = [
        { name: 'tool_a', description: 'Tool A', parameters: {} },
        { name: 'tool_b', description: 'Tool B', parameters: {} },
      ];

      const result = convertTools(tools);

      expect(result).toHaveLength(2);
      expect(result[0].name).toBe('tool_a');
      expect(result[1].name).toBe('tool_b');
    });
  });

  describe('generateToolClarificationMessage', () => {
    it('includes tool names and descriptions', () => {
      const tools = [
        {
          name: 'Bash',
          description: 'Run bash commands',
          parameters: {
            type: 'object',
            properties: { command: { type: 'string' } },
            required: ['command'],
          },
        },
      ];

      const result = generateToolClarificationMessage(tools);

      expect(result).toContain('Bash');
      expect(result).toContain('Run bash commands');
      expect(result).toContain('required params: command');
    });

    it('includes working directory when provided', () => {
      const result = generateToolClarificationMessage([], '/home/user/project');

      expect(result).toContain('/home/user/project');
    });

    it('includes Tron identity', () => {
      const result = generateToolClarificationMessage([]);

      expect(result).toContain('TRON');
      expect(result).toContain('AI coding assistant');
    });

    it('includes Bash tool capabilities section', () => {
      const result = generateToolClarificationMessage([]);

      expect(result).toContain('Bash Tool Capabilities');
      expect(result).toContain('Network access');
      expect(result).toContain('curl');
    });
  });
});
