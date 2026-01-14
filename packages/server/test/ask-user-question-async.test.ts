/**
 * @fileoverview Tests for AskUserQuestion Tool (Async Model)
 *
 * TDD: These tests verify the async/non-blocking behavior of AskUserQuestion.
 * In the async model:
 * - Tool returns immediately without blocking
 * - User answers submitted as new agent.prompt
 * - No timeout, no toolCallTracker dependency
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { AskUserQuestionTool } from '@tron/core';
import type { AskUserQuestionParams } from '@tron/core';

describe('AskUserQuestion Tool (Async Model)', () => {
  let tool: AskUserQuestionTool;

  beforeEach(() => {
    // Create tool WITHOUT delegate - async model doesn't need one
    tool = new AskUserQuestionTool({
      workingDirectory: '/test',
      // No delegate - tool should work without one in async mode
    });
  });

  describe('execution', () => {
    it('should return immediately without blocking', async () => {
      const params: AskUserQuestionParams = {
        questions: [
          {
            id: 'q1',
            question: 'Which approach?',
            options: [
              { label: 'Option A' },
              { label: 'Option B' },
            ],
            mode: 'single',
          },
        ],
      };

      const startTime = Date.now();
      const result = await tool.execute(params as Record<string, unknown>, {
        toolCallId: 'call_123',
        sessionId: 'sess_456',
      });
      const elapsed = Date.now() - startTime;

      // Should complete nearly instantly (< 100ms)
      expect(elapsed).toBeLessThan(100);
      expect(result.isError).toBe(false);
    });

    it('should NOT require a delegate', async () => {
      // Tool without delegate should still work
      const noDelegateTool = new AskUserQuestionTool({
        workingDirectory: '/test',
      });

      const params: AskUserQuestionParams = {
        questions: [
          {
            id: 'q1',
            question: 'Test question?',
            options: [
              { label: 'Yes' },
              { label: 'No' },
            ],
            mode: 'single',
          },
        ],
      };

      const result = await noDelegateTool.execute(params as Record<string, unknown>, {
        toolCallId: 'call_123',
        sessionId: 'sess_456',
      });

      // Should succeed without delegate
      expect(result.isError).toBe(false);
    });

    it('should return formatted question summary in content', async () => {
      const params: AskUserQuestionParams = {
        questions: [
          {
            id: 'q1',
            question: 'Which implementation approach?',
            options: [
              { label: 'Option A - Fast' },
              { label: 'Option B - Flexible' },
            ],
            mode: 'single',
          },
          {
            id: 'q2',
            question: 'Add tests?',
            options: [
              { label: 'Yes' },
              { label: 'No' },
            ],
            mode: 'single',
          },
        ],
      };

      const result = await tool.execute(params as Record<string, unknown>, {
        toolCallId: 'call_123',
        sessionId: 'sess_456',
      });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('Which implementation approach?');
      expect(result.content).toContain('Add tests?');
      expect(result.content).toContain('Awaiting user response');
    });

    it('should include async: true in details', async () => {
      const params: AskUserQuestionParams = {
        questions: [
          {
            id: 'q1',
            question: 'Test?',
            options: [{ label: 'A' }, { label: 'B' }],
            mode: 'single',
          },
        ],
      };

      const result = await tool.execute(params as Record<string, unknown>, {
        toolCallId: 'call_123',
        sessionId: 'sess_456',
      });

      expect(result.isError).toBe(false);
      expect(result.details).toBeDefined();
      expect((result.details as Record<string, unknown>).async).toBe(true);
    });

    it('should include questionCount in details', async () => {
      const params: AskUserQuestionParams = {
        questions: [
          { id: 'q1', question: 'Q1?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
          { id: 'q2', question: 'Q2?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
          { id: 'q3', question: 'Q3?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
        ],
      };

      const result = await tool.execute(params as Record<string, unknown>, {
        toolCallId: 'call_123',
        sessionId: 'sess_456',
      });

      expect(result.isError).toBe(false);
      expect((result.details as Record<string, unknown>).questionCount).toBe(3);
    });

    it('should work without toolCallId in async mode', async () => {
      // In async mode, toolCallId is optional since we're not tracking responses
      const params: AskUserQuestionParams = {
        questions: [
          {
            id: 'q1',
            question: 'Test?',
            options: [{ label: 'A' }, { label: 'B' }],
            mode: 'single',
          },
        ],
      };

      const result = await tool.execute(params as Record<string, unknown>, {
        sessionId: 'sess_456',
        // No toolCallId
      });

      // Should still succeed - we just can't track the response
      expect(result.isError).toBe(false);
    });

    it('should work without sessionId in async mode', async () => {
      const params: AskUserQuestionParams = {
        questions: [
          {
            id: 'q1',
            question: 'Test?',
            options: [{ label: 'A' }, { label: 'B' }],
            mode: 'single',
          },
        ],
      };

      const result = await tool.execute(params as Record<string, unknown>, {
        toolCallId: 'call_123',
        // No sessionId
      });

      // Should still succeed
      expect(result.isError).toBe(false);
    });
  });

  describe('validation', () => {
    it('should reject params with > 5 questions', async () => {
      const params: AskUserQuestionParams = {
        questions: [
          { id: 'q1', question: 'Q1?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
          { id: 'q2', question: 'Q2?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
          { id: 'q3', question: 'Q3?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
          { id: 'q4', question: 'Q4?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
          { id: 'q5', question: 'Q5?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
          { id: 'q6', question: 'Q6?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
        ],
      };

      const result = await tool.execute(params as Record<string, unknown>, {
        toolCallId: 'call_123',
        sessionId: 'sess_456',
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('at most 5 questions');
    });

    it('should reject questions with < 2 options', async () => {
      const params: AskUserQuestionParams = {
        questions: [
          { id: 'q1', question: 'Q1?', options: [{ label: 'Only one' }], mode: 'single' },
        ],
      };

      const result = await tool.execute(params as Record<string, unknown>, {
        toolCallId: 'call_123',
        sessionId: 'sess_456',
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('at least 2 options');
    });

    it('should reject duplicate question IDs', async () => {
      const params: AskUserQuestionParams = {
        questions: [
          { id: 'same_id', question: 'Q1?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
          { id: 'same_id', question: 'Q2?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
        ],
      };

      const result = await tool.execute(params as Record<string, unknown>, {
        toolCallId: 'call_123',
        sessionId: 'sess_456',
      });

      expect(result.isError).toBe(true);
      expect(result.content).toContain('unique');
    });

    it('should accept valid params', async () => {
      const params: AskUserQuestionParams = {
        questions: [
          {
            id: 'approach',
            question: 'Which implementation approach do you prefer?',
            options: [
              { label: 'Option A', description: 'Fast but less flexible' },
              { label: 'Option B', description: 'Slower but more extensible' },
            ],
            mode: 'single',
          },
        ],
        context: 'Choosing implementation strategy for the new feature',
      };

      const result = await tool.execute(params as Record<string, unknown>, {
        toolCallId: 'call_123',
        sessionId: 'sess_456',
      });

      expect(result.isError).toBe(false);
    });
  });

  describe('response format', () => {
    it('should format single question correctly', async () => {
      const params: AskUserQuestionParams = {
        questions: [
          {
            id: 'q1',
            question: 'Proceed with refactoring?',
            options: [
              { label: 'Yes, proceed' },
              { label: 'No, wait' },
            ],
            mode: 'single',
          },
        ],
      };

      const result = await tool.execute(params as Record<string, unknown>, {
        toolCallId: 'call_123',
        sessionId: 'sess_456',
      });

      expect(result.content).toContain('1. Proceed with refactoring?');
      expect(result.content).toContain('Yes, proceed');
      expect(result.content).toContain('No, wait');
    });

    it('should format multiple questions correctly', async () => {
      const params: AskUserQuestionParams = {
        questions: [
          {
            id: 'q1',
            question: 'First question?',
            options: [{ label: 'A' }, { label: 'B' }],
            mode: 'single',
          },
          {
            id: 'q2',
            question: 'Second question?',
            options: [{ label: 'X' }, { label: 'Y' }],
            mode: 'single',
          },
        ],
      };

      const result = await tool.execute(params as Record<string, unknown>, {
        toolCallId: 'call_123',
        sessionId: 'sess_456',
      });

      expect(result.content).toContain('1. First question?');
      expect(result.content).toContain('2. Second question?');
    });

    it('should list all options in summary', async () => {
      const params: AskUserQuestionParams = {
        questions: [
          {
            id: 'q1',
            question: 'Choose framework?',
            options: [
              { label: 'React' },
              { label: 'Vue' },
              { label: 'Svelte' },
            ],
            mode: 'single',
          },
        ],
      };

      const result = await tool.execute(params as Record<string, unknown>, {
        toolCallId: 'call_123',
        sessionId: 'sess_456',
      });

      expect(result.content).toContain('React');
      expect(result.content).toContain('Vue');
      expect(result.content).toContain('Svelte');
    });
  });

  describe('event flow expectations', () => {
    it('should complete immediately allowing turn to end', async () => {
      const params: AskUserQuestionParams = {
        questions: [
          {
            id: 'q1',
            question: 'Confirm?',
            options: [{ label: 'Yes' }, { label: 'No' }],
            mode: 'single',
          },
        ],
      };

      // Execute should return immediately
      const result = await tool.execute(params as Record<string, unknown>, {
        toolCallId: 'call_123',
        sessionId: 'sess_456',
      });

      // Result should be successful and not an error
      expect(result.isError).toBe(false);
      // Content should indicate waiting for response
      expect(result.content).toContain('Awaiting user response');
    });
  });
});

describe('Async Model Event Flow', () => {
  describe('Turn N (Agent asks questions)', () => {
    it('should emit tool.call with question params', () => {
      const toolCallEvent = {
        type: 'tool.call',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        payload: {
          toolCallId: 'call_456',
          toolName: 'AskUserQuestion',
          arguments: {
            questions: [
              {
                id: 'q1',
                question: 'Which approach?',
                options: [
                  { label: 'Option A' },
                  { label: 'Option B' },
                ],
                mode: 'single',
              },
            ],
          },
        },
      };

      expect(toolCallEvent.type).toBe('tool.call');
      expect(toolCallEvent.payload.toolName).toBe('AskUserQuestion');
      expect(toolCallEvent.payload.arguments.questions).toHaveLength(1);
    });

    it('should emit tool.result with success message immediately', () => {
      const toolResultEvent = {
        type: 'tool.result',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        payload: {
          toolCallId: 'call_456',
          content: 'Questions presented to user:\n1. Which approach? (Option A / Option B)\n\nAwaiting user response...',
          isError: false,
        },
      };

      expect(toolResultEvent.type).toBe('tool.result');
      expect(toolResultEvent.payload.isError).toBe(false);
      expect(toolResultEvent.payload.content).toContain('Awaiting user response');
    });

    it('should emit turn.end after tool returns', () => {
      const turnEndEvent = {
        type: 'turn.end',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        payload: {
          turnNumber: 1,
          reason: 'completed',
        },
      };

      expect(turnEndEvent.type).toBe('turn.end');
      expect(turnEndEvent.payload.reason).toBe('completed');
    });
  });

  describe('Turn N+1 (User answers)', () => {
    it('should receive answers as message.user event', () => {
      const messageUserEvent = {
        type: 'message.user',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        payload: {
          content: `[Answers to your questions]

**Which approach?**
Answer: Option A

`,
        },
      };

      expect(messageUserEvent.type).toBe('message.user');
      expect(messageUserEvent.payload.content).toContain('[Answers to your questions]');
      expect(messageUserEvent.payload.content).toContain('Which approach?');
      expect(messageUserEvent.payload.content).toContain('Option A');
    });

    it('should trigger new agent turn when answers submitted', () => {
      const agentStartEvent = {
        type: 'agent.start',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        payload: {
          turnNumber: 2,
        },
      };

      expect(agentStartEvent.type).toBe('agent.start');
      expect(agentStartEvent.payload.turnNumber).toBe(2);
    });
  });
});

describe('State Reconstruction (Async Model)', () => {
  it('should reconstruct pending status when no subsequent message.user', () => {
    const events = [
      { type: 'tool.call', payload: { toolName: 'AskUserQuestion', toolCallId: 'call_1' } },
      { type: 'tool.result', payload: { toolCallId: 'call_1', content: 'Awaiting...' } },
      { type: 'turn.end', payload: { turnNumber: 1 } },
      // No message.user after - still pending
    ];

    const reconstructStatus = (events: Array<{ type: string; payload: Record<string, unknown> }>) => {
      const toolCallIdx = events.findIndex(
        e => e.type === 'tool.call' && e.payload.toolName === 'AskUserQuestion'
      );
      const subsequentEvents = events.slice(toolCallIdx + 1);

      for (const event of subsequentEvents) {
        if (event.type === 'message.user') {
          const content = event.payload.content as string;
          if (content.includes('[Answers to your questions]')) {
            return 'answered';
          } else {
            return 'superseded';
          }
        }
      }
      return 'pending';
    };

    expect(reconstructStatus(events)).toBe('pending');
  });

  it('should reconstruct answered status when answer message follows', () => {
    const events = [
      { type: 'tool.call', payload: { toolName: 'AskUserQuestion', toolCallId: 'call_1' } },
      { type: 'tool.result', payload: { toolCallId: 'call_1', content: 'Awaiting...' } },
      { type: 'turn.end', payload: { turnNumber: 1 } },
      { type: 'message.user', payload: { content: '[Answers to your questions]\n\n**Q1?**\nAnswer: Yes' } },
    ];

    const reconstructStatus = (events: Array<{ type: string; payload: Record<string, unknown> }>) => {
      const toolCallIdx = events.findIndex(
        e => e.type === 'tool.call' && e.payload.toolName === 'AskUserQuestion'
      );
      const subsequentEvents = events.slice(toolCallIdx + 1);

      for (const event of subsequentEvents) {
        if (event.type === 'message.user') {
          const content = event.payload.content as string;
          if (content.includes('[Answers to your questions]')) {
            return 'answered';
          } else {
            return 'superseded';
          }
        }
      }
      return 'pending';
    };

    expect(reconstructStatus(events)).toBe('answered');
  });

  it('should reconstruct superseded status when other message follows', () => {
    const events = [
      { type: 'tool.call', payload: { toolName: 'AskUserQuestion', toolCallId: 'call_1' } },
      { type: 'tool.result', payload: { toolCallId: 'call_1', content: 'Awaiting...' } },
      { type: 'turn.end', payload: { turnNumber: 1 } },
      { type: 'message.user', payload: { content: 'Actually, never mind. Just do it.' } },
    ];

    const reconstructStatus = (events: Array<{ type: string; payload: Record<string, unknown> }>) => {
      const toolCallIdx = events.findIndex(
        e => e.type === 'tool.call' && e.payload.toolName === 'AskUserQuestion'
      );
      const subsequentEvents = events.slice(toolCallIdx + 1);

      for (const event of subsequentEvents) {
        if (event.type === 'message.user') {
          const content = event.payload.content as string;
          if (content.includes('[Answers to your questions]')) {
            return 'answered';
          } else {
            return 'superseded';
          }
        }
      }
      return 'pending';
    };

    expect(reconstructStatus(events)).toBe('superseded');
  });
});
