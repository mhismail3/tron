/**
 * @fileoverview TUI Types Tests
 *
 * Tests for type definitions and validation.
 */
import { describe, it, expect } from 'vitest';
import type {
  CliConfig,
  AppState,
  AppAction,
  DisplayMessage,
  HeaderProps,
  MessageListProps,
  InputAreaProps,
  StatusBarProps,
} from '../src/types.js';

describe('TUI Types', () => {
  describe('CliConfig', () => {
    it('should define required workingDirectory', () => {
      const config: CliConfig = {
        workingDirectory: '/test/path',
      };
      expect(config.workingDirectory).toBe('/test/path');
    });

    it('should support optional fields', () => {
      const config: CliConfig = {
        workingDirectory: '/test/path',
        model: 'claude-sonnet-4-20250514',
        provider: 'anthropic',
        resumeSession: 'session-123',
        serverMode: true,
        wsPort: 8080,
        healthPort: 8081,
        verbose: true,
        nonInteractive: true,
        initialPrompt: 'Hello',
      };
      expect(config.model).toBe('claude-sonnet-4-20250514');
      expect(config.serverMode).toBe(true);
    });
  });

  describe('AppState', () => {
    it('should define complete state structure', () => {
      const state: AppState = {
        input: 'test input',
        isProcessing: false,
        sessionId: 'sess_123',
        messages: [],
        status: 'Ready',
        error: null,
        tokenUsage: { input: 100, output: 50 },
        activeTool: null,
      };
      expect(state.sessionId).toBe('sess_123');
      expect(state.tokenUsage.input).toBe(100);
    });

    it('should support processing state', () => {
      const state: AppState = {
        input: '',
        isProcessing: true,
        sessionId: 'sess_123',
        messages: [],
        status: 'Thinking...',
        error: null,
        tokenUsage: { input: 0, output: 0 },
        activeTool: 'read',
      };
      expect(state.isProcessing).toBe(true);
      expect(state.activeTool).toBe('read');
    });
  });

  describe('DisplayMessage', () => {
    it('should define user message', () => {
      const message: DisplayMessage = {
        id: 'msg_1',
        role: 'user',
        content: 'Hello',
        timestamp: new Date().toISOString(),
      };
      expect(message.role).toBe('user');
    });

    it('should define assistant message', () => {
      const message: DisplayMessage = {
        id: 'msg_2',
        role: 'assistant',
        content: 'Hi there!',
        timestamp: new Date().toISOString(),
      };
      expect(message.role).toBe('assistant');
    });

    it('should define tool message with status', () => {
      const message: DisplayMessage = {
        id: 'msg_3',
        role: 'tool',
        content: 'File read',
        timestamp: new Date().toISOString(),
        toolName: 'read',
        toolStatus: 'success',
        duration: 150,
      };
      expect(message.role).toBe('tool');
      expect(message.toolName).toBe('read');
      expect(message.toolStatus).toBe('success');
      expect(message.duration).toBe(150);
    });

    it('should define system message', () => {
      const message: DisplayMessage = {
        id: 'msg_4',
        role: 'system',
        content: 'Welcome to Tron!',
        timestamp: new Date().toISOString(),
      };
      expect(message.role).toBe('system');
    });
  });

  describe('AppAction', () => {
    it('should define SET_INPUT action', () => {
      const action: AppAction = { type: 'SET_INPUT', payload: 'test' };
      expect(action.type).toBe('SET_INPUT');
      expect(action.payload).toBe('test');
    });

    it('should define CLEAR_INPUT action', () => {
      const action: AppAction = { type: 'CLEAR_INPUT' };
      expect(action.type).toBe('CLEAR_INPUT');
    });

    it('should define SET_PROCESSING action', () => {
      const action: AppAction = { type: 'SET_PROCESSING', payload: true };
      expect(action.type).toBe('SET_PROCESSING');
      expect(action.payload).toBe(true);
    });

    it('should define ADD_MESSAGE action', () => {
      const action: AppAction = {
        type: 'ADD_MESSAGE',
        payload: {
          id: 'msg_1',
          role: 'user',
          content: 'Hello',
          timestamp: new Date().toISOString(),
        },
      };
      expect(action.type).toBe('ADD_MESSAGE');
      expect(action.payload.role).toBe('user');
    });

    it('should define UPDATE_MESSAGE action', () => {
      const action: AppAction = {
        type: 'UPDATE_MESSAGE',
        payload: {
          id: 'msg_1',
          updates: { content: 'Updated content' },
        },
      };
      expect(action.type).toBe('UPDATE_MESSAGE');
      expect(action.payload.updates.content).toBe('Updated content');
    });

    it('should define SET_STATUS action', () => {
      const action: AppAction = { type: 'SET_STATUS', payload: 'Thinking...' };
      expect(action.type).toBe('SET_STATUS');
      expect(action.payload).toBe('Thinking...');
    });

    it('should define SET_ERROR action', () => {
      const action: AppAction = { type: 'SET_ERROR', payload: 'An error occurred' };
      expect(action.type).toBe('SET_ERROR');
      expect(action.payload).toBe('An error occurred');
    });

    it('should define UPDATE_TOKEN_USAGE action', () => {
      const action: AppAction = {
        type: 'UPDATE_TOKEN_USAGE',
        payload: { input: 100, output: 50 },
      };
      expect(action.type).toBe('UPDATE_TOKEN_USAGE');
      expect(action.payload.input).toBe(100);
    });

    it('should define SET_ACTIVE_TOOL action', () => {
      const action: AppAction = { type: 'SET_ACTIVE_TOOL', payload: 'bash' };
      expect(action.type).toBe('SET_ACTIVE_TOOL');
      expect(action.payload).toBe('bash');
    });

    it('should define RESET action', () => {
      const action: AppAction = { type: 'RESET' };
      expect(action.type).toBe('RESET');
    });
  });

  describe('Component Props', () => {
    it('should define HeaderProps', () => {
      const props: HeaderProps = {
        sessionId: 'sess_123',
        workingDirectory: '/test/path',
        model: 'claude-sonnet-4-20250514',
        tokenUsage: { input: 100, output: 50 },
      };
      expect(props.model).toBe('claude-sonnet-4-20250514');
    });

    it('should define MessageListProps', () => {
      const props: MessageListProps = {
        messages: [],
        isProcessing: false,
        activeTool: null,
      };
      expect(props.isProcessing).toBe(false);
    });

    it('should define InputAreaProps', () => {
      const props: InputAreaProps = {
        value: 'test',
        onChange: () => {},
        onSubmit: () => {},
        isProcessing: false,
      };
      expect(props.value).toBe('test');
    });

    it('should define StatusBarProps', () => {
      const props: StatusBarProps = {
        status: 'Ready',
        error: null,
      };
      expect(props.status).toBe('Ready');
    });
  });
});
