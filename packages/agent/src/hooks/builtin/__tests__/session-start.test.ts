/**
 * @fileoverview Tests for SessionStart built-in hook
 */
import { describe, it, expect } from 'vitest';
import { createSessionStartHook } from '../session-start.js';
import type { SessionStartHookContext } from '../../types.js';

describe('SessionStart Hook', () => {
  const createContext = (overrides: Partial<SessionStartHookContext> = {}): SessionStartHookContext => ({
    hookType: 'SessionStart',
    sessionId: 'test-session',
    timestamp: new Date().toISOString(),
    workingDirectory: '/test/project',
    data: {},
    ...overrides,
  });

  describe('creation', () => {
    it('should create hook with correct properties', () => {
      const hook = createSessionStartHook();

      expect(hook.name).toBe('builtin:session-start');
      expect(hook.type).toBe('SessionStart');
      expect(hook.priority).toBe(100);
      expect(typeof hook.handler).toBe('function');
    });

    it('should accept optional initial context', () => {
      const hook = createSessionStartHook({
        initialContext: 'Custom context injection',
      });

      expect(hook.name).toBe('builtin:session-start');
    });
  });

  describe('handler', () => {
    it('should return continue when no initial context', async () => {
      const hook = createSessionStartHook();
      const context = createContext();
      const result = await hook.handler(context);

      expect(result.action).toBe('continue');
      expect(result.message).toBeUndefined();
    });

    it('should return modify when initial context is provided', async () => {
      const hook = createSessionStartHook({
        initialContext: 'Start by reviewing the auth module',
      });
      const context = createContext();
      const result = await hook.handler(context);

      expect(result.action).toBe('modify');
      expect(result.message).toBe('Start by reviewing the auth module');
    });

    it('should include modifications when initial context provided', async () => {
      const hook = createSessionStartHook({
        initialContext: 'Custom instructions',
      });
      const context = createContext();
      const result = await hook.handler(context) as any;

      expect(result.modifications?.systemContext).toBe('Custom instructions');
    });
  });
});
