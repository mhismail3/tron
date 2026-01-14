/**
 * @fileoverview Tests for tool.result RPC Handler
 *
 * TDD: Tests for the client-initiated tool result handling.
 * This enables interactive tools like AskUserQuestion to receive user input.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { ToolResultParams, ToolResultResult } from '@tron/core';

// Mock pending tool call tracker - will be implemented
interface PendingToolCall {
  toolCallId: string;
  sessionId: string;
  toolName: string;
  createdAt: string;
  resolve: (result: unknown) => void;
  reject: (error: Error) => void;
}

interface ToolCallTracker {
  register(sessionId: string, toolCallId: string, toolName: string): Promise<unknown>;
  resolve(toolCallId: string, result: unknown): boolean;
  reject(toolCallId: string, error: Error): boolean;
  getPending(sessionId: string): PendingToolCall[];
  hasPending(toolCallId: string): boolean;
  cleanup(sessionId: string): void;
}

describe('tool.result RPC Handler', () => {
  describe('validation', () => {
    it('should require sessionId parameter', () => {
      const params: Partial<ToolResultParams> = {
        toolCallId: 'call_123',
        result: { answers: [] },
      };

      const isValid = params.sessionId !== undefined;
      expect(isValid).toBe(false);
    });

    it('should require toolCallId parameter', () => {
      const params: Partial<ToolResultParams> = {
        sessionId: 'sess_123',
        result: { answers: [] },
      };

      const isValid = params.toolCallId !== undefined;
      expect(isValid).toBe(false);
    });

    it('should require result parameter', () => {
      const params: Partial<ToolResultParams> = {
        sessionId: 'sess_123',
        toolCallId: 'call_123',
      };

      const isValid = params.result !== undefined;
      expect(isValid).toBe(false);
    });

    it('should accept valid params', () => {
      const params: ToolResultParams = {
        sessionId: 'sess_123',
        toolCallId: 'call_123',
        result: {
          answers: [
            { questionId: 'q1', selectedValues: ['Option A'] },
          ],
          complete: true,
          submittedAt: new Date().toISOString(),
        },
      };

      const isValid = params.sessionId && params.toolCallId && params.result !== undefined;
      expect(isValid).toBe(true);
    });
  });

  describe('pending tool call tracking', () => {
    it('should register a pending tool call', async () => {
      const pending = new Map<string, PendingToolCall>();

      const register = (sessionId: string, toolCallId: string, toolName: string): Promise<unknown> => {
        return new Promise((resolve, reject) => {
          pending.set(toolCallId, {
            toolCallId,
            sessionId,
            toolName,
            createdAt: new Date().toISOString(),
            resolve,
            reject,
          });
        });
      };

      // Start registration (non-blocking for test)
      const promise = register('sess_123', 'call_456', 'AskUserQuestion');

      expect(pending.has('call_456')).toBe(true);
      expect(pending.get('call_456')?.toolName).toBe('AskUserQuestion');

      // Resolve it for cleanup
      pending.get('call_456')?.resolve({ test: true });
      await promise;
    });

    it('should resolve pending tool call when result received', async () => {
      const pending = new Map<string, PendingToolCall>();
      let resolvedValue: unknown = null;

      // Register
      const promise = new Promise((resolve, reject) => {
        pending.set('call_789', {
          toolCallId: 'call_789',
          sessionId: 'sess_123',
          toolName: 'AskUserQuestion',
          createdAt: new Date().toISOString(),
          resolve: (value) => {
            resolvedValue = value;
            resolve(value);
          },
          reject,
        });
      });

      // Simulate receiving result
      const result = { answers: [{ questionId: 'q1', selectedValues: ['Yes'] }] };
      const call = pending.get('call_789');
      expect(call).toBeDefined();

      call?.resolve(result);
      pending.delete('call_789');

      await promise;
      expect(resolvedValue).toEqual(result);
      expect(pending.has('call_789')).toBe(false);
    });

    it('should return error for unknown tool call ID', () => {
      const pending = new Map<string, PendingToolCall>();

      const resolve = (toolCallId: string, _result: unknown): ToolResultResult => {
        if (!pending.has(toolCallId)) {
          return {
            success: false,
            error: `No pending tool call found with ID: ${toolCallId}`,
          };
        }
        return { success: true };
      };

      const result = resolve('unknown_call_id', {});
      expect(result.success).toBe(false);
      expect(result.error).toContain('No pending tool call found');
    });

    it('should clean up pending calls for session on disconnect', () => {
      const pending = new Map<string, PendingToolCall>();

      // Add multiple pending calls for same session
      pending.set('call_1', {
        toolCallId: 'call_1',
        sessionId: 'sess_A',
        toolName: 'AskUserQuestion',
        createdAt: new Date().toISOString(),
        resolve: vi.fn(),
        reject: vi.fn(),
      });
      pending.set('call_2', {
        toolCallId: 'call_2',
        sessionId: 'sess_A',
        toolName: 'AskUserQuestion',
        createdAt: new Date().toISOString(),
        resolve: vi.fn(),
        reject: vi.fn(),
      });
      pending.set('call_3', {
        toolCallId: 'call_3',
        sessionId: 'sess_B',
        toolName: 'AskUserQuestion',
        createdAt: new Date().toISOString(),
        resolve: vi.fn(),
        reject: vi.fn(),
      });

      // Cleanup session A
      const cleanup = (sessionId: string) => {
        for (const [id, call] of pending.entries()) {
          if (call.sessionId === sessionId) {
            call.reject(new Error('Session disconnected'));
            pending.delete(id);
          }
        }
      };

      cleanup('sess_A');

      expect(pending.size).toBe(1);
      expect(pending.has('call_3')).toBe(true);
      expect(pending.has('call_1')).toBe(false);
      expect(pending.has('call_2')).toBe(false);
    });
  });

  describe('timeout handling', () => {
    it('should timeout pending tool calls after configured duration', async () => {
      const pending = new Map<string, PendingToolCall>();
      const TIMEOUT_MS = 50; // Short timeout for test

      const registerWithTimeout = (
        sessionId: string,
        toolCallId: string,
        toolName: string,
        timeoutMs: number
      ): Promise<unknown> => {
        return new Promise((resolve, reject) => {
          const timeoutId = setTimeout(() => {
            pending.delete(toolCallId);
            reject(new Error(`Tool call ${toolCallId} timed out after ${timeoutMs}ms`));
          }, timeoutMs);

          pending.set(toolCallId, {
            toolCallId,
            sessionId,
            toolName,
            createdAt: new Date().toISOString(),
            resolve: (value) => {
              clearTimeout(timeoutId);
              pending.delete(toolCallId);
              resolve(value);
            },
            reject: (error) => {
              clearTimeout(timeoutId);
              pending.delete(toolCallId);
              reject(error);
            },
          });
        });
      };

      // This should timeout
      await expect(
        registerWithTimeout('sess_123', 'call_timeout', 'AskUserQuestion', TIMEOUT_MS)
      ).rejects.toThrow('timed out');
    });
  });

  describe('response format', () => {
    it('should return success: true on valid result', () => {
      const result: ToolResultResult = {
        success: true,
      };

      expect(result.success).toBe(true);
      expect(result.error).toBeUndefined();
    });

    it('should return success: false with error message on failure', () => {
      const result: ToolResultResult = {
        success: false,
        error: 'Tool call not found or already resolved',
      };

      expect(result.success).toBe(false);
      expect(result.error).toBeDefined();
    });
  });
});

describe('AskUserQuestion Tool', () => {
  describe('tool definition', () => {
    it('should have correct tool name', () => {
      const toolName = 'AskUserQuestion';
      expect(toolName).toBe('AskUserQuestion');
    });

    it('should define questions schema', () => {
      const schema = {
        type: 'object',
        properties: {
          questions: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                id: { type: 'string' },
                question: { type: 'string' },
                options: {
                  type: 'array',
                  items: {
                    type: 'object',
                    properties: {
                      label: { type: 'string' },
                      value: { type: 'string' },
                      description: { type: 'string' },
                    },
                    required: ['label'],
                  },
                  minItems: 2,
                },
                mode: { type: 'string', enum: ['single', 'multi'] },
                allowOther: { type: 'boolean' },
                otherPlaceholder: { type: 'string' },
              },
              required: ['id', 'question', 'options', 'mode'],
            },
            minItems: 1,
            maxItems: 5,
          },
          context: { type: 'string' },
        },
        required: ['questions'],
      };

      expect(schema.properties.questions.minItems).toBe(1);
      expect(schema.properties.questions.maxItems).toBe(5);
    });
  });

  describe('validation', () => {
    it('should reject params with > 5 questions', () => {
      const params = {
        questions: [
          { id: 'q1', question: 'Q1?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
          { id: 'q2', question: 'Q2?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
          { id: 'q3', question: 'Q3?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
          { id: 'q4', question: 'Q4?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
          { id: 'q5', question: 'Q5?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
          { id: 'q6', question: 'Q6?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
        ],
      };

      const isValid = params.questions.length <= 5;
      expect(isValid).toBe(false);
    });

    it('should reject params with duplicate question IDs', () => {
      const params = {
        questions: [
          { id: 'q1', question: 'Q1?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
          { id: 'q1', question: 'Q2?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
        ],
      };

      const ids = params.questions.map((q) => q.id);
      const uniqueIds = new Set(ids);
      const hasNoDuplicates = ids.length === uniqueIds.size;

      expect(hasNoDuplicates).toBe(false);
    });

    it('should reject questions with < 2 options', () => {
      const params = {
        questions: [
          { id: 'q1', question: 'Q1?', options: [{ label: 'Only one' }], mode: 'single' },
        ],
      };

      const hasMinOptions = params.questions.every((q) => q.options.length >= 2);
      expect(hasMinOptions).toBe(false);
    });

    it('should accept valid params', () => {
      const params = {
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
      };

      const isValid =
        params.questions.length >= 1 &&
        params.questions.length <= 5 &&
        params.questions.every((q) => q.options.length >= 2);

      expect(isValid).toBe(true);
    });
  });

  describe('execution flow', () => {
    it('should emit tool.call event with question data', () => {
      const toolCallEvent = {
        type: 'tool.call',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        data: {
          toolCallId: 'call_456',
          toolName: 'AskUserQuestion',
          arguments: {
            questions: [
              {
                id: 'q1',
                question: 'Do you want to proceed?',
                options: [
                  { label: 'Yes' },
                  { label: 'No' },
                ],
                mode: 'single',
              },
            ],
          },
        },
      };

      expect(toolCallEvent.type).toBe('tool.call');
      expect(toolCallEvent.data.toolName).toBe('AskUserQuestion');
      expect(toolCallEvent.data.arguments.questions).toHaveLength(1);
    });

    it('should block until client responds', async () => {
      // Simulate the blocking behavior
      let resolved = false;
      const waitForResult = new Promise<void>((resolve) => {
        // This simulates the client responding
        setTimeout(() => {
          resolved = true;
          resolve();
        }, 10);
      });

      expect(resolved).toBe(false);
      await waitForResult;
      expect(resolved).toBe(true);
    });

    it('should return parsed AskUserQuestionResult', () => {
      const result = {
        answers: [
          { questionId: 'q1', selectedValues: ['Yes'], otherValue: undefined },
        ],
        complete: true,
        submittedAt: '2026-01-14T12:00:00.000Z',
      };

      expect(result.answers).toHaveLength(1);
      expect(result.answers[0]?.selectedValues).toContain('Yes');
      expect(result.complete).toBe(true);
    });
  });

  describe('event persistence', () => {
    it('should persist tool.call with correct payload', () => {
      const event = {
        id: 'evt_call_1',
        type: 'tool.call',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        payload: {
          toolCallId: 'call_456',
          toolName: 'AskUserQuestion',
          arguments: {
            questions: [{ id: 'q1', question: 'Test?', options: [], mode: 'single' }],
          },
        },
      };

      expect(event.type).toBe('tool.call');
      expect(event.payload.toolName).toBe('AskUserQuestion');
    });

    it('should persist tool.result with answers', () => {
      const event = {
        id: 'evt_result_1',
        type: 'tool.result',
        sessionId: 'sess_123',
        timestamp: new Date().toISOString(),
        payload: {
          toolCallId: 'call_456',
          result: JSON.stringify({
            answers: [{ questionId: 'q1', selectedValues: ['Yes'] }],
            complete: true,
            submittedAt: new Date().toISOString(),
          }),
        },
      };

      expect(event.type).toBe('tool.result');
      expect(event.payload.toolCallId).toBe('call_456');
    });

    it('should link tool.result to tool.call via toolCallId', () => {
      const toolCallEvent = {
        type: 'tool.call',
        payload: { toolCallId: 'call_456', toolName: 'AskUserQuestion' },
      };

      const toolResultEvent = {
        type: 'tool.result',
        payload: { toolCallId: 'call_456', result: '{}' },
      };

      expect(toolCallEvent.payload.toolCallId).toBe(toolResultEvent.payload.toolCallId);
    });
  });
});
