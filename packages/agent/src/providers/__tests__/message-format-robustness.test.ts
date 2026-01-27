/**
 * @fileoverview Message Format Robustness Tests
 *
 * Tests that all providers correctly handle the internal message format:
 * - role='toolResult' with toolCallId, isError
 *
 * This is critical for:
 * - Session fork/resume across provider switches
 * - Message reconstruction from events
 * - Mid-session model switching
 */
import { describe, it, expect } from 'vitest';

import type { Message, ToolCall } from '../../types/index.js';
import { OpenAICodexProvider } from '../openai-codex.js';
import { OpenAIProvider } from '../openai.js';
import { GoogleProvider, convertMessages as convertGoogleMessages } from '../google/index.js';

/**
 * Test helper: Create a minimal context with messages
 */
function createContext(messages: Message[]) {
  return {
    messages,
    tools: [
      {
        name: 'TestTool',
        description: 'A test tool',
        parameters: {
          type: 'object',
          properties: {
            arg: { type: 'string' },
          },
          required: ['arg'],
        },
      },
    ],
  };
}

/**
 * Base messages that all format tests start with
 */
const baseMessages: Message[] = [
  {
    role: 'user',
    content: 'Test request',
  },
  {
    role: 'assistant',
    content: [
      { type: 'text', text: 'I will use a tool.' },
      {
        type: 'tool_use',
        id: 'call_123',
        name: 'TestTool',
        arguments: { arg: 'value' },
      },
    ],
  },
];

describe('Message Format Robustness', () => {
  describe('OpenAI Codex Provider', () => {
    it('should handle toolResult role messages (internal format)', () => {
      const messages: Message[] = [
        ...baseMessages,
        {
          role: 'toolResult',
          toolCallId: 'call_123',
          content: 'Tool result content',
          isError: false,
        },
      ];

      const provider = new OpenAICodexProvider({
        model: 'gpt-5.2-codex',
        auth: { type: 'oauth', accessToken: 'test', refreshToken: 'test', expiresAt: Date.now() + 3600000 },
      });

      // Access private method for testing
      const input = (provider as any).convertToResponsesInput(createContext(messages));

      // Should include function_call_output
      const functionOutput = input.find((i: any) => i.type === 'function_call_output');
      expect(functionOutput).toBeDefined();
      expect(functionOutput.call_id).toBe('call_123');
      expect(functionOutput.output).toBe('Tool result content');
    });

    it('should handle Anthropic tool call IDs with remapping', () => {
      // Anthropic format tool call ID
      const messages: Message[] = [
        {
          role: 'user',
          content: 'Test request',
        },
        {
          role: 'assistant',
          content: [
            { type: 'text', text: 'I will use a tool.' },
            {
              type: 'tool_use',
              id: 'toolu_01ABC123',
              name: 'TestTool',
              arguments: { arg: 'value' },
            },
          ],
        },
        {
          role: 'toolResult',
          toolCallId: 'toolu_01ABC123',
          content: 'Tool result content',
          isError: false,
        },
      ];

      const provider = new OpenAICodexProvider({
        model: 'gpt-5.2-codex',
        auth: { type: 'oauth', accessToken: 'test', refreshToken: 'test', expiresAt: Date.now() + 3600000 },
      });

      const input = (provider as any).convertToResponsesInput(createContext(messages));

      // Should remap toolu_01ABC123 to call_remap_0
      const functionCall = input.find((i: any) => i.type === 'function_call');
      const functionOutput = input.find((i: any) => i.type === 'function_call_output');

      expect(functionCall).toBeDefined();
      expect(functionCall.call_id).toBe('call_remap_0');
      expect(functionOutput).toBeDefined();
      expect(functionOutput.call_id).toBe('call_remap_0');
    });

    it('should handle multiple tool results', () => {
      const messages: Message[] = [
        {
          role: 'user',
          content: 'Test request',
        },
        {
          role: 'assistant',
          content: [
            { type: 'tool_use', id: 'call_1', name: 'TestTool', arguments: { arg: '1' } },
            { type: 'tool_use', id: 'call_2', name: 'TestTool', arguments: { arg: '2' } },
          ],
        },
        // Multiple tool results using internal format
        {
          role: 'toolResult',
          toolCallId: 'call_1',
          content: 'Result 1',
          isError: false,
        },
        {
          role: 'toolResult',
          toolCallId: 'call_2',
          content: 'Result 2',
          isError: false,
        },
      ];

      const provider = new OpenAICodexProvider({
        model: 'gpt-5.2-codex',
        auth: { type: 'oauth', accessToken: 'test', refreshToken: 'test', expiresAt: Date.now() + 3600000 },
      });

      const input = (provider as any).convertToResponsesInput(createContext(messages));

      const functionOutputs = input.filter((i: any) => i.type === 'function_call_output');
      expect(functionOutputs.length).toBe(2);
      expect(functionOutputs[0].call_id).toBe('call_1');
      expect(functionOutputs[0].output).toBe('Result 1');
      expect(functionOutputs[1].call_id).toBe('call_2');
      expect(functionOutputs[1].output).toBe('Result 2');
    });
  });

  describe('OpenAI Provider', () => {
    it('should handle toolResult role messages (internal format)', () => {
      const messages: Message[] = [
        ...baseMessages,
        {
          role: 'toolResult',
          toolCallId: 'call_123',
          content: 'Tool result content',
          isError: false,
        },
      ];

      const provider = new OpenAIProvider({
        model: 'gpt-4o',
        apiKey: 'test-key',
      });

      const converted = (provider as any).convertMessages(createContext(messages));

      // Should include tool message
      const toolMessage = converted.find((m: any) => m.role === 'tool');
      expect(toolMessage).toBeDefined();
      expect(toolMessage.tool_call_id).toBe('call_123');
      expect(toolMessage.content).toBe('Tool result content');
    });

  });

  describe('Google Provider', () => {
    it('should handle toolResult role messages (internal format)', () => {
      const messages: Message[] = [
        ...baseMessages,
        {
          role: 'toolResult',
          toolCallId: 'call_123',
          content: 'Tool result content',
          isError: false,
        },
      ];

      // Use the exported convertMessages function directly
      const converted = convertGoogleMessages(createContext(messages));

      // Should include functionResponse
      const userWithFunctionResponse = converted.find(
        (c: any) => c.parts?.some((p: any) => p.functionResponse)
      );
      expect(userWithFunctionResponse).toBeDefined();
    });

  });
});
