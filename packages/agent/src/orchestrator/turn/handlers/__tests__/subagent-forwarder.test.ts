/**
 * @fileoverview Tests for SubagentForwarder
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  SubagentForwarder,
  createSubagentForwarder,
  type SubagentForwarderDeps,
} from '../subagent-forwarder.js';
import type { SessionId } from '../../../../events/types.js';

// =============================================================================
// Test Helpers
// =============================================================================

function createMockDeps(): SubagentForwarderDeps {
  return {
    emit: vi.fn(),
  };
}

// =============================================================================
// Tests
// =============================================================================

describe('SubagentForwarder', () => {
  let deps: SubagentForwarderDeps;
  let forwarder: SubagentForwarder;

  beforeEach(() => {
    deps = createMockDeps();
    forwarder = createSubagentForwarder(deps);
  });

  describe('forwardToParent', () => {
    const subagentSessionId = 'subagent-123' as SessionId;
    const parentSessionId = 'parent-456' as SessionId;

    it('should forward message_update as text_delta', () => {
      const timestamp = new Date().toISOString();
      const event = { type: 'message_update', content: 'Hello world', sessionId: subagentSessionId, timestamp } as const;

      forwarder.forwardToParent(subagentSessionId, parentSessionId, event as any, timestamp);

      expect(deps.emit).toHaveBeenCalledWith('agent_event', {
        type: 'agent.subagent_event',
        sessionId: parentSessionId,
        timestamp,
        data: {
          subagentSessionId,
          event: {
            type: 'text_delta',
            data: { delta: 'Hello world' },
            timestamp,
          },
        },
      });
    });

    it('should forward tool_execution_start as tool_start', () => {
      const timestamp = new Date().toISOString();
      const event = {
        type: 'tool_execution_start',
        toolCallId: 'call-1',
        toolName: 'Read',
        arguments: { file_path: '/test.txt' },
        sessionId: subagentSessionId,
        timestamp,
      } as const;

      forwarder.forwardToParent(subagentSessionId, parentSessionId, event as any, timestamp);

      expect(deps.emit).toHaveBeenCalledWith('agent_event', {
        type: 'agent.subagent_event',
        sessionId: parentSessionId,
        timestamp,
        data: {
          subagentSessionId,
          event: {
            type: 'tool_start',
            data: {
              toolCallId: 'call-1',
              toolName: 'Read',
              arguments: { file_path: '/test.txt' },
            },
            timestamp,
          },
        },
      });
    });

    it('should forward tool_execution_end as tool_end', () => {
      const timestamp = new Date().toISOString();
      const event = {
        type: 'tool_execution_end',
        toolCallId: 'call-1',
        toolName: 'Read',
        result: 'file contents',
        isError: false,
        duration: 150,
        sessionId: subagentSessionId,
        timestamp,
      } as const;

      forwarder.forwardToParent(subagentSessionId, parentSessionId, event as any, timestamp);

      expect(deps.emit).toHaveBeenCalledWith('agent_event', {
        type: 'agent.subagent_event',
        sessionId: parentSessionId,
        timestamp,
        data: {
          subagentSessionId,
          event: {
            type: 'tool_end',
            data: {
              toolCallId: 'call-1',
              toolName: 'Read',
              success: true,
              result: 'file contents',
              duration: 150,
            },
            timestamp,
          },
        },
      });
    });

    it('should stringify non-string tool results', () => {
      const timestamp = new Date().toISOString();
      const event = {
        type: 'tool_execution_end',
        toolCallId: 'call-1',
        toolName: 'Read',
        result: { content: 'file contents', lines: 10 },
        isError: false,
        sessionId: subagentSessionId,
        timestamp,
      } as const;

      forwarder.forwardToParent(subagentSessionId, parentSessionId, event as any, timestamp);

      expect(deps.emit).toHaveBeenCalledWith('agent_event', {
        type: 'agent.subagent_event',
        sessionId: parentSessionId,
        timestamp,
        data: {
          subagentSessionId,
          event: {
            type: 'tool_end',
            data: expect.objectContaining({
              result: JSON.stringify({ content: 'file contents', lines: 10 }),
            }),
            timestamp,
          },
        },
      });
    });

    it('should forward turn_start with status update', () => {
      const timestamp = new Date().toISOString();
      const event = { type: 'turn_start', turn: 2, sessionId: subagentSessionId, timestamp } as const;

      forwarder.forwardToParent(subagentSessionId, parentSessionId, event as any, timestamp);

      // Should emit status update
      expect(deps.emit).toHaveBeenCalledWith('agent_event', {
        type: 'agent.subagent_status',
        sessionId: parentSessionId,
        timestamp,
        data: {
          subagentSessionId,
          status: 'running',
          currentTurn: 2,
        },
      });

      // Should also emit forwarded event
      expect(deps.emit).toHaveBeenCalledWith('agent_event', {
        type: 'agent.subagent_event',
        sessionId: parentSessionId,
        timestamp,
        data: {
          subagentSessionId,
          event: {
            type: 'turn_start',
            data: { turn: 2 },
            timestamp,
          },
        },
      });
    });

    it('should default turn to 1 for status update', () => {
      const timestamp = new Date().toISOString();
      const event = { type: 'turn_start', sessionId: subagentSessionId, timestamp } as const;

      forwarder.forwardToParent(subagentSessionId, parentSessionId, event as any, timestamp);

      expect(deps.emit).toHaveBeenCalledWith('agent_event', {
        type: 'agent.subagent_status',
        sessionId: parentSessionId,
        timestamp,
        data: {
          subagentSessionId,
          status: 'running',
          currentTurn: 1,
        },
      });
    });

    it('should forward turn_end', () => {
      const timestamp = new Date().toISOString();
      const event = { type: 'turn_end', turn: 3, sessionId: subagentSessionId, timestamp } as const;

      forwarder.forwardToParent(subagentSessionId, parentSessionId, event as any, timestamp);

      expect(deps.emit).toHaveBeenCalledWith('agent_event', {
        type: 'agent.subagent_event',
        sessionId: parentSessionId,
        timestamp,
        data: {
          subagentSessionId,
          event: {
            type: 'turn_end',
            data: { turn: 3 },
            timestamp,
          },
        },
      });
    });

    it('should not forward non-forwardable events', () => {
      const timestamp = new Date().toISOString();
      const event = { type: 'thinking_delta', delta: 'thinking...', sessionId: subagentSessionId, timestamp } as const;

      forwarder.forwardToParent(subagentSessionId, parentSessionId, event as any, timestamp);

      expect(deps.emit).not.toHaveBeenCalled();
    });

    it('should not forward agent_start', () => {
      const timestamp = new Date().toISOString();
      const event = { type: 'agent_start', sessionId: subagentSessionId, timestamp } as const;

      forwarder.forwardToParent(subagentSessionId, parentSessionId, event as any, timestamp);

      expect(deps.emit).not.toHaveBeenCalled();
    });

    it('should not forward compaction_complete', () => {
      const timestamp = new Date().toISOString();
      const event = {
        type: 'compaction_complete',
        tokensBefore: 100000,
        tokensAfter: 50000,
        success: true,
        compressionRatio: 0.5,
        sessionId: subagentSessionId,
        timestamp,
      } as const;

      forwarder.forwardToParent(subagentSessionId, parentSessionId, event as any, timestamp);

      expect(deps.emit).not.toHaveBeenCalled();
    });
  });

  describe('factory function', () => {
    it('should create SubagentForwarder instance', () => {
      const forwarder = createSubagentForwarder(deps);
      expect(forwarder).toBeInstanceOf(SubagentForwarder);
    });
  });
});
