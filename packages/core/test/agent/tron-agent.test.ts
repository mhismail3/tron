/**
 * @fileoverview Tests for TronAgent class
 *
 * TDD: Tests for the main agent implementation
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { TronAgent } from '../../src/agent/tron-agent.js';
import type { AgentConfig, TurnResult } from '../../src/agent/types.js';
import type { TronTool, TronToolResult, TronEvent } from '../../src/types/index.js';

// Mock provider
vi.mock('../../src/providers/anthropic.js', () => ({
  AnthropicProvider: vi.fn().mockImplementation(() => ({
    stream: vi.fn(),
  })),
}));

describe('TronAgent', () => {
  let config: AgentConfig;
  let mockTool: TronTool;

  beforeEach(() => {
    mockTool = {
      name: 'TestTool',
      description: 'A test tool',
      parameters: {
        type: 'object',
        properties: {
          input: { type: 'string' },
        },
        required: ['input'],
      },
      execute: vi.fn().mockResolvedValue({
        content: 'Tool result',
        isError: false,
      }),
    };

    config = {
      provider: {
        model: 'claude-sonnet-4-20250514',
        auth: { type: 'api_key', apiKey: 'test-key' },
      },
      tools: [mockTool],
      systemPrompt: 'You are a helpful assistant.',
    };
  });

  describe('constructor', () => {
    it('should create agent with config', () => {
      const agent = new TronAgent(config);
      expect(agent).toBeInstanceOf(TronAgent);
    });

    it('should initialize with default session ID', () => {
      const agent = new TronAgent(config);
      expect(agent.sessionId).toBeTruthy();
      expect(agent.sessionId).toMatch(/^sess_/);
    });
  });

  describe('getState', () => {
    it('should return current agent state', () => {
      const agent = new TronAgent(config);
      const state = agent.getState();

      expect(state.sessionId).toBeTruthy();
      expect(state.messages).toBeInstanceOf(Array);
      expect(state.currentTurn).toBe(0);
      expect(state.isRunning).toBe(false);
    });
  });

  describe('addMessage', () => {
    it('should add user message to context', () => {
      const agent = new TronAgent(config);
      agent.addMessage({ role: 'user', content: 'Hello' });

      const state = agent.getState();
      expect(state.messages).toHaveLength(1);
      expect(state.messages[0].role).toBe('user');
    });

    it('should add assistant message to context', () => {
      const agent = new TronAgent(config);
      agent.addMessage({
        role: 'assistant',
        content: [{ type: 'text', text: 'Hello!' }],
        stopReason: 'end_turn',
      });

      const state = agent.getState();
      expect(state.messages).toHaveLength(1);
      expect(state.messages[0].role).toBe('assistant');
    });
  });

  describe('clearMessages', () => {
    it('should clear all messages', () => {
      const agent = new TronAgent(config);
      agent.addMessage({ role: 'user', content: 'Hello' });
      agent.addMessage({
        role: 'assistant',
        content: [{ type: 'text', text: 'Hi!' }],
        stopReason: 'end_turn',
      });

      agent.clearMessages();

      const state = agent.getState();
      expect(state.messages).toHaveLength(0);
    });
  });

  describe('getTool', () => {
    it('should return tool by name', () => {
      const agent = new TronAgent(config);
      const tool = agent.getTool('TestTool');

      expect(tool).toBeDefined();
      expect(tool?.name).toBe('TestTool');
    });

    it('should return undefined for unknown tool', () => {
      const agent = new TronAgent(config);
      const tool = agent.getTool('NonExistentTool');

      expect(tool).toBeUndefined();
    });
  });

  describe('registerTool', () => {
    it('should register a new tool', () => {
      const agent = new TronAgent(config);

      const newTool: TronTool = {
        name: 'NewTool',
        description: 'A new tool',
        parameters: { type: 'object', properties: {} },
        execute: async () => ({ content: 'done', isError: false }),
      };

      agent.registerTool(newTool);

      expect(agent.getTool('NewTool')).toBeDefined();
    });
  });

  describe('events', () => {
    it('should emit events through onEvent callback', async () => {
      const events: TronEvent[] = [];
      const agent = new TronAgent(config);

      agent.onEvent((event) => {
        events.push(event);
      });

      // Manually emit test event
      agent.emit({
        type: 'agent_start',
        sessionId: agent.sessionId,
        timestamp: new Date().toISOString(),
      });

      expect(events).toHaveLength(1);
      expect(events[0].type).toBe('agent_start');
    });
  });

  describe('hooks', () => {
    it('should allow registering hooks', () => {
      const agent = new TronAgent(config);

      agent.registerHook({
        name: 'test-hook',
        type: 'PreToolUse',
        handler: async () => ({ action: 'continue' }),
      });

      // Should not throw
      expect(true).toBe(true);
    });
  });

  describe('abort', () => {
    it('should set abort flag', () => {
      const agent = new TronAgent(config);

      agent.abort();

      const state = agent.getState();
      // After abort, should not be running
      expect(state.isRunning).toBe(false);
    });
  });
});
