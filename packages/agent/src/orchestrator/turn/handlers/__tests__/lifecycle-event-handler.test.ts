/**
 * @fileoverview Tests for LifecycleEventHandler
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  LifecycleEventHandler,
  createLifecycleEventHandler,
  type LifecycleEventHandlerDeps,
} from '../lifecycle-event-handler.js';
import type { SessionId } from '../../../../events/types.js';
import type { ActiveSession } from '../../../types.js';

// =============================================================================
// Test Helpers
// =============================================================================

function createMockUIRenderHandler() {
  return {
    handleToolStart: vi.fn(),
    handleToolEnd: vi.fn(),
    handleToolCallDelta: vi.fn(),
    cleanup: vi.fn(),
  };
}

function createMockDeps(): LifecycleEventHandlerDeps {
  return {
    defaultProvider: 'anthropic',
    getActiveSession: vi.fn(),
    appendEventLinearized: vi.fn(),
    emit: vi.fn(),
    uiRenderHandler: createMockUIRenderHandler() as unknown as LifecycleEventHandlerDeps['uiRenderHandler'],
  };
}

function createMockActiveSession(overrides: Partial<ActiveSession> = {}): ActiveSession {
  return {
    sessionId: 'test-session' as SessionId,
    model: 'claude-sonnet-4-20250514',
    agent: {} as ActiveSession['agent'],
    sessionContext: {
      onAgentStart: vi.fn(),
      onAgentEnd: vi.fn(),
    } as unknown as ActiveSession['sessionContext'],
    ...overrides,
  } as ActiveSession;
}

// =============================================================================
// Tests
// =============================================================================

describe('LifecycleEventHandler', () => {
  let deps: LifecycleEventHandlerDeps;
  let handler: LifecycleEventHandler;

  beforeEach(() => {
    deps = createMockDeps();
    handler = createLifecycleEventHandler(deps);
  });

  describe('handleAgentStart', () => {
    it('should call onAgentStart on session context', () => {
      const sessionId = 'test-session' as SessionId;
      const timestamp = new Date().toISOString();
      const mockActive = createMockActiveSession();

      handler.handleAgentStart(sessionId, timestamp, mockActive);

      expect(mockActive.sessionContext!.onAgentStart).toHaveBeenCalled();
    });

    it('should emit agent.turn_start event', () => {
      const sessionId = 'test-session' as SessionId;
      const timestamp = new Date().toISOString();

      handler.handleAgentStart(sessionId, timestamp, undefined);

      expect(deps.emit).toHaveBeenCalledWith('agent_event', {
        type: 'agent.turn_start',
        sessionId,
        timestamp,
        data: {},
      });
    });

    it('should handle undefined active session', () => {
      const sessionId = 'test-session' as SessionId;
      const timestamp = new Date().toISOString();

      handler.handleAgentStart(sessionId, timestamp, undefined);

      // Should still emit event
      expect(deps.emit).toHaveBeenCalled();
    });
  });

  describe('handleAgentEnd', () => {
    it('should call onAgentEnd on session context', () => {
      const mockActive = createMockActiveSession();

      handler.handleAgentEnd(mockActive);

      expect(mockActive.sessionContext!.onAgentEnd).toHaveBeenCalled();
    });

    it('should cleanup UI render handler', () => {
      const mockActive = createMockActiveSession();

      handler.handleAgentEnd(mockActive);

      expect(deps.uiRenderHandler.cleanup).toHaveBeenCalled();
    });

    it('should handle undefined active session', () => {
      handler.handleAgentEnd(undefined);

      // Should still cleanup UI render handler
      expect(deps.uiRenderHandler.cleanup).toHaveBeenCalled();
    });

    it('should not emit agent.complete (emitted elsewhere)', () => {
      const mockActive = createMockActiveSession();

      handler.handleAgentEnd(mockActive);

      // agent.complete is emitted in runAgent() AFTER all events are persisted
      expect(deps.emit).not.toHaveBeenCalled();
    });
  });

  describe('handleAgentInterrupted', () => {
    it('should emit agent.complete with interrupted status', () => {
      const sessionId = 'test-session' as SessionId;
      const event = { type: 'agent_interrupted', partialContent: 'partial text' };
      const timestamp = new Date().toISOString();

      handler.handleAgentInterrupted(sessionId, event, timestamp);

      expect(deps.emit).toHaveBeenCalledWith('agent_event', {
        type: 'agent.complete',
        sessionId,
        timestamp,
        data: {
          success: false,
          interrupted: true,
          partialContent: 'partial text',
        },
      });
    });

    it('should handle missing partialContent', () => {
      const sessionId = 'test-session' as SessionId;
      const event = { type: 'agent_interrupted' };
      const timestamp = new Date().toISOString();

      handler.handleAgentInterrupted(sessionId, event, timestamp);

      expect(deps.emit).toHaveBeenCalledWith('agent_event', {
        type: 'agent.complete',
        sessionId,
        timestamp,
        data: {
          success: false,
          interrupted: true,
          partialContent: undefined,
        },
      });
    });
  });

  describe('handleApiRetry', () => {
    it('should persist error.provider event', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'api_retry',
        errorMessage: 'Rate limit exceeded',
        errorCategory: 'rate_limit',
        delayMs: 5000,
      };

      handler.handleApiRetry(sessionId, event);

      expect(deps.appendEventLinearized).toHaveBeenCalledWith(
        sessionId,
        'error.provider',
        {
          provider: 'anthropic',
          error: 'Rate limit exceeded',
          code: 'rate_limit',
          retryable: true,
          retryAfter: 5000,
        }
      );
    });

    it('should handle missing error details', () => {
      const sessionId = 'test-session' as SessionId;
      const event = { type: 'api_retry' };

      handler.handleApiRetry(sessionId, event);

      expect(deps.appendEventLinearized).toHaveBeenCalledWith(
        sessionId,
        'error.provider',
        {
          provider: 'anthropic',
          error: undefined,
          code: undefined,
          retryable: true,
          retryAfter: undefined,
        }
      );
    });
  });

  describe('factory function', () => {
    it('should create LifecycleEventHandler instance', () => {
      const handler = createLifecycleEventHandler(deps);
      expect(handler).toBeInstanceOf(LifecycleEventHandler);
    });
  });
});
