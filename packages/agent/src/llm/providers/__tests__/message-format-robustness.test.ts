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

import type { Message, Context, Tool } from '@core/types/index.js';
import { OpenAIProvider, convertToResponsesInput } from '../openai/index.js';
import { GoogleProvider, convertMessages as convertGoogleMessages } from '../google/index.js';

/**
 * Test helper: Create a minimal context with messages
 */
function createContext(messages: Message[]): Context {
  const tools: Tool[] = [
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
  ];

  return {
    messages,
    tools,
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

      // Use the exported function directly for testing
      const input = convertToResponsesInput(createContext(messages));

      // Should include function_call_output
      const functionOutput = input.find((i) => i.type === 'function_call_output');
      expect(functionOutput).toBeDefined();
      if (functionOutput && functionOutput.type === 'function_call_output') {
        expect(functionOutput.call_id).toBe('call_123');
        expect(functionOutput.output).toBe('Tool result content');
      }
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

      const input = convertToResponsesInput(createContext(messages));

      // Should remap toolu_01ABC123 to call_remap_0
      const functionCall = input.find((i) => i.type === 'function_call');
      const functionOutput = input.find((i) => i.type === 'function_call_output');

      expect(functionCall).toBeDefined();
      if (functionCall && functionCall.type === 'function_call') {
        expect(functionCall.call_id).toBe('call_remap_0');
      }
      expect(functionOutput).toBeDefined();
      if (functionOutput && functionOutput.type === 'function_call_output') {
        expect(functionOutput.call_id).toBe('call_remap_0');
      }
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

      const input = convertToResponsesInput(createContext(messages));

      const functionOutputs = input.filter((i) => i.type === 'function_call_output');
      expect(functionOutputs.length).toBe(2);
      const output1 = functionOutputs[0];
      const output2 = functionOutputs[1];
      if (output1 && output1.type === 'function_call_output') {
        expect(output1.call_id).toBe('call_1');
        expect(output1.output).toBe('Result 1');
      }
      if (output2 && output2.type === 'function_call_output') {
        expect(output2.call_id).toBe('call_2');
        expect(output2.output).toBe('Result 2');
      }
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
      const userWithFunctionResponse = converted.find((c) =>
        c.parts?.some((p) => 'functionResponse' in p && p.functionResponse)
      );
      expect(userWithFunctionResponse).toBeDefined();
    });
  });
});
