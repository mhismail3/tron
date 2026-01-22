/**
 * @fileoverview Tests for SessionEnd built-in hook
 */
import { describe, it, expect } from 'vitest';
import {
  createSessionEndHook,
  type SessionEndContext,
} from '../../../src/hooks/builtin/session-end.js';

describe('SessionEnd Hook', () => {
  const createContext = (overrides: Partial<SessionEndContext> = {}): SessionEndContext => ({
    hookType: 'SessionEnd',
    sessionId: 'test-session',
    timestamp: new Date().toISOString(),
    messageCount: 10,
    toolCallCount: 5,
    data: {},
    ...overrides,
  });

  describe('creation', () => {
    it('should create hook with correct properties', () => {
      const hook = createSessionEndHook();

      expect(hook.name).toBe('builtin:session-end');
      expect(hook.type).toBe('SessionEnd');
      expect(hook.priority).toBe(100);
    });

    it('should accept optional config', () => {
      const hook = createSessionEndHook({
        minMessagesForProcessing: 5,
      });

      expect(hook.name).toBe('builtin:session-end');
    });
  });

  describe('session processing', () => {
    it('should process session with enough messages', async () => {
      const hook = createSessionEndHook();
      const context = createContext({ messageCount: 5 });

      const result = await hook.handler(context);

      expect(result.action).toBe('continue');
      expect((result as any).modifications?.sessionEnded).toBe(true);
    });

    it('should skip processing for very short sessions', async () => {
      const hook = createSessionEndHook({
        minMessagesForProcessing: 5,
      });
      const context = createContext({ messageCount: 2 });

      const result = await hook.handler(context);

      expect(result.action).toBe('continue');
      expect((result as any).modifications).toBeUndefined();
    });

    it('should include tool call count in summary', async () => {
      const hook = createSessionEndHook();
      const context = createContext({ toolCallCount: 15 });

      const result = await hook.handler(context);

      expect(result.message).toContain('15 tool calls');
    });

    it('should include error in summary when session failed', async () => {
      const hook = createSessionEndHook();
      const context = createContext({
        outcome: 'error',
        error: 'Connection lost',
      });

      const result = await hook.handler(context);

      expect(result.message).toContain('Connection lost');
    });

    it('should set outcome in modifications', async () => {
      const hook = createSessionEndHook();
      const context = createContext({ outcome: 'completed' });

      const result = await hook.handler(context) as any;

      expect(result.modifications?.outcome).toBe('completed');
    });

    it('should default to completed outcome', async () => {
      const hook = createSessionEndHook();
      const context = createContext();

      const result = await hook.handler(context) as any;

      expect(result.modifications?.outcome).toBe('completed');
    });
  });
});
