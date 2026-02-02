/**
 * @fileoverview Tests for SubagentForwarder
 *
 * SubagentForwarder uses EventContext for automatic metadata injection.
 * It forwards streaming events from subagent sessions to their parent sessions.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import {
  SubagentForwarder,
  createSubagentForwarder,
  type SubagentForwarderDeps,
} from '../subagent-forwarder.js';
import { createTestEventContext, type TestEventContext } from '../../event-context.js';
import type { SessionId } from '../../../../events/types.js';
import type { TronEvent } from '../../../../types/events.js';

// =============================================================================
// Test Helpers
// =============================================================================

function createMockDeps(): SubagentForwarderDeps {
  return {};
}

function createTestContext(options: {
  sessionId?: SessionId;
  runId?: string;
} = {}): TestEventContext {
  return createTestEventContext({
    sessionId: options.sessionId ?? ('parent-456' as SessionId),
    runId: options.runId,
  });
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

    it('should forward message_update as text_delta via context', () => {
      const ctx = createTestContext({ sessionId: parentSessionId, runId: 'run-123' });
      const event = { type: 'message_update', content: 'Hello world' } as unknown as TronEvent;

      forwarder.forwardToParent(ctx, subagentSessionId, event);

      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0]).toEqual({
        type: 'agent.subagent_event',
        data: {
          subagentSessionId,
          event: {
            type: 'text_delta',
            data: { delta: 'Hello world' },
            timestamp: ctx.timestamp,
          },
        },
      });
    });

    it('should forward tool_execution_start as tool_start via context', () => {
      const ctx = createTestContext({ sessionId: parentSessionId, runId: 'run-456' });
      const event = {
        type: 'tool_execution_start',
        toolCallId: 'call-1',
        toolName: 'Read',
        arguments: { file_path: '/test.txt' },
      } as unknown as TronEvent;

      forwarder.forwardToParent(ctx, subagentSessionId, event);

      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0]).toEqual({
        type: 'agent.subagent_event',
        data: {
          subagentSessionId,
          event: {
            type: 'tool_start',
            data: {
              toolCallId: 'call-1',
              toolName: 'Read',
              arguments: { file_path: '/test.txt' },
            },
            timestamp: ctx.timestamp,
          },
        },
      });
    });

    it('should forward tool_execution_end as tool_end via context', () => {
      const ctx = createTestContext({ sessionId: parentSessionId, runId: 'run-789' });
      const event = {
        type: 'tool_execution_end',
        toolCallId: 'call-1',
        toolName: 'Read',
        result: 'file contents',
        isError: false,
        duration: 150,
      } as unknown as TronEvent;

      forwarder.forwardToParent(ctx, subagentSessionId, event);

      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0]).toEqual({
        type: 'agent.subagent_event',
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
            timestamp: ctx.timestamp,
          },
        },
      });
    });

    it('should stringify non-string tool results', () => {
      const ctx = createTestContext({ sessionId: parentSessionId, runId: 'run-000' });
      const event = {
        type: 'tool_execution_end',
        toolCallId: 'call-1',
        toolName: 'Read',
        result: { content: 'file contents', lines: 10 },
        isError: false,
      } as unknown as TronEvent;

      forwarder.forwardToParent(ctx, subagentSessionId, event);

      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0].data).toMatchObject({
        subagentSessionId,
        event: {
          type: 'tool_end',
          data: expect.objectContaining({
            result: JSON.stringify({ content: 'file contents', lines: 10 }),
          }),
        },
      });
    });

    it('should forward turn_start with status update via context', () => {
      const ctx = createTestContext({ sessionId: parentSessionId, runId: 'run-111' });
      const event = { type: 'turn_start', turn: 2 } as unknown as TronEvent;

      forwarder.forwardToParent(ctx, subagentSessionId, event);

      // Should emit 2 events: status update and forwarded event
      expect(ctx.emitCalls).toHaveLength(2);

      // Status update
      expect(ctx.emitCalls[0]).toEqual({
        type: 'agent.subagent_status',
        data: {
          subagentSessionId,
          status: 'running',
          currentTurn: 2,
        },
      });

      // Forwarded event
      expect(ctx.emitCalls[1]).toEqual({
        type: 'agent.subagent_event',
        data: {
          subagentSessionId,
          event: {
            type: 'turn_start',
            data: { turn: 2 },
            timestamp: ctx.timestamp,
          },
        },
      });
    });

    it('should default turn to 1 for status update', () => {
      const ctx = createTestContext({ sessionId: parentSessionId, runId: 'run-222' });
      const event = { type: 'turn_start' } as unknown as TronEvent;

      forwarder.forwardToParent(ctx, subagentSessionId, event);

      expect(ctx.emitCalls).toHaveLength(2);
      expect(ctx.emitCalls[0]).toEqual({
        type: 'agent.subagent_status',
        data: {
          subagentSessionId,
          status: 'running',
          currentTurn: 1,
        },
      });
    });

    it('should forward turn_end via context', () => {
      const ctx = createTestContext({ sessionId: parentSessionId, runId: 'run-333' });
      const event = { type: 'turn_end', turn: 3 } as unknown as TronEvent;

      forwarder.forwardToParent(ctx, subagentSessionId, event);

      expect(ctx.emitCalls).toHaveLength(1);
      expect(ctx.emitCalls[0]).toEqual({
        type: 'agent.subagent_event',
        data: {
          subagentSessionId,
          event: {
            type: 'turn_end',
            data: { turn: 3 },
            timestamp: ctx.timestamp,
          },
        },
      });
    });

    it('should not forward non-forwardable events', () => {
      const ctx = createTestContext({ sessionId: parentSessionId });
      const event = { type: 'thinking_delta', delta: 'thinking...' } as unknown as TronEvent;

      forwarder.forwardToParent(ctx, subagentSessionId, event);

      expect(ctx.emitCalls).toHaveLength(0);
    });

    it('should not forward agent_start', () => {
      const ctx = createTestContext({ sessionId: parentSessionId });
      const event = { type: 'agent_start' } as unknown as TronEvent;

      forwarder.forwardToParent(ctx, subagentSessionId, event);

      expect(ctx.emitCalls).toHaveLength(0);
    });

    it('should not forward compaction_complete', () => {
      const ctx = createTestContext({ sessionId: parentSessionId });
      const event = {
        type: 'compaction_complete',
        tokensBefore: 100000,
        tokensAfter: 50000,
        success: true,
        compressionRatio: 0.5,
      } as unknown as TronEvent;

      forwarder.forwardToParent(ctx, subagentSessionId, event);

      expect(ctx.emitCalls).toHaveLength(0);
    });
  });

  describe('factory function', () => {
    it('should create SubagentForwarder instance', () => {
      const forwarder = createSubagentForwarder(deps);
      expect(forwarder).toBeInstanceOf(SubagentForwarder);
    });
  });
});
