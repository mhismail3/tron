/**
 * @fileoverview Message Reconstructor Tests
 *
 * Tests for reconstructFromEvents function that builds messages from event ancestry.
 *
 * Key behaviors:
 * 1. Tool results are output as proper ToolResultMessage objects (role: 'toolResult')
 * 2. Message alternation is maintained for API compliance
 * 3. Compaction and deletion are handled correctly
 * 4. Token usage is accumulated properly
 */
import { describe, it, expect } from 'vitest';

import { reconstructFromEvents, type ReconstructionResult } from '../message-reconstructor.js';
import type { SessionEvent, Message } from '../types.js';

/**
 * Helper to extract messages array from reconstruction result (for easier test assertions)
 */
function getMessages(result: ReconstructionResult): Message[] {
  return result.messagesWithEventIds.map(m => m.message);
}

/**
 * Helper to create a minimal session event
 */
function createEvent(
  overrides: Partial<SessionEvent> & { type: string; payload: unknown }
): SessionEvent {
  const { type, payload, ...rest } = overrides;
  return {
    id: `evt_${Math.random().toString(36).slice(2)}` as any,
    sessionId: 'sess_test' as any,
    type,
    payload,
    timestamp: new Date().toISOString(),
    parentId: null,
    sequence: 0,
    ...rest,
  } as SessionEvent;
}

describe('reconstructFromEvents', () => {
  describe('Tool Result Output Format', () => {
    it('should output tool results as ToolResultMessage objects', () => {
      const events: SessionEvent[] = [
        createEvent({ type: 'session.start', payload: { workingDirectory: '/test', model: 'claude-3-5-sonnet' } }),
        createEvent({
          type: 'message.user',
          payload: { content: 'Use a tool', turn: 1 },
        }),
        createEvent({
          type: 'message.assistant',
          payload: {
            content: [
              { type: 'text', text: 'I will use a tool.' },
              { type: 'tool_use', id: 'call_123', name: 'TestTool', input: { arg: 'value' } },
            ],
            turn: 1,
            tokenUsage: { inputTokens: 50, outputTokens: 25 },
            stopReason: 'tool_use',
            model: 'claude-3-5-sonnet',
          },
        }),
        createEvent({
          type: 'tool.result',
          payload: { toolCallId: 'call_123', content: 'Tool output', isError: false, duration: 100 },
        }),
        // Assistant continues after processing tool result (normal agentic flow)
        createEvent({
          type: 'message.assistant',
          payload: {
            content: [{ type: 'text', text: 'The tool returned: Tool output' }],
            turn: 2,
            tokenUsage: { inputTokens: 75, outputTokens: 40 },
            stopReason: 'end_turn',
            model: 'claude-3-5-sonnet',
          },
        }),
      ];

      const result = reconstructFromEvents(events);

      // Should have: user, assistant, toolResult, assistant
      expect(getMessages(result)).toHaveLength(4);
      expect(getMessages(result)[0].role).toBe('user');
      expect(getMessages(result)[1].role).toBe('assistant');
      expect(getMessages(result)[2].role).toBe('toolResult');
      expect(getMessages(result)[3].role).toBe('assistant');

      // Verify toolResult message format
      const toolResultMsg = getMessages(result)[2];
      expect(toolResultMsg.role).toBe('toolResult');
      expect((toolResultMsg as any).toolCallId).toBe('call_123');
      expect((toolResultMsg as any).content).toBe('Tool output');
      expect((toolResultMsg as any).isError).toBe(false);
    });

    it('should output multiple tool results as separate ToolResultMessage objects', () => {
      const events: SessionEvent[] = [
        createEvent({ type: 'session.start', payload: { workingDirectory: '/test', model: 'claude-3-5-sonnet' } }),
        createEvent({
          type: 'message.user',
          payload: { content: 'Use multiple tools', turn: 1 },
        }),
        createEvent({
          type: 'message.assistant',
          payload: {
            content: [
              { type: 'tool_use', id: 'call_1', name: 'Tool1', input: {} },
              { type: 'tool_use', id: 'call_2', name: 'Tool2', input: {} },
            ],
            turn: 1,
            tokenUsage: { inputTokens: 60, outputTokens: 30 },
            stopReason: 'tool_use',
            model: 'claude-3-5-sonnet',
          },
        }),
        createEvent({
          type: 'tool.result',
          payload: { toolCallId: 'call_1', content: 'Result 1', isError: false, duration: 150 },
        }),
        createEvent({
          type: 'tool.result',
          payload: { toolCallId: 'call_2', content: 'Result 2', isError: true, duration: 200 },
        }),
        createEvent({
          type: 'message.assistant',
          payload: {
            content: [{ type: 'text', text: 'Done' }],
            turn: 2,
            tokenUsage: { inputTokens: 80, outputTokens: 35 },
            stopReason: 'end_turn',
            model: 'claude-3-5-sonnet',
          },
        }),
      ];

      const result = reconstructFromEvents(events);

      // Should have: user, assistant, toolResult, toolResult, assistant
      expect(getMessages(result)).toHaveLength(5);
      expect(getMessages(result)[0].role).toBe('user');
      expect(getMessages(result)[1].role).toBe('assistant');
      expect(getMessages(result)[2].role).toBe('toolResult');
      expect(getMessages(result)[3].role).toBe('toolResult');
      expect(getMessages(result)[4].role).toBe('assistant');

      // Verify each tool result
      const tr1 = getMessages(result)[2] as any;
      expect(tr1.toolCallId).toBe('call_1');
      expect(tr1.content).toBe('Result 1');
      expect(tr1.isError).toBe(false);

      const tr2 = getMessages(result)[3] as any;
      expect(tr2.toolCallId).toBe('call_2');
      expect(tr2.content).toBe('Result 2');
      expect(tr2.isError).toBe(true);
    });

    it('should flush tool results before next assistant message in agentic loop', () => {
      const events: SessionEvent[] = [
        createEvent({ type: 'session.start', payload: { workingDirectory: '/test', model: 'claude-3-5-sonnet' } }),
        createEvent({
          type: 'message.user',
          payload: { content: 'Start agentic loop', turn: 1 },
        }),
        // First tool call
        createEvent({
          type: 'message.assistant',
          payload: {
            content: [{ type: 'tool_use', id: 'call_1', name: 'Tool1', input: {} }],
            turn: 1,
            tokenUsage: { inputTokens: 45, outputTokens: 20 },
            stopReason: 'tool_use',
            model: 'claude-3-5-sonnet',
          },
        }),
        createEvent({
          type: 'tool.result',
          payload: { toolCallId: 'call_1', content: 'Result 1', isError: false, duration: 120 },
        }),
        // Second tool call (continuation)
        createEvent({
          type: 'message.assistant',
          payload: {
            content: [{ type: 'tool_use', id: 'call_2', name: 'Tool2', input: {} }],
            turn: 2,
            tokenUsage: { inputTokens: 65, outputTokens: 28 },
            stopReason: 'tool_use',
            model: 'claude-3-5-sonnet',
          },
        }),
        createEvent({
          type: 'tool.result',
          payload: { toolCallId: 'call_2', content: 'Result 2', isError: false, duration: 130 },
        }),
        // Final response
        createEvent({
          type: 'message.assistant',
          payload: {
            content: [{ type: 'text', text: 'All done!' }],
            turn: 3,
            tokenUsage: { inputTokens: 85, outputTokens: 42 },
            stopReason: 'end_turn',
            model: 'claude-3-5-sonnet',
          },
        }),
      ];

      const result = reconstructFromEvents(events);

      // Should have: user, assistant, toolResult, assistant, toolResult, assistant
      expect(getMessages(result)).toHaveLength(6);
      expect(getMessages(result)[0].role).toBe('user');
      expect(getMessages(result)[1].role).toBe('assistant');
      expect(getMessages(result)[2].role).toBe('toolResult');
      expect(getMessages(result)[3].role).toBe('assistant');
      expect(getMessages(result)[4].role).toBe('toolResult');
      expect(getMessages(result)[5].role).toBe('assistant');
    });

    it('should handle tool results at end of conversation (for resume/fork)', () => {
      const events: SessionEvent[] = [
        createEvent({ type: 'session.start', payload: { workingDirectory: '/test', model: 'claude-3-5-sonnet' } }),
        createEvent({
          type: 'message.user',
          payload: { content: 'Run a tool', turn: 1 },
        }),
        createEvent({
          type: 'message.assistant',
          payload: {
            content: [{ type: 'tool_use', id: 'call_1', name: 'Tool', input: {} }],
            turn: 1,
            tokenUsage: { inputTokens: 40, outputTokens: 18 },
            stopReason: 'tool_use',
            model: 'claude-3-5-sonnet',
          },
        }),
        createEvent({
          type: 'tool.result',
          payload: { toolCallId: 'call_1', content: 'Tool finished', isError: false, duration: 110 },
        }),
        // No more events - this simulates resuming mid-agentic-loop
      ];

      const result = reconstructFromEvents(events);

      // Should have: user, assistant, toolResult
      expect(getMessages(result)).toHaveLength(3);
      expect(getMessages(result)[0].role).toBe('user');
      expect(getMessages(result)[1].role).toBe('assistant');
      expect(getMessages(result)[2].role).toBe('toolResult');

      const toolResult = getMessages(result)[2] as any;
      expect(toolResult.toolCallId).toBe('call_1');
      expect(toolResult.content).toBe('Tool finished');
    });
  });

  describe('Message Merging', () => {
    it('should merge consecutive user messages', () => {
      const events: SessionEvent[] = [
        createEvent({ type: 'session.start', payload: { workingDirectory: '/test', model: 'claude-3-5-sonnet' } }),
        createEvent({
          type: 'message.user',
          payload: { content: 'First message', turn: 1 },
        }),
        createEvent({
          type: 'message.user',
          payload: { content: 'Second message', turn: 2 },
        }),
      ];

      const result = reconstructFromEvents(events);

      expect(getMessages(result)).toHaveLength(1);
      expect(getMessages(result)[0].role).toBe('user');
      // Content should be merged
      const content = getMessages(result)[0].content as any[];
      expect(content).toHaveLength(2);
      expect(content[0].text).toBe('First message');
      expect(content[1].text).toBe('Second message');
    });

    it('should discard pending tool results when real user message arrives', () => {
      const events: SessionEvent[] = [
        createEvent({ type: 'session.start', payload: { workingDirectory: '/test', model: 'claude-3-5-sonnet' } }),
        createEvent({
          type: 'message.user',
          payload: { content: 'Use tool', turn: 1 },
        }),
        createEvent({
          type: 'message.assistant',
          payload: {
            content: [{ type: 'tool_use', id: 'call_1', name: 'Tool', input: {} }],
            turn: 1,
            tokenUsage: { inputTokens: 50, outputTokens: 25 },
            stopReason: 'tool_use',
            model: 'claude-3-5-sonnet',
          },
        }),
        createEvent({
          type: 'tool.result',
          payload: { toolCallId: 'call_1', content: 'Result', isError: false, duration: 140 },
        }),
        // User interrupts before assistant processes result
        createEvent({
          type: 'message.user',
          payload: { content: 'Actually, never mind', turn: 2 },
        }),
      ];

      const result = reconstructFromEvents(events);

      // Tool result should be discarded since user interrupted
      // Should have: user, assistant, user
      expect(getMessages(result)).toHaveLength(3);
      expect(getMessages(result)[0].role).toBe('user');
      expect(getMessages(result)[1].role).toBe('assistant');
      expect(getMessages(result)[2].role).toBe('user');
    });
  });

  describe('Compaction Handling', () => {
    it('should clear messages after compact.summary and inject synthetic pair', () => {
      const events: SessionEvent[] = [
        createEvent({ type: 'session.start', payload: { workingDirectory: '/test', model: 'claude-3-5-sonnet' } }),
        createEvent({
          type: 'message.user',
          payload: { content: 'Old message', turn: 1 },
        }),
        createEvent({
          type: 'message.assistant',
          payload: {
            content: [{ type: 'text', text: 'Old response' }],
            turn: 1,
            tokenUsage: { inputTokens: 30, outputTokens: 15 },
            stopReason: 'end_turn',
            model: 'claude-3-5-sonnet',
          },
        }),
        createEvent({
          type: 'compact.summary',
          payload: { summary: 'Previous conversation summary', boundaryEventId: 'evt_boundary' as any },
        }),
        createEvent({
          type: 'message.user',
          payload: { content: 'New message', turn: 2 },
        }),
      ];

      const result = reconstructFromEvents(events);

      // Should have: synthetic user (summary), synthetic assistant, real user
      expect(getMessages(result)).toHaveLength(3);
      expect(getMessages(result)[0].role).toBe('user');
      expect((getMessages(result)[0].content as string)).toContain('Context from earlier');
      expect((getMessages(result)[0].content as string)).toContain('Previous conversation summary');
      expect(getMessages(result)[1].role).toBe('assistant');
      expect(getMessages(result)[2].role).toBe('user');
      expect(getMessages(result)[2].content).toBe('New message');
    });
  });

  describe('Token Usage Accumulation', () => {
    it('should accumulate token usage from all messages', () => {
      const events: SessionEvent[] = [
        createEvent({ type: 'session.start', payload: { workingDirectory: '/test', model: 'claude-3-5-sonnet' } }),
        createEvent({
          type: 'message.user',
          payload: { content: 'Hello', turn: 1 },
        }),
        createEvent({
          type: 'message.assistant',
          payload: {
            content: [{ type: 'text', text: 'Hi' }],
            turn: 1,
            tokenUsage: { inputTokens: 100, outputTokens: 50, cacheReadTokens: 10 },
            stopReason: 'end_turn',
            model: 'claude-3-5-sonnet',
          },
        }),
        createEvent({
          type: 'message.user',
          payload: { content: 'More', turn: 2 },
        }),
        createEvent({
          type: 'message.assistant',
          payload: {
            content: [{ type: 'text', text: 'More response' }],
            turn: 2,
            tokenUsage: { inputTokens: 150, outputTokens: 75, cacheCreationTokens: 20 },
            stopReason: 'end_turn',
            model: 'claude-3-5-sonnet',
          },
        }),
      ];

      const result = reconstructFromEvents(events);

      expect(result.tokenUsage.inputTokens).toBe(250);
      expect(result.tokenUsage.outputTokens).toBe(125);
      expect(result.tokenUsage.cacheReadTokens).toBe(10);
      expect(result.tokenUsage.cacheCreationTokens).toBe(20);
    });
  });

  describe('Tool Argument Restoration', () => {
    it('should restore truncated tool arguments from tool.call events', () => {
      const events: SessionEvent[] = [
        createEvent({ type: 'session.start', payload: { workingDirectory: '/test', model: 'claude-3-5-sonnet' } }),
        createEvent({
          type: 'message.user',
          payload: { content: 'Run tool', turn: 1 },
        }),
        createEvent({
          type: 'message.assistant',
          payload: {
            content: [
              {
                type: 'tool_use',
                id: 'call_1',
                name: 'BigTool',
                input: { _truncated: true }, // Truncated in event
              },
            ],
            turn: 1,
            tokenUsage: { inputTokens: 55, outputTokens: 22 },
            stopReason: 'tool_use',
            model: 'claude-3-5-sonnet',
          },
        }),
        createEvent({
          type: 'tool.call',
          payload: {
            toolCallId: 'call_1',
            name: 'BigTool',
            arguments: { largeArg: 'This is the full argument that was truncated' },
            turn: 1,
          },
        }),
        createEvent({
          type: 'tool.result',
          payload: { toolCallId: 'call_1', content: 'Done', isError: false, duration: 160 },
        }),
      ];

      const result = reconstructFromEvents(events);

      // Assistant message should have restored arguments
      const assistantMsg = getMessages(result)[1] as any;
      const toolUse = assistantMsg.content[0];
      expect(toolUse.input).toEqual({ largeArg: 'This is the full argument that was truncated' });
    });
  });

  describe('Reasoning Level', () => {
    it('should extract reasoning level from config events', () => {
      const events: SessionEvent[] = [
        createEvent({ type: 'session.start', payload: { workingDirectory: '/test', model: 'claude-3-5-sonnet' } }),
        createEvent({
          type: 'config.reasoning_level',
          payload: { newLevel: 'high' },
        }),
        createEvent({
          type: 'message.user',
          payload: { content: 'Hello', turn: 1 },
        }),
      ];

      const result = reconstructFromEvents(events);

      expect(result.reasoningLevel).toBe('high');
    });

    it('should use most recent reasoning level', () => {
      const events: SessionEvent[] = [
        createEvent({ type: 'session.start', payload: { workingDirectory: '/test', model: 'claude-3-5-sonnet' } }),
        createEvent({
          type: 'config.reasoning_level',
          payload: { newLevel: 'low' },
        }),
        createEvent({
          type: 'config.reasoning_level',
          payload: { newLevel: 'medium' },
        }),
        createEvent({
          type: 'config.reasoning_level',
          payload: { newLevel: 'xhigh' },
        }),
      ];

      const result = reconstructFromEvents(events);

      expect(result.reasoningLevel).toBe('xhigh');
    });
  });
});
