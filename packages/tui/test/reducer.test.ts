/**
 * @fileoverview App Reducer Tests
 *
 * Tests for the TUI state reducer logic.
 */
import { describe, it, expect } from 'vitest';
import type { AppState, AppAction, DisplayMessage, MenuStackEntry } from '../src/types.js';

// Helper function to get current menu from stack
function getCurrentMenu(stack: MenuStackEntry[]): MenuStackEntry | null {
  return stack.length > 0 ? stack[stack.length - 1]! : null;
}

// Re-implement reducer for testing (mirrors app.tsx implementation)
const initialState: AppState = {
  isInitialized: false,
  input: '',
  isProcessing: false,
  sessionId: null,
  messages: [],
  status: 'Initializing',
  error: null,
  tokenUsage: { input: 0, output: 0 },
  activeTool: null,
  activeToolInput: null,
  streamingContent: '',
  isStreaming: false,
  thinkingText: '',
  menuStack: [],
  promptHistory: [],
  historyIndex: -1,
  temporaryInput: '',
  currentModel: 'claude-sonnet-4-20250514',
};

function reducer(state: AppState, action: AppAction): AppState {
  switch (action.type) {
    case 'SET_INITIALIZED':
      return { ...state, isInitialized: action.payload };
    case 'SET_INPUT':
      return { ...state, input: action.payload };
    case 'CLEAR_INPUT':
      return { ...state, input: '' };
    case 'SET_PROCESSING':
      return { ...state, isProcessing: action.payload };
    case 'SET_SESSION':
      return { ...state, sessionId: action.payload };
    case 'ADD_MESSAGE':
      return { ...state, messages: [...state.messages, action.payload] };
    case 'UPDATE_MESSAGE':
      return {
        ...state,
        messages: state.messages.map((m) =>
          m.id === action.payload.id ? { ...m, ...action.payload.updates } : m
        ),
      };
    case 'SET_STATUS':
      return { ...state, status: action.payload };
    case 'SET_ERROR':
      return { ...state, error: action.payload };
    case 'SET_TOKEN_USAGE':
      return {
        ...state,
        tokenUsage: {
          input: action.payload.input,
          output: action.payload.output,
        },
      };
    case 'SET_ACTIVE_TOOL':
      return { ...state, activeTool: action.payload };
    case 'SET_ACTIVE_TOOL_INPUT':
      return { ...state, activeToolInput: action.payload };
    case 'APPEND_STREAMING_CONTENT':
      return { ...state, streamingContent: state.streamingContent + action.payload };
    case 'SET_STREAMING':
      return { ...state, isStreaming: action.payload };
    case 'CLEAR_STREAMING':
      return { ...state, streamingContent: '', isStreaming: false, thinkingText: '' };
    case 'SET_THINKING_TEXT':
      return { ...state, thinkingText: action.payload };
    case 'APPEND_THINKING_TEXT':
      return { ...state, thinkingText: state.thinkingText + action.payload };
    case 'RESET':
      return {
        ...initialState,
        isInitialized: true,
        sessionId: state.sessionId,
        status: 'Ready',
        activeToolInput: null,
      };
    // Menu stack actions
    case 'PUSH_MENU': {
      const { id, index = 0, saveInput = false } = action.payload;
      const currentMenu = getCurrentMenu(state.menuStack);
      if (currentMenu?.id === id) return state;
      const newEntry: MenuStackEntry = {
        id,
        index,
        savedInput: saveInput ? state.input : undefined,
      };
      return { ...state, menuStack: [...state.menuStack, newEntry] };
    }
    case 'POP_MENU': {
      if (state.menuStack.length === 0) return state;
      const newStack = state.menuStack.slice(0, -1);
      const newTop = getCurrentMenu(newStack);
      const restoredInput = newTop?.savedInput;
      return {
        ...state,
        menuStack: newStack,
        input: restoredInput !== undefined ? restoredInput : state.input,
      };
    }
    case 'SET_MENU_INDEX': {
      if (state.menuStack.length === 0) return state;
      const updatedStack = [...state.menuStack];
      const topIndex = updatedStack.length - 1;
      updatedStack[topIndex] = { ...updatedStack[topIndex]!, index: action.payload };
      return { ...state, menuStack: updatedStack };
    }
    case 'CLOSE_ALL_MENUS':
      return { ...state, menuStack: [], input: '' };
    case 'ADD_TO_HISTORY': {
      const trimmed = action.payload.trim();
      if (!trimmed) return state;
      if (state.promptHistory.length > 0 &&
          state.promptHistory[state.promptHistory.length - 1] === trimmed) {
        return { ...state, historyIndex: -1, temporaryInput: '' };
      }
      return {
        ...state,
        promptHistory: [...state.promptHistory, trimmed],
        historyIndex: -1,
        temporaryInput: '',
      };
    }
    case 'HISTORY_UP': {
      if (state.promptHistory.length === 0) return state;
      if (state.historyIndex === -1) {
        const newIndex = state.promptHistory.length - 1;
        return {
          ...state,
          historyIndex: newIndex,
          input: state.promptHistory[newIndex] ?? '',
        };
      } else if (state.historyIndex > 0) {
        const newIndex = state.historyIndex - 1;
        return {
          ...state,
          historyIndex: newIndex,
          input: state.promptHistory[newIndex] ?? '',
        };
      }
      return state;
    }
    case 'HISTORY_DOWN': {
      if (state.promptHistory.length === 0 || state.historyIndex === -1) {
        return state;
      }
      if (state.historyIndex < state.promptHistory.length - 1) {
        const newIndex = state.historyIndex + 1;
        return {
          ...state,
          historyIndex: newIndex,
          input: state.promptHistory[newIndex] ?? '',
        };
      } else {
        return {
          ...state,
          historyIndex: -1,
          input: state.temporaryInput,
        };
      }
    }
    case 'SET_TEMPORARY_INPUT':
      return { ...state, temporaryInput: action.payload };
    case 'RESET_HISTORY_NAVIGATION':
      return { ...state, historyIndex: -1 };
    case 'SET_CURRENT_MODEL':
      return { ...state, currentModel: action.payload };
    default:
      return state;
  }
}

describe('App Reducer', () => {
  describe('SET_INPUT', () => {
    it('should update input value', () => {
      const state = reducer(initialState, { type: 'SET_INPUT', payload: 'hello' });
      expect(state.input).toBe('hello');
    });

    it('should not affect other state', () => {
      const state = reducer(initialState, { type: 'SET_INPUT', payload: 'hello' });
      expect(state.status).toBe('Initializing'); // Default is Initializing until Ready
      expect(state.isProcessing).toBe(false);
    });
  });

  describe('CLEAR_INPUT', () => {
    it('should clear input value', () => {
      const startState = { ...initialState, input: 'some text' };
      const state = reducer(startState, { type: 'CLEAR_INPUT' });
      expect(state.input).toBe('');
    });
  });

  describe('SET_PROCESSING', () => {
    it('should set processing to true', () => {
      const state = reducer(initialState, { type: 'SET_PROCESSING', payload: true });
      expect(state.isProcessing).toBe(true);
    });

    it('should set processing to false', () => {
      const startState = { ...initialState, isProcessing: true };
      const state = reducer(startState, { type: 'SET_PROCESSING', payload: false });
      expect(state.isProcessing).toBe(false);
    });
  });

  describe('SET_SESSION', () => {
    it('should set session ID', () => {
      const state = reducer(initialState, { type: 'SET_SESSION', payload: 'sess_123' });
      expect(state.sessionId).toBe('sess_123');
    });
  });

  describe('ADD_MESSAGE', () => {
    it('should add message to empty list', () => {
      const message: DisplayMessage = {
        id: 'msg_1',
        role: 'user',
        content: 'Hello',
        timestamp: '2025-01-01T00:00:00Z',
      };
      const state = reducer(initialState, { type: 'ADD_MESSAGE', payload: message });
      expect(state.messages).toHaveLength(1);
      expect(state.messages[0]!).toEqual(message);
    });

    it('should append message to existing list', () => {
      const existingMessage: DisplayMessage = {
        id: 'msg_1',
        role: 'user',
        content: 'First',
        timestamp: '2025-01-01T00:00:00Z',
      };
      const newMessage: DisplayMessage = {
        id: 'msg_2',
        role: 'assistant',
        content: 'Second',
        timestamp: '2025-01-01T00:00:01Z',
      };
      const startState = { ...initialState, messages: [existingMessage] };
      const state = reducer(startState, { type: 'ADD_MESSAGE', payload: newMessage });
      expect(state.messages).toHaveLength(2);
      expect(state.messages[1]!).toEqual(newMessage);
    });
  });

  describe('UPDATE_MESSAGE', () => {
    it('should update existing message', () => {
      const message: DisplayMessage = {
        id: 'msg_1',
        role: 'assistant',
        content: 'Initial',
        timestamp: '2025-01-01T00:00:00Z',
      };
      const startState = { ...initialState, messages: [message] };
      const state = reducer(startState, {
        type: 'UPDATE_MESSAGE',
        payload: { id: 'msg_1', updates: { content: 'Updated' } },
      });
      expect(state.messages[0]!.content).toBe('Updated');
    });

    it('should not update non-existent message', () => {
      const message: DisplayMessage = {
        id: 'msg_1',
        role: 'assistant',
        content: 'Original',
        timestamp: '2025-01-01T00:00:00Z',
      };
      const startState = { ...initialState, messages: [message] };
      const state = reducer(startState, {
        type: 'UPDATE_MESSAGE',
        payload: { id: 'msg_999', updates: { content: 'Updated' } },
      });
      expect(state.messages[0]!.content).toBe('Original');
    });

    it('should preserve other message properties', () => {
      const message: DisplayMessage = {
        id: 'msg_1',
        role: 'assistant',
        content: 'Initial',
        timestamp: '2025-01-01T00:00:00Z',
      };
      const startState = { ...initialState, messages: [message] };
      const state = reducer(startState, {
        type: 'UPDATE_MESSAGE',
        payload: { id: 'msg_1', updates: { content: 'Updated' } },
      });
      expect(state.messages[0]!.role).toBe('assistant');
      expect(state.messages[0]!.timestamp).toBe('2025-01-01T00:00:00Z');
    });
  });

  describe('SET_STATUS', () => {
    it('should update status', () => {
      const state = reducer(initialState, { type: 'SET_STATUS', payload: 'Thinking...' });
      expect(state.status).toBe('Thinking...');
    });
  });

  describe('SET_ERROR', () => {
    it('should set error message', () => {
      const state = reducer(initialState, { type: 'SET_ERROR', payload: 'Something went wrong' });
      expect(state.error).toBe('Something went wrong');
    });

    it('should clear error', () => {
      const startState = { ...initialState, error: 'Previous error' };
      const state = reducer(startState, { type: 'SET_ERROR', payload: null });
      expect(state.error).toBeNull();
    });
  });

  describe('SET_TOKEN_USAGE', () => {
    it('should set token usage', () => {
      const state = reducer(initialState, {
        type: 'SET_TOKEN_USAGE',
        payload: { input: 100, output: 50 },
      });
      expect(state.tokenUsage.input).toBe(100);
      expect(state.tokenUsage.output).toBe(50);
    });

    it('should replace token usage (cumulative from agent)', () => {
      const startState = { ...initialState, tokenUsage: { input: 100, output: 50 } };
      const state = reducer(startState, {
        type: 'SET_TOKEN_USAGE',
        payload: { input: 300, output: 150 },
      });
      expect(state.tokenUsage.input).toBe(300);
      expect(state.tokenUsage.output).toBe(150);
    });
  });

  describe('SET_ACTIVE_TOOL', () => {
    it('should set active tool', () => {
      const state = reducer(initialState, { type: 'SET_ACTIVE_TOOL', payload: 'read' });
      expect(state.activeTool).toBe('read');
    });

    it('should clear active tool', () => {
      const startState = { ...initialState, activeTool: 'bash' };
      const state = reducer(startState, { type: 'SET_ACTIVE_TOOL', payload: null });
      expect(state.activeTool).toBeNull();
    });
  });

  describe('SET_ACTIVE_TOOL_INPUT', () => {
    it('should set active tool input', () => {
      const state = reducer(initialState, { type: 'SET_ACTIVE_TOOL_INPUT', payload: 'ls -la' });
      expect(state.activeToolInput).toBe('ls -la');
    });

    it('should clear active tool input', () => {
      const startState = { ...initialState, activeToolInput: 'ls -la' };
      const state = reducer(startState, { type: 'SET_ACTIVE_TOOL_INPUT', payload: null });
      expect(state.activeToolInput).toBeNull();
    });
  });

  describe('RESET', () => {
    it('should reset to initial state but keep session ID', () => {
      const startState: AppState = {
        isInitialized: true,
        input: 'some input',
        isProcessing: true,
        sessionId: 'sess_123',
        messages: [{ id: 'msg_1', role: 'user', content: 'Hi', timestamp: '' }],
        status: 'Thinking...',
        error: 'An error',
        tokenUsage: { input: 100, output: 50 },
        activeTool: 'bash',
        activeToolInput: 'ls -la',
        streamingContent: 'some content',
        isStreaming: true,
        thinkingText: 'thinking...',
        menuStack: [{ id: 'slash-menu', index: 2 }],
        promptHistory: ['prev1', 'prev2'],
        historyIndex: 1,
        temporaryInput: 'temp',
        currentModel: 'claude-sonnet-4-20250514',
      };
      const state = reducer(startState, { type: 'RESET' });
      expect(state.input).toBe('');
      expect(state.isProcessing).toBe(false);
      expect(state.messages).toHaveLength(0);
      expect(state.status).toBe('Ready');
      expect(state.error).toBeNull();
      expect(state.tokenUsage.input).toBe(0);
      expect(state.activeTool).toBeNull();
      expect(state.activeToolInput).toBeNull();
      expect(state.streamingContent).toBe('');
      expect(state.isStreaming).toBe(false);
      expect(state.thinkingText).toBe('');
      expect(state.menuStack).toHaveLength(0);
      // Session ID should be preserved
      expect(state.sessionId).toBe('sess_123');
      // isInitialized should stay true
      expect(state.isInitialized).toBe(true);
    });
  });

  describe('SET_INITIALIZED', () => {
    it('should set initialized to true', () => {
      const state = reducer(initialState, { type: 'SET_INITIALIZED', payload: true });
      expect(state.isInitialized).toBe(true);
    });

    it('should set initialized to false', () => {
      const startState = { ...initialState, isInitialized: true };
      const state = reducer(startState, { type: 'SET_INITIALIZED', payload: false });
      expect(state.isInitialized).toBe(false);
    });
  });

  describe('APPEND_STREAMING_CONTENT', () => {
    it('should append content to empty string', () => {
      const state = reducer(initialState, { type: 'APPEND_STREAMING_CONTENT', payload: 'Hello' });
      expect(state.streamingContent).toBe('Hello');
    });

    it('should append content to existing content', () => {
      const startState = { ...initialState, streamingContent: 'Hello ' };
      const state = reducer(startState, { type: 'APPEND_STREAMING_CONTENT', payload: 'World' });
      expect(state.streamingContent).toBe('Hello World');
    });
  });

  describe('SET_STREAMING', () => {
    it('should set streaming to true', () => {
      const state = reducer(initialState, { type: 'SET_STREAMING', payload: true });
      expect(state.isStreaming).toBe(true);
    });

    it('should set streaming to false', () => {
      const startState = { ...initialState, isStreaming: true };
      const state = reducer(startState, { type: 'SET_STREAMING', payload: false });
      expect(state.isStreaming).toBe(false);
    });
  });

  describe('CLEAR_STREAMING', () => {
    it('should clear all streaming state', () => {
      const startState = {
        ...initialState,
        streamingContent: 'some content',
        isStreaming: true,
        thinkingText: 'thinking...',
      };
      const state = reducer(startState, { type: 'CLEAR_STREAMING' });
      expect(state.streamingContent).toBe('');
      expect(state.isStreaming).toBe(false);
      expect(state.thinkingText).toBe('');
    });
  });

  describe('SET_THINKING_TEXT', () => {
    it('should set thinking text', () => {
      const state = reducer(initialState, { type: 'SET_THINKING_TEXT', payload: 'Analyzing...' });
      expect(state.thinkingText).toBe('Analyzing...');
    });

    it('should replace thinking text', () => {
      const startState = { ...initialState, thinkingText: 'Old thinking' };
      const state = reducer(startState, { type: 'SET_THINKING_TEXT', payload: 'New thinking' });
      expect(state.thinkingText).toBe('New thinking');
    });
  });

  describe('APPEND_THINKING_TEXT', () => {
    it('should append to empty thinking text', () => {
      const state = reducer(initialState, { type: 'APPEND_THINKING_TEXT', payload: 'First ' });
      expect(state.thinkingText).toBe('First ');
    });

    it('should append to existing thinking text', () => {
      const startState = { ...initialState, thinkingText: 'First ' };
      const state = reducer(startState, { type: 'APPEND_THINKING_TEXT', payload: 'Second' });
      expect(state.thinkingText).toBe('First Second');
    });
  });
});

describe('Menu Stack', () => {
  describe('PUSH_MENU', () => {
    it('should push a menu onto empty stack', () => {
      const state = reducer(initialState, {
        type: 'PUSH_MENU',
        payload: { id: 'slash-menu' },
      });
      expect(state.menuStack).toHaveLength(1);
      expect(state.menuStack[0]!.id).toBe('slash-menu');
      expect(state.menuStack[0]!.index).toBe(0);
    });

    it('should push a submenu onto existing stack', () => {
      const startState = {
        ...initialState,
        menuStack: [{ id: 'slash-menu', index: 2 }],
        input: '/model',
      };
      const state = reducer(startState, {
        type: 'PUSH_MENU',
        payload: { id: 'model-switcher', index: 3, saveInput: true },
      });
      expect(state.menuStack).toHaveLength(2);
      expect(state.menuStack[0]!.id).toBe('slash-menu');
      expect(state.menuStack[1]!.id).toBe('model-switcher');
      expect(state.menuStack[1]!.index).toBe(3);
      expect(state.menuStack[1]!.savedInput).toBe('/model');
    });

    it('should not push duplicate menu at top', () => {
      const startState = {
        ...initialState,
        menuStack: [{ id: 'slash-menu', index: 2 }],
      };
      const state = reducer(startState, {
        type: 'PUSH_MENU',
        payload: { id: 'slash-menu' },
      });
      expect(state.menuStack).toHaveLength(1);
    });
  });

  describe('POP_MENU', () => {
    it('should pop menu from stack', () => {
      const startState = {
        ...initialState,
        menuStack: [{ id: 'slash-menu', index: 2 }],
      };
      const state = reducer(startState, { type: 'POP_MENU' });
      expect(state.menuStack).toHaveLength(0);
    });

    it('should restore input when popping to parent with savedInput', () => {
      const startState = {
        ...initialState,
        input: '',
        menuStack: [
          { id: 'slash-menu', index: 2, savedInput: '/model' },
          { id: 'model-switcher', index: 0 },
        ],
      };
      const state = reducer(startState, { type: 'POP_MENU' });
      expect(state.menuStack).toHaveLength(1);
      expect(state.menuStack[0]!.id).toBe('slash-menu');
      expect(state.input).toBe('/model');
    });

    it('should not change state when stack is empty', () => {
      const state = reducer(initialState, { type: 'POP_MENU' });
      expect(state).toBe(initialState);
    });
  });

  describe('SET_MENU_INDEX', () => {
    it('should update index of top menu', () => {
      const startState = {
        ...initialState,
        menuStack: [{ id: 'slash-menu', index: 0 }],
      };
      const state = reducer(startState, { type: 'SET_MENU_INDEX', payload: 3 });
      expect(state.menuStack[0]!.index).toBe(3);
    });

    it('should not change state when stack is empty', () => {
      const state = reducer(initialState, { type: 'SET_MENU_INDEX', payload: 3 });
      expect(state.menuStack).toHaveLength(0);
    });
  });

  describe('CLOSE_ALL_MENUS', () => {
    it('should clear entire stack and input', () => {
      const startState = {
        ...initialState,
        input: '/model',
        menuStack: [
          { id: 'slash-menu', index: 2 },
          { id: 'model-switcher', index: 0 },
        ],
      };
      const state = reducer(startState, { type: 'CLOSE_ALL_MENUS' });
      expect(state.menuStack).toHaveLength(0);
      expect(state.input).toBe('');
    });
  });

  describe('Hierarchical Navigation Flow', () => {
    it('should support full hierarchical menu navigation', () => {
      // Start fresh
      let state = initialState;

      // User types "/" - push slash menu
      state = reducer(state, { type: 'SET_INPUT', payload: '/' });
      state = reducer(state, { type: 'PUSH_MENU', payload: { id: 'slash-menu' } });
      expect(state.menuStack).toHaveLength(1);
      expect(state.input).toBe('/');

      // User navigates to model
      state = reducer(state, { type: 'SET_INPUT', payload: '/model' });
      state = reducer(state, { type: 'SET_MENU_INDEX', payload: 2 }); // index of model

      // User selects model - push model switcher
      state = reducer(state, {
        type: 'PUSH_MENU',
        payload: { id: 'model-switcher', index: 0, saveInput: true },
      });
      expect(state.menuStack).toHaveLength(2);
      expect(state.menuStack[1]!.savedInput).toBe('/model');

      // User presses Escape - pop model switcher, restore input
      state = reducer(state, { type: 'POP_MENU' });
      expect(state.menuStack).toHaveLength(1);
      expect(state.menuStack[0]!.id).toBe('slash-menu');
      expect(state.input).toBe('/model');

      // User presses Escape again - pop slash menu
      state = reducer(state, { type: 'POP_MENU' });
      expect(state.menuStack).toHaveLength(0);
    });
  });
});
