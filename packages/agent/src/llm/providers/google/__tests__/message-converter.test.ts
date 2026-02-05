/**
 * @fileoverview Tests for Google Gemini message conversion
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

import { convertMessages, convertTools, sanitizeSchemaForGemini } from '../message-converter.js';
import type { Context } from '@core/types/index.js';

describe('Google Message Converter', () => {
  describe('convertMessages', () => {
    it('converts simple string user messages', () => {
      const context: Context = {
        messages: [{ role: 'user', content: 'Hello' }],
      };

      const result = convertMessages(context);

      expect(result).toEqual([
        { role: 'user', parts: [{ text: 'Hello' }] },
      ]);
    });

    it('converts user messages with text content blocks', () => {
      const context: Context = {
        messages: [{
          role: 'user',
          content: [
            { type: 'text', text: 'First part' },
            { type: 'text', text: 'Second part' },
          ],
        }],
      };

      const result = convertMessages(context);

      expect(result).toHaveLength(1);
      expect(result[0].parts).toHaveLength(2);
      expect(result[0].parts[0]).toEqual({ text: 'First part' });
    });

    it('converts image content to inlineData', () => {
      const context: Context = {
        messages: [{
          role: 'user',
          content: [
            { type: 'image', mimeType: 'image/png', data: 'base64data' },
          ],
        }],
      };

      const result = convertMessages(context);

      expect(result[0].parts[0]).toEqual({
        inlineData: { mimeType: 'image/png', data: 'base64data' },
      });
    });

    it('converts PDF documents to inlineData', () => {
      const context: Context = {
        messages: [{
          role: 'user',
          content: [
            { type: 'document', mimeType: 'application/pdf', data: 'pdfdata', fileName: 'doc.pdf' },
          ],
        }],
      };

      const result = convertMessages(context);

      expect(result[0].parts[0]).toEqual({
        inlineData: { mimeType: 'application/pdf', data: 'pdfdata' },
      });
    });

    it('skips unsupported document types', () => {
      const context: Context = {
        messages: [{
          role: 'user',
          content: [
            { type: 'document', mimeType: 'application/docx', data: 'data', fileName: 'doc.docx' },
          ],
        }],
      };

      const result = convertMessages(context);

      // No parts means no content added
      expect(result).toHaveLength(0);
    });

    it('converts assistant messages with text', () => {
      const context: Context = {
        messages: [{
          role: 'assistant',
          content: [{ type: 'text', text: 'Response text' }],
          usage: { inputTokens: 10, outputTokens: 5 },
          stopReason: 'end_turn',
        }],
      };

      const result = convertMessages(context);

      expect(result).toEqual([
        { role: 'model', parts: [{ text: 'Response text' }] },
      ]);
    });

    it('converts assistant tool calls with thoughtSignature', () => {
      const context: Context = {
        messages: [{
          role: 'assistant',
          content: [{
            type: 'tool_use',
            id: 'call_123',
            name: 'read_file',
            arguments: { path: '/test.txt' },
            thoughtSignature: 'sig123',
          }],
          usage: { inputTokens: 10, outputTokens: 5 },
          stopReason: 'tool_use',
        }],
      };

      const result = convertMessages(context);

      expect(result[0].role).toBe('model');
      const part = result[0].parts[0] as { functionCall: { name: string; args: Record<string, unknown> }; thoughtSignature: string };
      expect(part.functionCall.name).toBe('read_file');
      expect(part.functionCall.args).toEqual({ path: '/test.txt' });
      expect(part.thoughtSignature).toBe('sig123');
    });

    it('uses skip validator for tool calls without thoughtSignature', () => {
      const context: Context = {
        messages: [{
          role: 'assistant',
          content: [{
            type: 'tool_use',
            id: 'call_123',
            name: 'read_file',
            arguments: { path: '/test.txt' },
          }],
          usage: { inputTokens: 10, outputTokens: 5 },
          stopReason: 'tool_use',
        }],
      };

      const result = convertMessages(context);

      const part = result[0].parts[0] as { thoughtSignature: string };
      expect(part.thoughtSignature).toBe('skip_thought_signature_validator');
    });

    it('converts tool result messages', () => {
      const context: Context = {
        messages: [{
          role: 'toolResult',
          toolCallId: 'call_123',
          content: 'File contents here',
        }],
      };

      const result = convertMessages(context);

      expect(result[0].role).toBe('user');
      const part = result[0].parts[0] as { functionResponse: { name: string; response: Record<string, unknown> } };
      expect(part.functionResponse.name).toBe('tool_result');
      expect(part.functionResponse.response.result).toBe('File contents here');
    });

    it('converts tool result messages with content blocks', () => {
      const context: Context = {
        messages: [{
          role: 'toolResult',
          toolCallId: 'call_123',
          content: [
            { type: 'text', text: 'Line 1' },
            { type: 'text', text: 'Line 2' },
          ],
        }],
      };

      const result = convertMessages(context);

      const part = result[0].parts[0] as { functionResponse: { name: string; response: Record<string, unknown> } };
      expect(part.functionResponse.response.result).toBe('Line 1\nLine 2');
    });

    it('handles mixed message conversation', () => {
      const context: Context = {
        messages: [
          { role: 'user', content: 'Read the file' },
          {
            role: 'assistant',
            content: [{
              type: 'tool_use',
              id: 'call_1',
              name: 'read',
              arguments: { path: '/f.txt' },
            }],
            usage: { inputTokens: 10, outputTokens: 5 },
            stopReason: 'tool_use',
          },
          {
            role: 'toolResult',
            toolCallId: 'call_1',
            content: 'file contents',
          },
          {
            role: 'assistant',
            content: [{ type: 'text', text: 'Here is the file' }],
            usage: { inputTokens: 20, outputTokens: 10 },
            stopReason: 'end_turn',
          },
        ],
      };

      const result = convertMessages(context);

      expect(result).toHaveLength(4);
      expect(result[0].role).toBe('user');
      expect(result[1].role).toBe('model');
      expect(result[2].role).toBe('user'); // tool result
      expect(result[3].role).toBe('model');
    });
  });

  describe('convertTools', () => {
    it('wraps tools in functionDeclarations array', () => {
      const tools = [
        {
          name: 'read_file',
          description: 'Read a file',
          parameters: {
            type: 'object',
            properties: { path: { type: 'string' } },
            required: ['path'],
          },
        },
      ];

      const result = convertTools(tools);

      expect(result).toHaveLength(1);
      expect(result[0].functionDeclarations).toHaveLength(1);
      expect(result[0].functionDeclarations[0].name).toBe('read_file');
    });

    it('sanitizes schemas in tool parameters', () => {
      const tools = [
        {
          name: 'test',
          description: 'Test tool',
          parameters: {
            type: 'object',
            additionalProperties: false,
            $schema: 'http://json-schema.org/draft-07/schema#',
            properties: { x: { type: 'string' } },
          },
        },
      ];

      const result = convertTools(tools);

      const params = result[0].functionDeclarations[0].parameters;
      expect(params).not.toHaveProperty('additionalProperties');
      expect(params).not.toHaveProperty('$schema');
      expect(params).toHaveProperty('type', 'object');
    });
  });

  describe('sanitizeSchemaForGemini', () => {
    it('removes additionalProperties', () => {
      const schema = {
        type: 'object',
        additionalProperties: false,
        properties: { x: { type: 'string' } },
      };

      const result = sanitizeSchemaForGemini(schema);

      expect(result).not.toHaveProperty('additionalProperties');
      expect(result.type).toBe('object');
      expect(result.properties).toBeDefined();
    });

    it('removes $schema', () => {
      const schema = {
        $schema: 'http://json-schema.org/draft-07/schema#',
        type: 'object',
      };

      const result = sanitizeSchemaForGemini(schema);

      expect(result).not.toHaveProperty('$schema');
      expect(result.type).toBe('object');
    });

    it('recursively sanitizes nested objects', () => {
      const schema = {
        type: 'object',
        properties: {
          nested: {
            type: 'object',
            additionalProperties: true,
            properties: { y: { type: 'number' } },
          },
        },
      };

      const result = sanitizeSchemaForGemini(schema) as Record<string, Record<string, Record<string, unknown>>>;

      expect(result.properties.nested).not.toHaveProperty('additionalProperties');
      expect(result.properties.nested.type).toBe('object');
    });

    it('sanitizes arrays of objects', () => {
      const schema = {
        anyOf: [
          { type: 'string', additionalProperties: false },
          { type: 'number' },
        ],
      };

      const result = sanitizeSchemaForGemini(schema) as Record<string, Array<Record<string, unknown>>>;

      expect(result.anyOf[0]).not.toHaveProperty('additionalProperties');
      expect(result.anyOf[0].type).toBe('string');
      expect(result.anyOf[1].type).toBe('number');
    });

    it('handles null/undefined gracefully', () => {
      expect(sanitizeSchemaForGemini(null as unknown as Record<string, unknown>)).toBeNull();
      expect(sanitizeSchemaForGemini(undefined as unknown as Record<string, unknown>)).toBeUndefined();
    });
  });
});
