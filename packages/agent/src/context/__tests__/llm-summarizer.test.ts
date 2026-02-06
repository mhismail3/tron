/**
 * @fileoverview LLM Summarizer Tests
 *
 * Tests for the LLMSummarizer class covering:
 * - Happy path with valid JSON response
 * - Fallback scenarios (subagent failure, invalid JSON, thrown errors)
 * - Markdown fence stripping
 * - Partial extractedData defaults
 * - Message serialization (all message types)
 * - Large message truncation
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { LLMSummarizer, serializeMessages, type LLMSummarizerDeps } from '../llm-summarizer.js';
import type { Message } from '../../core/types/index.js';

// =============================================================================
// Helpers
// =============================================================================

function createMockDeps(
  overrides?: Partial<LLMSummarizerDeps>
): LLMSummarizerDeps {
  return {
    spawnSubsession: vi.fn().mockResolvedValue({
      success: true,
      output: JSON.stringify({
        narrative: 'Test summary narrative.',
        extractedData: {
          currentGoal: 'Build a feature',
          completedSteps: ['Step 1'],
          pendingTasks: ['Step 2'],
          keyDecisions: [{ decision: 'Use TypeScript', reason: 'Type safety' }],
          filesModified: ['src/index.ts'],
          topicsDiscussed: ['architecture'],
          userPreferences: ['no emojis'],
          importantContext: ['deadline is Friday'],
          thinkingInsights: ['considered alternative approaches'],
        },
      }),
    }),
    ...overrides,
  };
}

function makeUserMessage(text: string): Message {
  return { role: 'user', content: text };
}

function makeAssistantMessage(text: string): Message {
  return {
    role: 'assistant',
    content: [{ type: 'text', text }],
  };
}

function makeThinkingMessage(thinking: string, text: string): Message {
  return {
    role: 'assistant',
    content: [
      { type: 'thinking', thinking },
      { type: 'text', text },
    ],
  };
}

function makeToolCallMessage(name: string, args: Record<string, unknown>): Message {
  return {
    role: 'assistant',
    content: [{
      type: 'tool_use' as const,
      id: 'tc_123',
      name,
      arguments: args,
    }],
  };
}

function makeToolResultMessage(content: string, isError = false): Message {
  return {
    role: 'toolResult',
    toolCallId: 'tc_123',
    content,
    isError,
  };
}

// =============================================================================
// Tests
// =============================================================================

describe('LLMSummarizer', () => {
  let deps: LLMSummarizerDeps;
  let summarizer: LLMSummarizer;

  beforeEach(() => {
    deps = createMockDeps();
    summarizer = new LLMSummarizer(deps);
  });

  describe('happy path', () => {
    it('returns structured SummaryResult from valid JSON response', async () => {
      const messages: Message[] = [
        makeUserMessage('Build a feature'),
        makeAssistantMessage('I will build it.'),
      ];

      const result = await summarizer.summarize(messages);

      expect(result.narrative).toBe('Test summary narrative.');
      expect(result.extractedData.currentGoal).toBe('Build a feature');
      expect(result.extractedData.completedSteps).toEqual(['Step 1']);
      expect(result.extractedData.keyDecisions).toEqual([
        { decision: 'Use TypeScript', reason: 'Type safety' },
      ]);
      expect(result.extractedData.filesModified).toEqual(['src/index.ts']);
    });

    it('passes correct parameters to spawnSubsession', async () => {
      const messages: Message[] = [makeUserMessage('Hello')];
      await summarizer.summarize(messages);

      expect(deps.spawnSubsession).toHaveBeenCalledWith(
        expect.objectContaining({
          model: 'claude-haiku-4-5-20251001',
          toolDenials: { denyAll: true },
          maxTurns: 1,
          blocking: true,
          timeout: 30_000,
        })
      );
    });
  });

  describe('fallback to KeywordSummarizer', () => {
    it('falls back when subagent fails', async () => {
      deps = createMockDeps({
        spawnSubsession: vi.fn().mockResolvedValue({
          success: false,
          error: 'Subagent timed out',
        }),
      });
      summarizer = new LLMSummarizer(deps);

      const messages: Message[] = [
        makeUserMessage('Build a feature'),
        makeAssistantMessage('Working on it.'),
      ];

      const result = await summarizer.summarize(messages);

      // KeywordSummarizer produces generic summaries
      expect(result.narrative).toContain('2 messages summarized');
      expect(result.extractedData.currentGoal).toBe('Continue working on the task');
    });

    it('falls back when response is invalid JSON', async () => {
      deps = createMockDeps({
        spawnSubsession: vi.fn().mockResolvedValue({
          success: true,
          output: 'This is not JSON at all.',
        }),
      });
      summarizer = new LLMSummarizer(deps);

      const result = await summarizer.summarize([makeUserMessage('Hello')]);

      expect(result.narrative).toContain('1 messages summarized');
    });

    it('falls back when spawnSubsession throws', async () => {
      deps = createMockDeps({
        spawnSubsession: vi.fn().mockRejectedValue(new Error('Network error')),
      });
      summarizer = new LLMSummarizer(deps);

      const result = await summarizer.summarize([makeUserMessage('Hello')]);

      expect(result.narrative).toContain('1 messages summarized');
    });

    it('falls back when narrative field is missing', async () => {
      deps = createMockDeps({
        spawnSubsession: vi.fn().mockResolvedValue({
          success: true,
          output: JSON.stringify({ extractedData: { currentGoal: 'test' } }),
        }),
      });
      summarizer = new LLMSummarizer(deps);

      const result = await summarizer.summarize([makeUserMessage('Hello')]);

      expect(result.narrative).toContain('1 messages summarized');
    });

    it('falls back when narrative is empty string', async () => {
      deps = createMockDeps({
        spawnSubsession: vi.fn().mockResolvedValue({
          success: true,
          output: JSON.stringify({ narrative: '', extractedData: {} }),
        }),
      });
      summarizer = new LLMSummarizer(deps);

      const result = await summarizer.summarize([makeUserMessage('Hello')]);

      expect(result.narrative).toContain('1 messages summarized');
    });

    it('falls back when output is undefined', async () => {
      deps = createMockDeps({
        spawnSubsession: vi.fn().mockResolvedValue({
          success: true,
          output: undefined,
        }),
      });
      summarizer = new LLMSummarizer(deps);

      const result = await summarizer.summarize([makeUserMessage('Hello')]);

      expect(result.narrative).toContain('1 messages summarized');
    });
  });

  describe('markdown fence stripping', () => {
    it('strips ```json fences', async () => {
      deps = createMockDeps({
        spawnSubsession: vi.fn().mockResolvedValue({
          success: true,
          output: '```json\n{"narrative": "Fenced summary.", "extractedData": {}}\n```',
        }),
      });
      summarizer = new LLMSummarizer(deps);

      const result = await summarizer.summarize([makeUserMessage('Hello')]);

      expect(result.narrative).toBe('Fenced summary.');
    });

    it('strips bare ``` fences', async () => {
      deps = createMockDeps({
        spawnSubsession: vi.fn().mockResolvedValue({
          success: true,
          output: '```\n{"narrative": "Bare fence.", "extractedData": {}}\n```',
        }),
      });
      summarizer = new LLMSummarizer(deps);

      const result = await summarizer.summarize([makeUserMessage('Hello')]);

      expect(result.narrative).toBe('Bare fence.');
    });
  });

  describe('partial extractedData', () => {
    it('defaults missing fields to empty values', async () => {
      deps = createMockDeps({
        spawnSubsession: vi.fn().mockResolvedValue({
          success: true,
          output: JSON.stringify({
            narrative: 'Partial data.',
            extractedData: {
              currentGoal: 'Test goal',
              // All other fields missing
            },
          }),
        }),
      });
      summarizer = new LLMSummarizer(deps);

      const result = await summarizer.summarize([makeUserMessage('Hello')]);

      expect(result.narrative).toBe('Partial data.');
      expect(result.extractedData.currentGoal).toBe('Test goal');
      expect(result.extractedData.completedSteps).toEqual([]);
      expect(result.extractedData.pendingTasks).toEqual([]);
      expect(result.extractedData.keyDecisions).toEqual([]);
      expect(result.extractedData.filesModified).toEqual([]);
      expect(result.extractedData.topicsDiscussed).toEqual([]);
      expect(result.extractedData.userPreferences).toEqual([]);
      expect(result.extractedData.importantContext).toEqual([]);
      expect(result.extractedData.thinkingInsights).toEqual([]);
    });

    it('defaults when extractedData is entirely missing', async () => {
      deps = createMockDeps({
        spawnSubsession: vi.fn().mockResolvedValue({
          success: true,
          output: JSON.stringify({ narrative: 'No data.' }),
        }),
      });
      summarizer = new LLMSummarizer(deps);

      const result = await summarizer.summarize([makeUserMessage('Hello')]);

      expect(result.narrative).toBe('No data.');
      expect(result.extractedData.currentGoal).toBe('');
      expect(result.extractedData.completedSteps).toEqual([]);
    });
  });
});

// =============================================================================
// Message Serialization Tests
// =============================================================================

describe('serializeMessages', () => {
  it('serializes user messages with [USER] label', () => {
    const messages: Message[] = [makeUserMessage('Hello world')];
    const result = serializeMessages(messages);
    expect(result).toBe('[USER] Hello world');
  });

  it('serializes assistant text with [ASSISTANT] label', () => {
    const messages: Message[] = [makeAssistantMessage('I can help with that.')];
    const result = serializeMessages(messages);
    expect(result).toBe('[ASSISTANT] I can help with that.');
  });

  it('truncates long assistant text', () => {
    const longText = 'a'.repeat(500);
    const messages: Message[] = [makeAssistantMessage(longText)];
    const result = serializeMessages(messages);
    expect(result).toBe(`[ASSISTANT] ${'a'.repeat(300)}`);
  });

  it('serializes thinking blocks with [THINKING] label', () => {
    const messages: Message[] = [
      makeThinkingMessage('Let me analyze this problem.', 'Here is my answer.'),
    ];
    const result = serializeMessages(messages);
    expect(result).toContain('[THINKING] Let me analyze this problem.');
    expect(result).toContain('[ASSISTANT] Here is my answer.');
  });

  it('truncates long thinking text', () => {
    const longThinking = 'b'.repeat(1000);
    const messages: Message[] = [makeThinkingMessage(longThinking, 'Answer')];
    const result = serializeMessages(messages);
    expect(result).toContain(`[THINKING] ${'b'.repeat(500)}`);
  });

  it('serializes tool calls with [TOOL_CALL] label and key args', () => {
    const messages: Message[] = [
      makeToolCallMessage('Read', { file_path: '/src/main.ts', encoding: 'utf-8' }),
    ];
    const result = serializeMessages(messages);
    expect(result).toBe('[TOOL_CALL] Read(file_path: /src/main.ts)');
  });

  it('serializes tool results with [TOOL_RESULT] label', () => {
    const messages: Message[] = [makeToolResultMessage('File contents here...')];
    const result = serializeMessages(messages);
    expect(result).toBe('[TOOL_RESULT] File contents here...');
  });

  it('truncates long tool results', () => {
    const longResult = 'c'.repeat(200);
    const messages: Message[] = [makeToolResultMessage(longResult)];
    const result = serializeMessages(messages);
    expect(result).toBe(`[TOOL_RESULT] ${'c'.repeat(100)}`);
  });

  it('serializes tool errors with [TOOL_ERROR] label', () => {
    const messages: Message[] = [makeToolResultMessage('File not found', true)];
    const result = serializeMessages(messages);
    expect(result).toBe('[TOOL_ERROR] File not found');
  });

  it('handles mixed message types', () => {
    const messages: Message[] = [
      makeUserMessage('Read the file'),
      makeToolCallMessage('Read', { file_path: '/test.ts' }),
      makeToolResultMessage('export const x = 1;'),
      makeAssistantMessage('The file exports x.'),
    ];
    const result = serializeMessages(messages);
    const lines = result.split('\n');
    expect(lines[0]).toBe('[USER] Read the file');
    expect(lines[1]).toBe('[TOOL_CALL] Read(file_path: /test.ts)');
    expect(lines[2]).toBe('[TOOL_RESULT] export const x = 1;');
    expect(lines[3]).toBe('[ASSISTANT] The file exports x.');
  });

  it('handles user message with content blocks', () => {
    const messages: Message[] = [{
      role: 'user',
      content: [
        { type: 'text', text: 'First part' },
        { type: 'text', text: 'Second part' },
      ],
    }];
    const result = serializeMessages(messages);
    expect(result).toBe('[USER] First part\nSecond part');
  });

  it('truncates large transcripts with middle omission', () => {
    // Create messages that exceed 150K chars
    const bigMessage = 'x'.repeat(80_000);
    const messages: Message[] = [
      makeUserMessage(bigMessage),
      makeUserMessage(bigMessage),
    ];
    const result = serializeMessages(messages);

    expect(result.length).toBeLessThanOrEqual(150_000 + 200); // allow for marker text
    expect(result).toContain('[... ');
    expect(result).toContain(' characters omitted ...]');
  });
});
