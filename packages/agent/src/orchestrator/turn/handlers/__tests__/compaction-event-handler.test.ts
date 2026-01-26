/**
 * @fileoverview Tests for CompactionEventHandler
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  CompactionEventHandler,
  createCompactionEventHandler,
  type CompactionEventHandlerDeps,
} from '../compaction-event-handler.js';
import type { SessionId } from '../../../../events/types.js';

// =============================================================================
// Test Helpers
// =============================================================================

function createMockDeps(): CompactionEventHandlerDeps {
  return {
    appendEventLinearized: vi.fn(),
    emit: vi.fn(),
  };
}

// =============================================================================
// Tests
// =============================================================================

describe('CompactionEventHandler', () => {
  let deps: CompactionEventHandlerDeps;
  let handler: CompactionEventHandler;

  beforeEach(() => {
    deps = createMockDeps();
    handler = createCompactionEventHandler(deps);
  });

  describe('handleCompactionComplete', () => {
    it('should emit agent.compaction event', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'compaction_complete',
        tokensBefore: 100000,
        tokensAfter: 50000,
        compressionRatio: 0.5,
        reason: 'auto',
        success: true,
        summary: 'Compacted context',
      };
      const timestamp = new Date().toISOString();

      handler.handleCompactionComplete(sessionId, event, timestamp);

      expect(deps.emit).toHaveBeenCalledWith('agent_event', {
        type: 'agent.compaction',
        sessionId,
        timestamp,
        data: {
          tokensBefore: 100000,
          tokensAfter: 50000,
          compressionRatio: 0.5,
          reason: 'auto',
          summary: 'Compacted context',
        },
      });
    });

    it('should persist compact.boundary event on success', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'compaction_complete',
        tokensBefore: 100000,
        tokensAfter: 50000,
        compressionRatio: 0.5,
        reason: 'manual',
        success: true,
        summary: 'User-requested compaction',
      };
      const timestamp = new Date().toISOString();

      handler.handleCompactionComplete(sessionId, event, timestamp);

      expect(deps.appendEventLinearized).toHaveBeenCalledWith(
        sessionId,
        'compact.boundary',
        {
          originalTokens: 100000,
          compactedTokens: 50000,
          compressionRatio: 0.5,
          reason: 'manual',
          summary: 'User-requested compaction',
        }
      );
    });

    it('should not persist event on failure', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'compaction_complete',
        tokensBefore: 100000,
        tokensAfter: 100000,
        success: false,
      };
      const timestamp = new Date().toISOString();

      handler.handleCompactionComplete(sessionId, event, timestamp);

      // Should still emit streaming event
      expect(deps.emit).toHaveBeenCalled();
      // But should not persist
      expect(deps.appendEventLinearized).not.toHaveBeenCalled();
    });

    it('should default reason to auto', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'compaction_complete',
        tokensBefore: 100000,
        tokensAfter: 50000,
        success: true,
      };
      const timestamp = new Date().toISOString();

      handler.handleCompactionComplete(sessionId, event, timestamp);

      expect(deps.emit).toHaveBeenCalledWith(
        'agent_event',
        expect.objectContaining({
          data: expect.objectContaining({
            reason: 'auto',
          }),
        })
      );

      expect(deps.appendEventLinearized).toHaveBeenCalledWith(
        sessionId,
        'compact.boundary',
        expect.objectContaining({
          reason: 'auto',
        })
      );
    });

    it('should persist when success is undefined (default true)', () => {
      const sessionId = 'test-session' as SessionId;
      const event = {
        type: 'compaction_complete',
        tokensBefore: 100000,
        tokensAfter: 50000,
      };
      const timestamp = new Date().toISOString();

      handler.handleCompactionComplete(sessionId, event, timestamp);

      // Should persist (success !== false)
      expect(deps.appendEventLinearized).toHaveBeenCalled();
    });
  });

  describe('factory function', () => {
    it('should create CompactionEventHandler instance', () => {
      const handler = createCompactionEventHandler(deps);
      expect(handler).toBeInstanceOf(CompactionEventHandler);
    });
  });
});
