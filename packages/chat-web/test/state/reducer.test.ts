/**
 * @fileoverview State Reducer Tests (TDD - Written Before Implementation)
 *
 * These tests define the expected behavior of the chat-web state reducer.
 * Following TDD, we write tests first, then implement to make them pass.
 *
 * Test coverage matches TUI's reducer pattern from packages/tui/src/app.tsx
 */
import { describe, it, expect, beforeEach } from 'vitest';
import { reducer, createInitialState } from '../../src/store/reducer.js';
import type { AppState, DisplayMessage } from '../../src/store/types.js';

// =============================================================================
// Test Helpers
// =============================================================================

function createTestMessage(overrides: Partial<DisplayMessage> = {}): DisplayMessage {
  return {
    id: `msg_${Date.now()}`,
    role: 'user',
    content: 'Test message',
    timestamp: new Date().toISOString(),
    ...overrides,
  };
}

// =============================================================================
// Initial State Tests
// =============================================================================

describe('Initial State', () => {
  it('should have correct default values', () => {
    const state = createInitialState();

    // Core state
    expect(state.isInitialized).toBe(false);
    expect(state.input).toBe('');
    expect(state.isProcessing).toBe(false);
    expect(state.sessionId).toBeNull();
    expect(state.messages).toEqual([]);
    expect(state.status).toBe('Initializing');
    expect(state.error).toBeNull();

    // Token usage
    expect(state.tokenUsage).toEqual({ input: 0, output: 0 });

    // Tool state
    expect(state.activeTool).toBeNull();
    expect(state.activeToolInput).toBeNull();

    // Streaming state
    expect(state.streamingContent).toBe('');
    expect(state.isStreaming).toBe(false);
    expect(state.thinkingText).toBe('');

    // Menu stack
    expect(state.menuStack).toEqual([]);

    // History
    expect(state.promptHistory).toEqual([]);
    expect(state.historyIndex).toBe(-1);
    expect(state.temporaryInput).toBe('');

    // Model and git
    expect(state.currentModel).toBeDefined();
    expect(state.gitBranch).toBeNull();

    // Queue
    expect(state.queuedMessages).toEqual([]);
  });

  it('should return a new object each time', () => {
    const state1 = createInitialState();
    const state2 = createInitialState();
    expect(state1).not.toBe(state2);
    expect(state1).toEqual(state2);
  });
});

// =============================================================================
// Initialization Actions
// =============================================================================

describe('Initialization Actions', () => {
  let state: AppState;

  beforeEach(() => {
    state = createInitialState();
  });

  describe('SET_INITIALIZED', () => {
    it('should set isInitialized to true', () => {
      const result = reducer(state, { type: 'SET_INITIALIZED', payload: true });
      expect(result.isInitialized).toBe(true);
    });

    it('should set isInitialized to false', () => {
      state = { ...state, isInitialized: true };
      const result = reducer(state, { type: 'SET_INITIALIZED', payload: false });
      expect(result.isInitialized).toBe(false);
    });
  });

  describe('SET_SESSION', () => {
    it('should set sessionId', () => {
      const result = reducer(state, { type: 'SET_SESSION', payload: 'sess_abc123' });
      expect(result.sessionId).toBe('sess_abc123');
    });
  });

  describe('RESET', () => {
    it('should reset to initial state but preserve sessionId and initialized', () => {
      state = {
        ...state,
        isInitialized: true,
        sessionId: 'sess_abc',
        input: 'some input',
        messages: [createTestMessage()],
        isProcessing: true,
        error: 'some error',
        streamingContent: 'streaming...',
      };

      const result = reducer(state, { type: 'RESET' });

      expect(result.isInitialized).toBe(true);
      expect(result.sessionId).toBe('sess_abc');
      expect(result.input).toBe('');
      expect(result.messages).toEqual([]);
      expect(result.isProcessing).toBe(false);
      expect(result.error).toBeNull();
      expect(result.status).toBe('Ready');
    });
  });
});

// =============================================================================
// Input Actions
// =============================================================================

describe('Input Actions', () => {
  let state: AppState;

  beforeEach(() => {
    state = createInitialState();
  });

  describe('SET_INPUT', () => {
    it('should set input value', () => {
      const result = reducer(state, { type: 'SET_INPUT', payload: 'Hello, world!' });
      expect(result.input).toBe('Hello, world!');
    });

    it('should replace existing input', () => {
      state = { ...state, input: 'old input' };
      const result = reducer(state, { type: 'SET_INPUT', payload: 'new input' });
      expect(result.input).toBe('new input');
    });
  });

  describe('CLEAR_INPUT', () => {
    it('should clear input', () => {
      state = { ...state, input: 'some input' };
      const result = reducer(state, { type: 'CLEAR_INPUT' });
      expect(result.input).toBe('');
    });
  });
});

// =============================================================================
// Processing Actions
// =============================================================================

describe('Processing Actions', () => {
  let state: AppState;

  beforeEach(() => {
    state = createInitialState();
  });

  describe('SET_PROCESSING', () => {
    it('should set isProcessing to true', () => {
      const result = reducer(state, { type: 'SET_PROCESSING', payload: true });
      expect(result.isProcessing).toBe(true);
    });

    it('should set isProcessing to false', () => {
      state = { ...state, isProcessing: true };
      const result = reducer(state, { type: 'SET_PROCESSING', payload: false });
      expect(result.isProcessing).toBe(false);
    });
  });

  describe('SET_STATUS', () => {
    it('should set status message', () => {
      const result = reducer(state, { type: 'SET_STATUS', payload: 'Thinking' });
      expect(result.status).toBe('Thinking');
    });
  });

  describe('SET_ERROR', () => {
    it('should set error message', () => {
      const result = reducer(state, { type: 'SET_ERROR', payload: 'Something went wrong' });
      expect(result.error).toBe('Something went wrong');
    });

    it('should clear error with null', () => {
      state = { ...state, error: 'previous error' };
      const result = reducer(state, { type: 'SET_ERROR', payload: null });
      expect(result.error).toBeNull();
    });
  });
});

// =============================================================================
// Message Actions
// =============================================================================

describe('Message Actions', () => {
  let state: AppState;

  beforeEach(() => {
    state = createInitialState();
  });

  describe('ADD_MESSAGE', () => {
    it('should add message to empty list', () => {
      const message = createTestMessage({ role: 'user', content: 'Hello' });
      const result = reducer(state, { type: 'ADD_MESSAGE', payload: message });

      expect(result.messages).toHaveLength(1);
      expect(result.messages[0]).toEqual(message);
    });

    it('should append message to existing list', () => {
      const msg1 = createTestMessage({ id: 'msg_1' });
      const msg2 = createTestMessage({ id: 'msg_2' });
      state = { ...state, messages: [msg1] };

      const result = reducer(state, { type: 'ADD_MESSAGE', payload: msg2 });

      expect(result.messages).toHaveLength(2);
      expect(result.messages[0]).toEqual(msg1);
      expect(result.messages[1]).toEqual(msg2);
    });
  });

  describe('UPDATE_MESSAGE', () => {
    it('should update existing message by id', () => {
      const msg = createTestMessage({ id: 'msg_1', content: 'original' });
      state = { ...state, messages: [msg] };

      const result = reducer(state, {
        type: 'UPDATE_MESSAGE',
        payload: { id: 'msg_1', updates: { content: 'updated' } },
      });

      expect(result.messages[0]?.content).toBe('updated');
      expect(result.messages[0]?.role).toBe('user'); // Unchanged
    });

    it('should not affect other messages', () => {
      const msg1 = createTestMessage({ id: 'msg_1', content: 'first' });
      const msg2 = createTestMessage({ id: 'msg_2', content: 'second' });
      state = { ...state, messages: [msg1, msg2] };

      const result = reducer(state, {
        type: 'UPDATE_MESSAGE',
        payload: { id: 'msg_1', updates: { content: 'updated first' } },
      });

      expect(result.messages[0]?.content).toBe('updated first');
      expect(result.messages[1]?.content).toBe('second');
    });

    it('should do nothing if message not found', () => {
      const msg = createTestMessage({ id: 'msg_1' });
      state = { ...state, messages: [msg] };

      const result = reducer(state, {
        type: 'UPDATE_MESSAGE',
        payload: { id: 'nonexistent', updates: { content: 'ignored' } },
      });

      expect(result.messages).toEqual(state.messages);
    });

    it('should update tool message with token usage', () => {
      const toolMsg = createTestMessage({
        id: 'msg_tool',
        role: 'tool',
        toolName: 'bash',
        toolStatus: 'success',
      });
      state = { ...state, messages: [toolMsg] };

      const result = reducer(state, {
        type: 'UPDATE_MESSAGE',
        payload: {
          id: 'msg_tool',
          updates: { tokenUsage: { inputTokens: 100, outputTokens: 50 } },
        },
      });

      expect(result.messages[0]?.tokenUsage).toEqual({ inputTokens: 100, outputTokens: 50 });
    });
  });
});

// =============================================================================
// Token Usage Actions
// =============================================================================

describe('Token Usage Actions', () => {
  let state: AppState;

  beforeEach(() => {
    state = createInitialState();
  });

  describe('SET_TOKEN_USAGE', () => {
    it('should set token usage directly', () => {
      const result = reducer(state, {
        type: 'SET_TOKEN_USAGE',
        payload: { input: 1000, output: 500 },
      });

      expect(result.tokenUsage).toEqual({ input: 1000, output: 500 });
    });

    it('should replace existing token usage', () => {
      state = { ...state, tokenUsage: { input: 100, output: 50 } };

      const result = reducer(state, {
        type: 'SET_TOKEN_USAGE',
        payload: { input: 2000, output: 1000 },
      });

      expect(result.tokenUsage).toEqual({ input: 2000, output: 1000 });
    });
  });
});

// =============================================================================
// Tool Actions
// =============================================================================

describe('Tool Actions', () => {
  let state: AppState;

  beforeEach(() => {
    state = createInitialState();
  });

  describe('SET_ACTIVE_TOOL', () => {
    it('should set active tool name', () => {
      const result = reducer(state, { type: 'SET_ACTIVE_TOOL', payload: 'bash' });
      expect(result.activeTool).toBe('bash');
    });

    it('should clear active tool with null', () => {
      state = { ...state, activeTool: 'bash' };
      const result = reducer(state, { type: 'SET_ACTIVE_TOOL', payload: null });
      expect(result.activeTool).toBeNull();
    });
  });

  describe('SET_ACTIVE_TOOL_INPUT', () => {
    it('should set active tool input', () => {
      const result = reducer(state, {
        type: 'SET_ACTIVE_TOOL_INPUT',
        payload: 'ls -la',
      });
      expect(result.activeToolInput).toBe('ls -la');
    });

    it('should clear active tool input with null', () => {
      state = { ...state, activeToolInput: 'ls -la' };
      const result = reducer(state, { type: 'SET_ACTIVE_TOOL_INPUT', payload: null });
      expect(result.activeToolInput).toBeNull();
    });
  });
});

// =============================================================================
// Streaming Actions
// =============================================================================

describe('Streaming Actions', () => {
  let state: AppState;

  beforeEach(() => {
    state = createInitialState();
  });

  describe('APPEND_STREAMING_CONTENT', () => {
    it('should append to empty streaming content', () => {
      const result = reducer(state, {
        type: 'APPEND_STREAMING_CONTENT',
        payload: 'Hello',
      });
      expect(result.streamingContent).toBe('Hello');
    });

    it('should append to existing streaming content', () => {
      state = { ...state, streamingContent: 'Hello, ' };
      const result = reducer(state, {
        type: 'APPEND_STREAMING_CONTENT',
        payload: 'world!',
      });
      expect(result.streamingContent).toBe('Hello, world!');
    });
  });

  describe('SET_STREAMING', () => {
    it('should set isStreaming to true', () => {
      const result = reducer(state, { type: 'SET_STREAMING', payload: true });
      expect(result.isStreaming).toBe(true);
    });

    it('should set isStreaming to false', () => {
      state = { ...state, isStreaming: true };
      const result = reducer(state, { type: 'SET_STREAMING', payload: false });
      expect(result.isStreaming).toBe(false);
    });
  });

  describe('CLEAR_STREAMING', () => {
    it('should clear all streaming state', () => {
      state = {
        ...state,
        streamingContent: 'some content',
        isStreaming: true,
        thinkingText: 'thinking...',
      };

      const result = reducer(state, { type: 'CLEAR_STREAMING' });

      expect(result.streamingContent).toBe('');
      expect(result.isStreaming).toBe(false);
      expect(result.thinkingText).toBe('');
    });
  });
});

// =============================================================================
// Thinking Actions
// =============================================================================

describe('Thinking Actions', () => {
  let state: AppState;

  beforeEach(() => {
    state = createInitialState();
  });

  describe('SET_THINKING_TEXT', () => {
    it('should set thinking text', () => {
      const result = reducer(state, {
        type: 'SET_THINKING_TEXT',
        payload: 'Analyzing the problem...',
      });
      expect(result.thinkingText).toBe('Analyzing the problem...');
    });

    it('should replace existing thinking text', () => {
      state = { ...state, thinkingText: 'old thinking' };
      const result = reducer(state, {
        type: 'SET_THINKING_TEXT',
        payload: 'new thinking',
      });
      expect(result.thinkingText).toBe('new thinking');
    });
  });

  describe('APPEND_THINKING_TEXT', () => {
    it('should append to empty thinking text', () => {
      const result = reducer(state, {
        type: 'APPEND_THINKING_TEXT',
        payload: 'First thought',
      });
      expect(result.thinkingText).toBe('First thought');
    });

    it('should append to existing thinking text', () => {
      state = { ...state, thinkingText: 'First, ' };
      const result = reducer(state, {
        type: 'APPEND_THINKING_TEXT',
        payload: 'then this',
      });
      expect(result.thinkingText).toBe('First, then this');
    });
  });
});

// =============================================================================
// Menu Stack Actions
// =============================================================================

describe('Menu Stack Actions', () => {
  let state: AppState;

  beforeEach(() => {
    state = createInitialState();
  });

  describe('PUSH_MENU', () => {
    it('should push menu onto empty stack', () => {
      const result = reducer(state, {
        type: 'PUSH_MENU',
        payload: { id: 'slash-menu' },
      });

      expect(result.menuStack).toHaveLength(1);
      expect(result.menuStack[0]?.id).toBe('slash-menu');
      expect(result.menuStack[0]?.index).toBe(0); // Default
    });

    it('should push menu with custom index', () => {
      const result = reducer(state, {
        type: 'PUSH_MENU',
        payload: { id: 'model-switcher', index: 5 },
      });

      expect(result.menuStack[0]?.index).toBe(5);
    });

    it('should save input when saveInput is true', () => {
      state = { ...state, input: '/mod' };
      const result = reducer(state, {
        type: 'PUSH_MENU',
        payload: { id: 'model-switcher', saveInput: true },
      });

      expect(result.menuStack[0]?.savedInput).toBe('/mod');
    });

    it('should not save input when saveInput is false', () => {
      state = { ...state, input: '/mod' };
      const result = reducer(state, {
        type: 'PUSH_MENU',
        payload: { id: 'model-switcher', saveInput: false },
      });

      expect(result.menuStack[0]?.savedInput).toBeUndefined();
    });

    it('should push submenu onto existing stack', () => {
      state = {
        ...state,
        menuStack: [{ id: 'slash-menu', index: 0 }],
      };

      const result = reducer(state, {
        type: 'PUSH_MENU',
        payload: { id: 'model-switcher', saveInput: true },
      });

      expect(result.menuStack).toHaveLength(2);
      expect(result.menuStack[0]?.id).toBe('slash-menu');
      expect(result.menuStack[1]?.id).toBe('model-switcher');
    });

    it('should not push duplicate menu at top of stack', () => {
      state = {
        ...state,
        menuStack: [{ id: 'slash-menu', index: 0 }],
      };

      const result = reducer(state, {
        type: 'PUSH_MENU',
        payload: { id: 'slash-menu' },
      });

      expect(result.menuStack).toHaveLength(1);
      expect(result).toBe(state); // Same reference
    });
  });

  describe('POP_MENU', () => {
    it('should pop menu from stack', () => {
      state = {
        ...state,
        menuStack: [
          { id: 'slash-menu', index: 0 },
          { id: 'model-switcher', index: 3 },
        ],
      };

      const result = reducer(state, { type: 'POP_MENU' });

      expect(result.menuStack).toHaveLength(1);
      expect(result.menuStack[0]?.id).toBe('slash-menu');
    });

    it('should restore input from popped menu with savedInput', () => {
      state = {
        ...state,
        input: 'current',
        menuStack: [
          { id: 'slash-menu', index: 0, savedInput: '/mod' },
        ],
      };

      const result = reducer(state, { type: 'POP_MENU' });

      // After popping, new top's savedInput should be restored
      // If stack is empty, input stays as is
      expect(result.menuStack).toHaveLength(0);
    });

    it('should do nothing on empty stack', () => {
      const result = reducer(state, { type: 'POP_MENU' });
      expect(result).toBe(state);
    });
  });

  describe('SET_MENU_INDEX', () => {
    it('should update index of top menu', () => {
      state = {
        ...state,
        menuStack: [{ id: 'slash-menu', index: 0 }],
      };

      const result = reducer(state, { type: 'SET_MENU_INDEX', payload: 5 });

      expect(result.menuStack[0]?.index).toBe(5);
    });

    it('should do nothing on empty stack', () => {
      const result = reducer(state, { type: 'SET_MENU_INDEX', payload: 5 });
      expect(result).toBe(state);
    });
  });

  describe('CLOSE_ALL_MENUS', () => {
    it('should clear menu stack and input', () => {
      state = {
        ...state,
        input: '/model',
        menuStack: [
          { id: 'slash-menu', index: 0 },
          { id: 'model-switcher', index: 3 },
        ],
      };

      const result = reducer(state, { type: 'CLOSE_ALL_MENUS' });

      expect(result.menuStack).toEqual([]);
      expect(result.input).toBe('');
    });
  });
});

// =============================================================================
// History Actions
// =============================================================================

describe('History Actions', () => {
  let state: AppState;

  beforeEach(() => {
    state = createInitialState();
  });

  describe('ADD_TO_HISTORY', () => {
    it('should add prompt to empty history', () => {
      const result = reducer(state, {
        type: 'ADD_TO_HISTORY',
        payload: 'first prompt',
      });

      expect(result.promptHistory).toEqual(['first prompt']);
      expect(result.historyIndex).toBe(-1);
      expect(result.temporaryInput).toBe('');
    });

    it('should append to existing history', () => {
      state = { ...state, promptHistory: ['first'] };
      const result = reducer(state, {
        type: 'ADD_TO_HISTORY',
        payload: 'second',
      });

      expect(result.promptHistory).toEqual(['first', 'second']);
    });

    it('should not add consecutive duplicates', () => {
      state = { ...state, promptHistory: ['same prompt'] };
      const result = reducer(state, {
        type: 'ADD_TO_HISTORY',
        payload: 'same prompt',
      });

      expect(result.promptHistory).toEqual(['same prompt']);
    });

    it('should trim input before adding', () => {
      const result = reducer(state, {
        type: 'ADD_TO_HISTORY',
        payload: '  trimmed  ',
      });

      expect(result.promptHistory).toEqual(['trimmed']);
    });

    it('should not add empty or whitespace-only input', () => {
      let result = reducer(state, { type: 'ADD_TO_HISTORY', payload: '' });
      expect(result.promptHistory).toEqual([]);

      result = reducer(state, { type: 'ADD_TO_HISTORY', payload: '   ' });
      expect(result.promptHistory).toEqual([]);
    });

    it('should enforce max history limit', () => {
      // Fill with 100 items
      state = {
        ...state,
        promptHistory: Array.from({ length: 100 }, (_, i) => `prompt_${i}`),
      };

      const result = reducer(state, {
        type: 'ADD_TO_HISTORY',
        payload: 'new prompt',
      });

      expect(result.promptHistory).toHaveLength(100);
      expect(result.promptHistory[99]).toBe('new prompt');
      expect(result.promptHistory[0]).toBe('prompt_1'); // First removed
    });
  });

  describe('HISTORY_UP', () => {
    it('should navigate to most recent entry', () => {
      state = {
        ...state,
        promptHistory: ['first', 'second', 'third'],
        historyIndex: -1,
        input: 'current',
      };

      const result = reducer(state, { type: 'HISTORY_UP' });

      expect(result.historyIndex).toBe(2);
      expect(result.input).toBe('third');
    });

    it('should navigate to older entries', () => {
      state = {
        ...state,
        promptHistory: ['first', 'second', 'third'],
        historyIndex: 2,
        input: 'third',
      };

      const result = reducer(state, { type: 'HISTORY_UP' });

      expect(result.historyIndex).toBe(1);
      expect(result.input).toBe('second');
    });

    it('should stay at beginning of history', () => {
      state = {
        ...state,
        promptHistory: ['first', 'second'],
        historyIndex: 0,
        input: 'first',
      };

      const result = reducer(state, { type: 'HISTORY_UP' });

      expect(result.historyIndex).toBe(0);
      expect(result.input).toBe('first');
      expect(result).toBe(state); // No change
    });

    it('should do nothing with empty history', () => {
      const result = reducer(state, { type: 'HISTORY_UP' });
      expect(result).toBe(state);
    });
  });

  describe('HISTORY_DOWN', () => {
    it('should navigate to newer entries', () => {
      state = {
        ...state,
        promptHistory: ['first', 'second', 'third'],
        historyIndex: 1,
        input: 'second',
      };

      const result = reducer(state, { type: 'HISTORY_DOWN' });

      expect(result.historyIndex).toBe(2);
      expect(result.input).toBe('third');
    });

    it('should restore temporary input when past end', () => {
      state = {
        ...state,
        promptHistory: ['first', 'second'],
        historyIndex: 1,
        input: 'second',
        temporaryInput: 'my draft',
      };

      const result = reducer(state, { type: 'HISTORY_DOWN' });

      expect(result.historyIndex).toBe(-1);
      expect(result.input).toBe('my draft');
    });

    it('should do nothing when not navigating', () => {
      state = {
        ...state,
        promptHistory: ['first'],
        historyIndex: -1,
      };

      const result = reducer(state, { type: 'HISTORY_DOWN' });
      expect(result).toBe(state);
    });

    it('should do nothing with empty history', () => {
      const result = reducer(state, { type: 'HISTORY_DOWN' });
      expect(result).toBe(state);
    });
  });

  describe('SET_TEMPORARY_INPUT', () => {
    it('should set temporary input', () => {
      const result = reducer(state, {
        type: 'SET_TEMPORARY_INPUT',
        payload: 'my draft',
      });
      expect(result.temporaryInput).toBe('my draft');
    });
  });

  describe('RESET_HISTORY_NAVIGATION', () => {
    it('should reset history index to -1', () => {
      state = { ...state, historyIndex: 5 };
      const result = reducer(state, { type: 'RESET_HISTORY_NAVIGATION' });
      expect(result.historyIndex).toBe(-1);
    });
  });
});

// =============================================================================
// Model Actions
// =============================================================================

describe('Model Actions', () => {
  let state: AppState;

  beforeEach(() => {
    state = createInitialState();
  });

  describe('SET_CURRENT_MODEL', () => {
    it('should set current model', () => {
      const result = reducer(state, {
        type: 'SET_CURRENT_MODEL',
        payload: 'claude-opus-4-20250514',
      });
      expect(result.currentModel).toBe('claude-opus-4-20250514');
    });
  });

  describe('SET_GIT_BRANCH', () => {
    it('should set git branch', () => {
      const result = reducer(state, {
        type: 'SET_GIT_BRANCH',
        payload: 'main',
      });
      expect(result.gitBranch).toBe('main');
    });

    it('should clear git branch with null', () => {
      state = { ...state, gitBranch: 'feature-branch' };
      const result = reducer(state, {
        type: 'SET_GIT_BRANCH',
        payload: null,
      });
      expect(result.gitBranch).toBeNull();
    });
  });
});

// =============================================================================
// Queue Actions
// =============================================================================

describe('Queue Actions', () => {
  let state: AppState;

  beforeEach(() => {
    state = createInitialState();
  });

  describe('QUEUE_MESSAGE', () => {
    it('should add message to empty queue', () => {
      const result = reducer(state, {
        type: 'QUEUE_MESSAGE',
        payload: 'queued prompt',
      });
      expect(result.queuedMessages).toEqual(['queued prompt']);
    });

    it('should append to existing queue', () => {
      state = { ...state, queuedMessages: ['first'] };
      const result = reducer(state, {
        type: 'QUEUE_MESSAGE',
        payload: 'second',
      });
      expect(result.queuedMessages).toEqual(['first', 'second']);
    });
  });

  describe('CLEAR_QUEUE', () => {
    it('should clear queued messages', () => {
      state = { ...state, queuedMessages: ['first', 'second'] };
      const result = reducer(state, { type: 'CLEAR_QUEUE' });
      expect(result.queuedMessages).toEqual([]);
    });
  });
});

// =============================================================================
// Web-Specific: Connection Actions
// =============================================================================

describe('Connection Actions', () => {
  let state: AppState;

  beforeEach(() => {
    state = createInitialState();
  });

  describe('SET_CONNECTION_STATUS', () => {
    it('should set connection status to connecting', () => {
      const result = reducer(state, {
        type: 'SET_CONNECTION_STATUS',
        payload: 'connecting',
      });
      expect(result.connection.status).toBe('connecting');
    });

    it('should set connection status to connected', () => {
      const result = reducer(state, {
        type: 'SET_CONNECTION_STATUS',
        payload: 'connected',
      });
      expect(result.connection.status).toBe('connected');
    });

    it('should set connection status to disconnected', () => {
      const result = reducer(state, {
        type: 'SET_CONNECTION_STATUS',
        payload: 'disconnected',
      });
      expect(result.connection.status).toBe('disconnected');
    });

    it('should set connection status to error', () => {
      const result = reducer(state, {
        type: 'SET_CONNECTION_STATUS',
        payload: 'error',
      });
      expect(result.connection.status).toBe('error');
    });
  });

  describe('SET_CONNECTION_ERROR', () => {
    it('should set connection error', () => {
      const result = reducer(state, {
        type: 'SET_CONNECTION_ERROR',
        payload: 'Connection refused',
      });
      expect(result.connection.error).toBe('Connection refused');
    });

    it('should clear connection error with null', () => {
      state = {
        ...state,
        connection: { ...state.connection, error: 'old error' },
      };
      const result = reducer(state, {
        type: 'SET_CONNECTION_ERROR',
        payload: null,
      });
      expect(result.connection.error).toBeNull();
    });
  });

  describe('INCREMENT_RECONNECT_ATTEMPT', () => {
    it('should increment reconnect attempt counter', () => {
      expect(state.connection.reconnectAttempt).toBe(0);

      let result = reducer(state, { type: 'INCREMENT_RECONNECT_ATTEMPT' });
      expect(result.connection.reconnectAttempt).toBe(1);

      result = reducer(result, { type: 'INCREMENT_RECONNECT_ATTEMPT' });
      expect(result.connection.reconnectAttempt).toBe(2);
    });
  });

  describe('RESET_RECONNECT_ATTEMPT', () => {
    it('should reset reconnect attempt counter to 0', () => {
      state = {
        ...state,
        connection: { ...state.connection, reconnectAttempt: 5 },
      };
      const result = reducer(state, { type: 'RESET_RECONNECT_ATTEMPT' });
      expect(result.connection.reconnectAttempt).toBe(0);
    });
  });
});

// =============================================================================
// Web-Specific: Session List Actions
// =============================================================================

describe('Session List Actions', () => {
  let state: AppState;

  beforeEach(() => {
    state = createInitialState();
  });

  describe('SET_SESSIONS', () => {
    it('should set sessions list', () => {
      const sessions = [
        { id: 'sess_1', title: 'Session 1', lastActivity: new Date().toISOString() },
        { id: 'sess_2', title: 'Session 2', lastActivity: new Date().toISOString() },
      ];

      const result = reducer(state, {
        type: 'SET_SESSIONS',
        payload: sessions,
      });

      expect(result.sessions).toHaveLength(2);
      expect(result.sessions[0]?.id).toBe('sess_1');
    });
  });

  describe('ADD_SESSION', () => {
    it('should add session to list', () => {
      const session = { id: 'sess_new', title: 'New Session', lastActivity: new Date().toISOString() };

      const result = reducer(state, {
        type: 'ADD_SESSION',
        payload: session,
      });

      expect(result.sessions).toHaveLength(1);
      expect(result.sessions[0]?.id).toBe('sess_new');
    });
  });

  describe('REMOVE_SESSION', () => {
    it('should remove session from list', () => {
      state = {
        ...state,
        sessions: [
          { id: 'sess_1', title: 'Session 1', lastActivity: new Date().toISOString() },
          { id: 'sess_2', title: 'Session 2', lastActivity: new Date().toISOString() },
        ],
      };

      const result = reducer(state, {
        type: 'REMOVE_SESSION',
        payload: 'sess_1',
      });

      expect(result.sessions).toHaveLength(1);
      expect(result.sessions[0]?.id).toBe('sess_2');
    });
  });
});

// =============================================================================
// Web-Specific: UI Actions
// =============================================================================

describe('UI Actions', () => {
  let state: AppState;

  beforeEach(() => {
    state = createInitialState();
  });

  describe('SET_SIDEBAR_OPEN', () => {
    it('should set sidebar open state', () => {
      const result = reducer(state, {
        type: 'SET_SIDEBAR_OPEN',
        payload: true,
      });
      expect(result.ui.sidebarOpen).toBe(true);
    });

    it('should close sidebar', () => {
      state = { ...state, ui: { ...state.ui, sidebarOpen: true } };
      const result = reducer(state, {
        type: 'SET_SIDEBAR_OPEN',
        payload: false,
      });
      expect(result.ui.sidebarOpen).toBe(false);
    });
  });

  describe('SET_IS_MOBILE', () => {
    it('should set mobile state', () => {
      const result = reducer(state, {
        type: 'SET_IS_MOBILE',
        payload: true,
      });
      expect(result.ui.isMobile).toBe(true);
    });
  });
});

// =============================================================================
// Unknown Action
// =============================================================================

describe('Unknown Action', () => {
  it('should return unchanged state for unknown action', () => {
    const state = createInitialState();
    // @ts-expect-error - Testing unknown action
    const result = reducer(state, { type: 'UNKNOWN_ACTION' });
    expect(result).toBe(state);
  });
});
