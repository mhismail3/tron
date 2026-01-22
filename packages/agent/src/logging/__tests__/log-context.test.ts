/**
 * @fileoverview TDD Tests for LogContext - AsyncLocalStorage context propagation
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import {
  withLoggingContext,
  getLoggingContext,
  updateLoggingContext,
  setLoggingContext,
  clearLoggingContext,
  type LoggingContext,
} from '../log-context.js';

describe('LogContext', () => {
  beforeEach(() => {
    clearLoggingContext();
  });

  afterEach(() => {
    clearLoggingContext();
  });

  describe('withLoggingContext()', () => {
    it('provides context to sync code', () => {
      let capturedContext: LoggingContext | null = null;

      withLoggingContext({ sessionId: 'sess_sync' }, () => {
        capturedContext = getLoggingContext();
      });

      expect(capturedContext).toEqual({ sessionId: 'sess_sync' });
    });

    it('provides context through async boundaries', async () => {
      let capturedContext: LoggingContext | null = null;

      await withLoggingContext({ sessionId: 'sess_async' }, async () => {
        // Simulate async operation
        await new Promise(resolve => setTimeout(resolve, 10));
        capturedContext = getLoggingContext();
      });

      expect(capturedContext).toEqual({ sessionId: 'sess_async' });
    });

    it('supports nested contexts', () => {
      let outerContext: LoggingContext | null = null;
      let innerContext: LoggingContext | null = null;

      withLoggingContext({ sessionId: 'sess_outer' }, () => {
        outerContext = getLoggingContext();

        withLoggingContext({ turn: 1 }, () => {
          innerContext = getLoggingContext();
        });
      });

      expect(outerContext).toEqual({ sessionId: 'sess_outer' });
      expect(innerContext).toEqual({ sessionId: 'sess_outer', turn: 1 });
    });

    it('merges nested context with parent', () => {
      let result: LoggingContext | null = null;

      withLoggingContext({ sessionId: 'sess_parent', workspaceId: 'ws_parent' }, () => {
        withLoggingContext({ turn: 5, eventId: 'evt_123' }, () => {
          result = getLoggingContext();
        });
      });

      expect(result).toEqual({
        sessionId: 'sess_parent',
        workspaceId: 'ws_parent',
        turn: 5,
        eventId: 'evt_123',
      });
    });

    it('allows child to override parent context', () => {
      let result: LoggingContext | null = null;

      withLoggingContext({ sessionId: 'sess_parent', turn: 1 }, () => {
        withLoggingContext({ turn: 2 }, () => {
          result = getLoggingContext();
        });
      });

      expect(result).toEqual({ sessionId: 'sess_parent', turn: 2 });
    });

    it('returns the function result', () => {
      const result = withLoggingContext({ sessionId: 'test' }, () => {
        return 'return value';
      });

      expect(result).toBe('return value');
    });

    it('returns async function result', async () => {
      const result = await withLoggingContext({ sessionId: 'test' }, async () => {
        await new Promise(resolve => setTimeout(resolve, 1));
        return 42;
      });

      expect(result).toBe(42);
    });

    it('propagates through Promise chains', async () => {
      let capturedContext: LoggingContext | null = null;

      await withLoggingContext({ sessionId: 'sess_promise' }, () => {
        return Promise.resolve()
          .then(() => new Promise(resolve => setTimeout(resolve, 5)))
          .then(() => {
            capturedContext = getLoggingContext();
          });
      });

      expect(capturedContext).toEqual({ sessionId: 'sess_promise' });
    });

    it('isolates context between parallel async operations', async () => {
      const results: LoggingContext[] = [];

      await Promise.all([
        withLoggingContext({ sessionId: 'sess_1' }, async () => {
          await new Promise(resolve => setTimeout(resolve, 10));
          results.push({ ...getLoggingContext() });
        }),
        withLoggingContext({ sessionId: 'sess_2' }, async () => {
          await new Promise(resolve => setTimeout(resolve, 5));
          results.push({ ...getLoggingContext() });
        }),
      ]);

      expect(results).toHaveLength(2);
      expect(results.some(r => r.sessionId === 'sess_1')).toBe(true);
      expect(results.some(r => r.sessionId === 'sess_2')).toBe(true);
    });
  });

  describe('getLoggingContext()', () => {
    it('returns empty object outside context', () => {
      const context = getLoggingContext();
      expect(context).toEqual({});
    });

    it('returns current context inside withLoggingContext', () => {
      withLoggingContext({ sessionId: 'test', turn: 3 }, () => {
        const context = getLoggingContext();
        expect(context).toEqual({ sessionId: 'test', turn: 3 });
      });
    });

    it('returns empty object after context exits', () => {
      withLoggingContext({ sessionId: 'test' }, () => {
        // Inside context
      });

      const context = getLoggingContext();
      expect(context).toEqual({});
    });
  });

  describe('updateLoggingContext()', () => {
    it('updates context in place', () => {
      withLoggingContext({ sessionId: 'test' }, () => {
        updateLoggingContext({ turn: 1 });
        expect(getLoggingContext()).toEqual({ sessionId: 'test', turn: 1 });

        updateLoggingContext({ eventId: 'evt_123' });
        expect(getLoggingContext()).toEqual({ sessionId: 'test', turn: 1, eventId: 'evt_123' });
      });
    });

    it('does nothing outside context', () => {
      // Should not throw
      updateLoggingContext({ sessionId: 'test' });
      expect(getLoggingContext()).toEqual({});
    });

    it('can override existing values', () => {
      withLoggingContext({ turn: 1 }, () => {
        updateLoggingContext({ turn: 2 });
        expect(getLoggingContext().turn).toBe(2);
      });
    });
  });

  describe('setLoggingContext()', () => {
    it('sets context for testing', () => {
      setLoggingContext({ sessionId: 'test_session' });
      expect(getLoggingContext()).toEqual({ sessionId: 'test_session' });
    });

    it('replaces existing context', () => {
      setLoggingContext({ sessionId: 'first' });
      setLoggingContext({ sessionId: 'second' });
      expect(getLoggingContext().sessionId).toBe('second');
    });
  });

  describe('clearLoggingContext()', () => {
    it('clears the context', () => {
      setLoggingContext({ sessionId: 'test' });
      clearLoggingContext();
      // After clear, new getLoggingContext should return empty
      expect(getLoggingContext()).toEqual({});
    });
  });
});
