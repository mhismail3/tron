/**
 * @fileoverview ContextClearHandler Unit Tests
 *
 * Tests for the ContextClearHandler which builds context.cleared events.
 *
 * Contract:
 * 1. Build context.cleared event with token stats
 * 2. Track reason for clearing
 */
import { describe, it, expect, beforeEach } from 'vitest';
import {
  ContextClearHandler,
  createContextClearHandler,
  type ContextClearContext,
} from '../context-clear.js';

describe('ContextClearHandler', () => {
  let handler: ContextClearHandler;

  beforeEach(() => {
    handler = createContextClearHandler();
  });

  describe('buildClearEvent()', () => {
    it('should create context.cleared event', () => {
      const context: ContextClearContext = {
        sessionId: 'session_1',
        tokensBefore: 100000,
        tokensAfter: 5000,
        reason: 'manual',
      };

      const event = handler.buildClearEvent(context);

      expect(event.type).toBe('context.cleared');
    });

    it('should include token stats in payload', () => {
      const context: ContextClearContext = {
        sessionId: 'session_1',
        tokensBefore: 150000,
        tokensAfter: 3000,
        reason: 'manual',
      };

      const event = handler.buildClearEvent(context);

      expect(event.payload).toMatchObject({
        tokensBefore: 150000,
        tokensAfter: 3000,
      });
    });

    it('should include reason in payload', () => {
      const context: ContextClearContext = {
        sessionId: 'session_1',
        tokensBefore: 100000,
        tokensAfter: 5000,
        reason: 'manual',
      };

      const event = handler.buildClearEvent(context);

      expect(event.payload.reason).toBe('manual');
    });

    it('should handle different reasons', () => {
      const contextManual: ContextClearContext = {
        sessionId: 'session_1',
        tokensBefore: 100000,
        tokensAfter: 5000,
        reason: 'manual',
      };

      const contextAuto: ContextClearContext = {
        sessionId: 'session_1',
        tokensBefore: 100000,
        tokensAfter: 5000,
        reason: 'automatic',
      };

      expect(handler.buildClearEvent(contextManual).payload.reason).toBe('manual');
      expect(handler.buildClearEvent(contextAuto).payload.reason).toBe('automatic');
    });

    it('should handle zero tokens after clear', () => {
      const context: ContextClearContext = {
        sessionId: 'session_1',
        tokensBefore: 100000,
        tokensAfter: 0,
        reason: 'manual',
      };

      const event = handler.buildClearEvent(context);

      expect(event.payload.tokensAfter).toBe(0);
    });

    it('should handle equal before and after (no effect)', () => {
      const context: ContextClearContext = {
        sessionId: 'session_1',
        tokensBefore: 5000,
        tokensAfter: 5000,
        reason: 'manual',
      };

      const event = handler.buildClearEvent(context);

      expect(event.payload.tokensBefore).toBe(5000);
      expect(event.payload.tokensAfter).toBe(5000);
    });
  });

  describe('calculateTokensFreed()', () => {
    it('should calculate tokens freed correctly', () => {
      const context: ContextClearContext = {
        sessionId: 'session_1',
        tokensBefore: 100000,
        tokensAfter: 5000,
        reason: 'manual',
      };

      const freed = handler.calculateTokensFreed(context);

      expect(freed).toBe(95000);
    });

    it('should handle no tokens freed', () => {
      const context: ContextClearContext = {
        sessionId: 'session_1',
        tokensBefore: 5000,
        tokensAfter: 5000,
        reason: 'manual',
      };

      const freed = handler.calculateTokensFreed(context);

      expect(freed).toBe(0);
    });
  });
});
