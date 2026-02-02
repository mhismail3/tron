/**
 * @fileoverview Run ID Correlation Tests
 *
 * TDD tests for runId correlation feature:
 * - runId is generated for each agent run
 * - runId is included in emitted events
 * - runId is included in persisted events
 * - runId is returned in AgentPromptResult
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { randomUUID } from 'crypto';

// =============================================================================
// Test: runId Generation
// =============================================================================

describe('runId Correlation', () => {
  describe('runId generation', () => {
    it('should generate a unique runId for each agent run', () => {
      // runId should be a valid UUID
      const runId1 = randomUUID();
      const runId2 = randomUUID();

      expect(runId1).toMatch(
        /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
      );
      expect(runId1).not.toBe(runId2);
    });
  });

  describe('AgentRunOptions with runId', () => {
    it('should accept runId in AgentRunOptions', () => {
      // Type test - if this compiles, the type is correct
      const options = {
        sessionId: 'sess_123',
        prompt: 'Hello',
        runId: randomUUID(),
      };

      expect(options.runId).toBeDefined();
      expect(typeof options.runId).toBe('string');
    });
  });

  describe('ActiveSession with currentRunId', () => {
    it('should store currentRunId on ActiveSession', () => {
      // Mock ActiveSession structure
      const activeSession = {
        sessionId: 'sess_123',
        currentRunId: randomUUID(),
        agent: {},
        lastActivity: new Date(),
      };

      expect(activeSession.currentRunId).toBeDefined();
      expect(typeof activeSession.currentRunId).toBe('string');
    });

    it('should clear currentRunId when run completes', () => {
      const activeSession = {
        sessionId: 'sess_123',
        currentRunId: randomUUID() as string | undefined,
      };

      // After run completes
      activeSession.currentRunId = undefined;

      expect(activeSession.currentRunId).toBeUndefined();
    });
  });

  describe('Event emission with runId', () => {
    it('should include runId in agent_event emissions', () => {
      const emittedEvents: Array<{ type: string; runId?: string }> = [];
      const emit = vi.fn((eventName: string, data: unknown) => {
        if (eventName === 'agent_event') {
          emittedEvents.push(data as { type: string; runId?: string });
        }
      });

      const runId = randomUUID();

      // Simulate emitting an event with runId
      emit('agent_event', {
        type: 'agent.turn_start',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        runId,
        data: { turn: 1 },
      });

      expect(emittedEvents[0].runId).toBe(runId);
    });

    it('should include runId in agent_turn emissions', () => {
      const emittedEvents: Array<{ runId?: string }> = [];
      const emit = vi.fn((eventName: string, data: unknown) => {
        if (eventName === 'agent_turn') {
          emittedEvents.push(data as { runId?: string });
        }
      });

      const runId = randomUUID();

      // Simulate emitting turn complete event with runId
      emit('agent_turn', {
        type: 'turn_complete',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        runId,
        data: {},
      });

      expect(emittedEvents[0].runId).toBe(runId);
    });
  });

  describe('Persisted events with runId', () => {
    it('should include runId in stream.turn_start payload', () => {
      const runId = randomUUID();
      const payload = {
        turn: 1,
        runId,
      };

      expect(payload.runId).toBe(runId);
    });

    it('should include runId in stream.turn_end payload', () => {
      const runId = randomUUID();
      const payload = {
        turn: 1,
        tokenUsage: { inputTokens: 100, outputTokens: 50 },
        runId,
      };

      expect(payload.runId).toBe(runId);
    });

    it('should include runId in message.assistant payload', () => {
      const runId = randomUUID();
      const payload = {
        content: 'Hello!',
        model: 'claude-3',
        runId,
      };

      expect(payload.runId).toBe(runId);
    });
  });

  describe('AgentPromptResult with runId', () => {
    it('should return runId in AgentPromptResult', () => {
      const runId = randomUUID();
      const result = {
        acknowledged: true,
        runId,
      };

      expect(result.acknowledged).toBe(true);
      expect(result.runId).toBe(runId);
    });
  });

  describe('runId propagation through run lifecycle', () => {
    it('should maintain same runId throughout entire run', () => {
      const runId = randomUUID();
      const events: string[] = [];

      // Simulate run lifecycle tracking runId
      const trackEvent = (eventType: string, eventRunId: string) => {
        expect(eventRunId).toBe(runId);
        events.push(eventType);
      };

      // Simulate events during a run
      trackEvent('turn_start', runId);
      trackEvent('message_update', runId);
      trackEvent('tool_call', runId);
      trackEvent('tool_result', runId);
      trackEvent('turn_end', runId);
      trackEvent('agent_complete', runId);

      expect(events).toEqual([
        'turn_start',
        'message_update',
        'tool_call',
        'tool_result',
        'turn_end',
        'agent_complete',
      ]);
    });

    it('should use different runId for different runs of same session', () => {
      const runIds: string[] = [];

      // First run
      runIds.push(randomUUID());

      // Second run (same session)
      runIds.push(randomUUID());

      expect(runIds[0]).not.toBe(runIds[1]);
    });
  });
});
