/**
 * @fileoverview Tests for the agent loop
 *
 * TDD: Tests for the core agent execution loop
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import type {
  AgentConfig,
  AgentOptions,
  TurnResult,
} from '../types.js';
import type { Context, StreamEvent, AssistantMessage } from '../../types/index.js';

describe('Agent Loop', () => {
  describe('AgentConfig', () => {
    it('should define required configuration', () => {
      const config: AgentConfig = {
        provider: {
          model: 'claude-sonnet-4-20250514',
          auth: { type: 'api_key', apiKey: 'test-key' },
        },
        tools: [],
        systemPrompt: 'You are a helpful assistant.',
      };

      expect(config.provider).toBeDefined();
      expect(config.tools).toBeInstanceOf(Array);
      expect(config.systemPrompt).toBeTruthy();
    });

    it('should support optional parameters', () => {
      const config: AgentConfig = {
        provider: {
          model: 'claude-sonnet-4-20250514',
          auth: { type: 'api_key', apiKey: 'test-key' },
        },
        tools: [],
        maxTokens: 4096,
        temperature: 0.7,
        maxTurns: 50,
        enableThinking: true,
        thinkingBudget: 2048,
      };

      expect(config.maxTokens).toBe(4096);
      expect(config.temperature).toBe(0.7);
      expect(config.maxTurns).toBe(50);
      expect(config.enableThinking).toBe(true);
    });
  });

  describe('AgentOptions', () => {
    it('should define runtime options', () => {
      const options: AgentOptions = {
        sessionId: 'sess_123',
        workingDirectory: '/project',
        onEvent: (event) => {},
        signal: new AbortController().signal,
      };

      expect(options.sessionId).toBe('sess_123');
      expect(options.workingDirectory).toBe('/project');
      expect(typeof options.onEvent).toBe('function');
    });
  });

  describe('TurnResult', () => {
    it('should define a successful turn', () => {
      const result: TurnResult = {
        success: true,
        message: {
          role: 'assistant',
          content: [{ type: 'text', text: 'Hello!' }],
          stopReason: 'end_turn',
        },
        toolCallsExecuted: 0,
        tokenUsage: {
          inputTokens: 100,
          outputTokens: 50,
        },
      };

      expect(result.success).toBe(true);
      expect(result.message?.role).toBe('assistant');
    });

    it('should define a turn with tool calls', () => {
      const result: TurnResult = {
        success: true,
        message: {
          role: 'assistant',
          content: [
            { type: 'text', text: 'Let me read that file.' },
            {
              type: 'tool_use',
              id: 'tool_123',
              name: 'Read',
              arguments: { file_path: '/test.txt' },
            },
          ],
          stopReason: 'tool_use',
        },
        toolCallsExecuted: 1,
        tokenUsage: { inputTokens: 100, outputTokens: 80 },
      };

      expect(result.toolCallsExecuted).toBe(1);
      expect(result.message?.stopReason).toBe('tool_use');
    });

    it('should define a failed turn', () => {
      const result: TurnResult = {
        success: false,
        error: 'Rate limit exceeded',
        tokenUsage: { inputTokens: 0, outputTokens: 0 },
      };

      expect(result.success).toBe(false);
      expect(result.error).toBe('Rate limit exceeded');
    });
  });
});
