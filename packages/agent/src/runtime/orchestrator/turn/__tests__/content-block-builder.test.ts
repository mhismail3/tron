/**
 * @fileoverview ContentBlockBuilder Unit Tests (TDD)
 *
 * Tests for pure functions that build API-compatible content blocks.
 * Extracted from TurnContentTracker for better testability.
 */
import { describe, it, expect } from 'vitest';
import {
  buildPreToolContentBlocks,
  buildInterruptedContentBlocks,
  buildThinkingBlock,
  buildToolUseBlock,
  buildToolResultBlock,
  type ToolCallData,
  type ContentSequenceItem,
} from '../content-block-builder.js';

describe('ContentBlockBuilder', () => {
  // ===========================================================================
  // buildThinkingBlock
  // ===========================================================================

  describe('buildThinkingBlock', () => {
    it('builds thinking block without signature', () => {
      const result = buildThinkingBlock('This is thinking content');

      expect(result).toEqual({
        type: 'thinking',
        thinking: 'This is thinking content',
      });
    });

    it('builds thinking block with signature', () => {
      const result = buildThinkingBlock('This is thinking content', 'sig123');

      expect(result).toEqual({
        type: 'thinking',
        thinking: 'This is thinking content',
        signature: 'sig123',
      });
    });

    it('handles empty thinking', () => {
      const result = buildThinkingBlock('');

      expect(result).toEqual({
        type: 'thinking',
        thinking: '',
      });
    });
  });

  // ===========================================================================
  // buildToolUseBlock
  // ===========================================================================

  describe('buildToolUseBlock', () => {
    const baseToolCall: ToolCallData = {
      toolCallId: 'tool_123',
      toolName: 'Read',
      arguments: { file_path: '/path/to/file' },
      status: 'completed',
    };

    it('builds basic tool_use block', () => {
      const result = buildToolUseBlock(baseToolCall);

      expect(result).toEqual({
        type: 'tool_use',
        id: 'tool_123',
        name: 'Read',
        input: { file_path: '/path/to/file' },
      });
    });

    it('includes _meta for interrupted tool', () => {
      const runningToolCall: ToolCallData = {
        ...baseToolCall,
        status: 'running',
        startedAt: '2024-01-01T00:00:00.000Z',
      };

      const result = buildToolUseBlock(runningToolCall, true);

      expect(result._meta).toEqual({
        status: 'running',
        interrupted: true,
        durationMs: undefined,
      });
    });

    it('includes _meta for pending tool', () => {
      const pendingToolCall: ToolCallData = {
        ...baseToolCall,
        status: 'pending',
      };

      const result = buildToolUseBlock(pendingToolCall, true);

      expect(result._meta).toEqual({
        status: 'pending',
        interrupted: true,
        durationMs: undefined,
      });
    });

    it('calculates durationMs for completed tool', () => {
      const completedToolCall: ToolCallData = {
        ...baseToolCall,
        status: 'completed',
        startedAt: '2024-01-01T00:00:00.000Z',
        completedAt: '2024-01-01T00:00:05.000Z', // 5 seconds later
      };

      const result = buildToolUseBlock(completedToolCall, true);

      expect(result._meta?.durationMs).toBe(5000);
    });

    it('marks completed tool as not interrupted', () => {
      const completedToolCall: ToolCallData = {
        ...baseToolCall,
        status: 'completed',
      };

      const result = buildToolUseBlock(completedToolCall, true);

      expect(result._meta?.interrupted).toBe(false);
    });

    it('does not include _meta when includeMeta is false', () => {
      const result = buildToolUseBlock(baseToolCall, false);

      expect(result._meta).toBeUndefined();
    });
  });

  // ===========================================================================
  // buildToolResultBlock
  // ===========================================================================

  describe('buildToolResultBlock', () => {
    const baseToolCall: ToolCallData = {
      toolCallId: 'tool_123',
      toolName: 'Read',
      arguments: { file_path: '/path/to/file' },
      status: 'completed',
      result: 'File content here',
      isError: false,
      startedAt: '2024-01-01T00:00:00.000Z',
      completedAt: '2024-01-01T00:00:01.000Z',
    };

    it('builds tool_result for completed tool', () => {
      const result = buildToolResultBlock(baseToolCall);

      expect(result).toEqual({
        type: 'tool_result',
        tool_use_id: 'tool_123',
        content: 'File content here',
        is_error: false,
        _meta: {
          durationMs: 1000,
          toolName: 'Read',
        },
      });
    });

    it('builds tool_result for error tool', () => {
      const errorToolCall: ToolCallData = {
        ...baseToolCall,
        status: 'error',
        result: 'Permission denied',
        isError: true,
      };

      const result = buildToolResultBlock(errorToolCall);

      expect(result.is_error).toBe(true);
      expect(result.content).toBe('Permission denied');
    });

    it('handles missing result', () => {
      const noResultToolCall: ToolCallData = {
        ...baseToolCall,
        result: undefined,
      };

      const result = buildToolResultBlock(noResultToolCall);

      expect(result.content).toBe('(no output)');
    });

    it('handles missing result on error tool', () => {
      const errorNoResultToolCall: ToolCallData = {
        ...baseToolCall,
        result: undefined,
        isError: true,
      };

      const result = buildToolResultBlock(errorNoResultToolCall);

      expect(result.content).toBe('Error');
    });

    it('builds interrupted tool_result', () => {
      const runningToolCall: ToolCallData = {
        ...baseToolCall,
        status: 'running',
        result: undefined,
        completedAt: undefined,
      };

      const result = buildToolResultBlock(runningToolCall, true);

      expect(result.content).toBe('Command interrupted (no output captured)');
      expect(result.is_error).toBe(false);
      expect(result._meta?.interrupted).toBe(true);
    });

    it('builds interrupted tool_result for pending tool', () => {
      const pendingToolCall: ToolCallData = {
        ...baseToolCall,
        status: 'pending',
        result: undefined,
        startedAt: undefined,
        completedAt: undefined,
      };

      const result = buildToolResultBlock(pendingToolCall, true);

      expect(result.content).toBe('Command interrupted (no output captured)');
      expect(result._meta?.interrupted).toBe(true);
    });
  });

  // ===========================================================================
  // buildPreToolContentBlocks
  // ===========================================================================

  describe('buildPreToolContentBlocks', () => {
    const createToolCallsMap = (toolCalls: ToolCallData[]): Map<string, ToolCallData> => {
      return new Map(toolCalls.map(tc => [tc.toolCallId, tc]));
    };

    it('returns null when already flushed', () => {
      const result = buildPreToolContentBlocks(
        '', // thinking
        undefined, // signature
        [], // sequence
        new Map(), // toolCalls
        true // alreadyFlushed
      );

      expect(result).toBeNull();
    });

    it('returns null when no content', () => {
      const result = buildPreToolContentBlocks(
        '', // thinking
        undefined, // signature
        [], // sequence
        new Map(), // toolCalls
        false // alreadyFlushed
      );

      expect(result).toBeNull();
    });

    it('builds thinking-only content', () => {
      const result = buildPreToolContentBlocks(
        'Thinking about the task',
        'sig_abc',
        [],
        new Map(),
        false
      );

      expect(result).toEqual([
        {
          type: 'thinking',
          thinking: 'Thinking about the task',
          signature: 'sig_abc',
        },
      ]);
    });

    it('builds text-only content', () => {
      const sequence: ContentSequenceItem[] = [
        { type: 'text', text: 'Hello world' },
      ];

      const result = buildPreToolContentBlocks(
        '',
        undefined,
        sequence,
        new Map(),
        false
      );

      expect(result).toEqual([
        { type: 'text', text: 'Hello world' },
      ]);
    });

    it('puts thinking first, then text', () => {
      const sequence: ContentSequenceItem[] = [
        { type: 'text', text: 'Hello world' },
      ];

      const result = buildPreToolContentBlocks(
        'Thinking first',
        undefined,
        sequence,
        new Map(),
        false
      );

      expect(result).toHaveLength(2);
      expect(result![0].type).toBe('thinking');
      expect(result![1].type).toBe('text');
    });

    it('includes tool_use blocks', () => {
      const toolCall: ToolCallData = {
        toolCallId: 'tool_1',
        toolName: 'Read',
        arguments: { file_path: '/test' },
        status: 'pending',
      };
      const sequence: ContentSequenceItem[] = [
        { type: 'tool_ref', toolCallId: 'tool_1' },
      ];

      const result = buildPreToolContentBlocks(
        '',
        undefined,
        sequence,
        createToolCallsMap([toolCall]),
        false
      );

      expect(result).toEqual([
        {
          type: 'tool_use',
          id: 'tool_1',
          name: 'Read',
          input: { file_path: '/test' },
        },
      ]);
    });

    it('builds full content with thinking, text, and tools', () => {
      const toolCall: ToolCallData = {
        toolCallId: 'tool_1',
        toolName: 'Write',
        arguments: { file_path: '/out', content: 'data' },
        status: 'pending',
      };
      const sequence: ContentSequenceItem[] = [
        { type: 'text', text: 'Let me write a file' },
        { type: 'tool_ref', toolCallId: 'tool_1' },
      ];

      const result = buildPreToolContentBlocks(
        'Planning the file write',
        'sig_xyz',
        sequence,
        createToolCallsMap([toolCall]),
        false
      );

      expect(result).toHaveLength(3);
      expect(result![0]).toEqual({
        type: 'thinking',
        thinking: 'Planning the file write',
        signature: 'sig_xyz',
      });
      expect(result![1]).toEqual({
        type: 'text',
        text: 'Let me write a file',
      });
      expect(result![2]).toEqual({
        type: 'tool_use',
        id: 'tool_1',
        name: 'Write',
        input: { file_path: '/out', content: 'data' },
      });
    });

    it('skips tool_ref with missing tool data', () => {
      const sequence: ContentSequenceItem[] = [
        { type: 'text', text: 'Hello' },
        { type: 'tool_ref', toolCallId: 'missing_tool' },
      ];

      const result = buildPreToolContentBlocks(
        '',
        undefined,
        sequence,
        new Map(), // Empty map - tool not found
        false
      );

      expect(result).toHaveLength(1);
      expect(result![0]).toEqual({ type: 'text', text: 'Hello' });
    });

    it('skips empty text items', () => {
      const sequence: ContentSequenceItem[] = [
        { type: 'text', text: '' },
        { type: 'text', text: 'Real content' },
      ];

      const result = buildPreToolContentBlocks(
        '',
        undefined,
        sequence,
        new Map(),
        false
      );

      expect(result).toHaveLength(1);
      expect(result![0]).toEqual({ type: 'text', text: 'Real content' });
    });
  });

  // ===========================================================================
  // buildInterruptedContentBlocks
  // ===========================================================================

  describe('buildInterruptedContentBlocks', () => {
    it('returns empty arrays when no content', () => {
      const result = buildInterruptedContentBlocks(
        '', // thinking
        undefined, // signature
        [], // sequence
        [] // toolCalls
      );

      expect(result.assistantContent).toEqual([]);
      expect(result.toolResultContent).toEqual([]);
    });

    it('builds thinking-only content', () => {
      const result = buildInterruptedContentBlocks(
        'Deep thoughts here',
        'sig_deep',
        [],
        []
      );

      expect(result.assistantContent).toEqual([
        {
          type: 'thinking',
          thinking: 'Deep thoughts here',
          signature: 'sig_deep',
        },
      ]);
      expect(result.toolResultContent).toEqual([]);
    });

    it('builds text-only content from sequence', () => {
      const sequence: ContentSequenceItem[] = [
        { type: 'text', text: 'Hello from interrupted session' },
      ];

      const result = buildInterruptedContentBlocks(
        '',
        undefined,
        sequence,
        []
      );

      expect(result.assistantContent).toEqual([
        { type: 'text', text: 'Hello from interrupted session' },
      ]);
    });

    it('builds text from accumulatedText when no sequence', () => {
      const result = buildInterruptedContentBlocks(
        '', // thinking
        undefined, // signature
        [], // empty sequence
        [], // toolCalls
        'Fallback text content' // accumulatedText
      );

      expect(result.assistantContent).toEqual([
        { type: 'text', text: 'Fallback text content' },
      ]);
    });

    it('builds completed tool with tool_use and tool_result', () => {
      const toolCall: ToolCallData = {
        toolCallId: 'tool_1',
        toolName: 'Read',
        arguments: { file_path: '/test' },
        status: 'completed',
        result: 'File contents',
        isError: false,
        startedAt: '2024-01-01T00:00:00.000Z',
        completedAt: '2024-01-01T00:00:02.000Z',
      };
      const sequence: ContentSequenceItem[] = [
        { type: 'tool_ref', toolCallId: 'tool_1' },
      ];

      const result = buildInterruptedContentBlocks(
        '',
        undefined,
        sequence,
        [toolCall]
      );

      // Check assistant content has tool_use
      expect(result.assistantContent).toHaveLength(1);
      expect(result.assistantContent[0].type).toBe('tool_use');
      expect(result.assistantContent[0].id).toBe('tool_1');
      expect(result.assistantContent[0]._meta).toEqual({
        status: 'completed',
        interrupted: false,
        durationMs: 2000,
      });

      // Check tool result
      expect(result.toolResultContent).toHaveLength(1);
      expect(result.toolResultContent[0]).toEqual({
        type: 'tool_result',
        tool_use_id: 'tool_1',
        content: 'File contents',
        is_error: false,
        _meta: {
          durationMs: 2000,
          toolName: 'Read',
        },
      });
    });

    it('builds interrupted (running) tool with proper metadata', () => {
      const toolCall: ToolCallData = {
        toolCallId: 'tool_1',
        toolName: 'Bash',
        arguments: { command: 'sleep 100' },
        status: 'running',
        startedAt: '2024-01-01T00:00:00.000Z',
      };
      const sequence: ContentSequenceItem[] = [
        { type: 'tool_ref', toolCallId: 'tool_1' },
      ];

      const result = buildInterruptedContentBlocks(
        '',
        undefined,
        sequence,
        [toolCall]
      );

      // tool_use should be marked as interrupted
      expect(result.assistantContent[0]._meta?.interrupted).toBe(true);
      expect(result.assistantContent[0]._meta?.status).toBe('running');

      // tool_result should have interrupted message
      expect(result.toolResultContent[0].content).toBe('Command interrupted (no output captured)');
      expect(result.toolResultContent[0]._meta?.interrupted).toBe(true);
    });

    it('builds interrupted (pending) tool with proper metadata', () => {
      const toolCall: ToolCallData = {
        toolCallId: 'tool_1',
        toolName: 'Write',
        arguments: { file_path: '/out', content: 'data' },
        status: 'pending',
      };
      const sequence: ContentSequenceItem[] = [
        { type: 'tool_ref', toolCallId: 'tool_1' },
      ];

      const result = buildInterruptedContentBlocks(
        '',
        undefined,
        sequence,
        [toolCall]
      );

      // tool_use should be marked as interrupted
      expect(result.assistantContent[0]._meta?.interrupted).toBe(true);
      expect(result.assistantContent[0]._meta?.status).toBe('pending');

      // tool_result should have interrupted message
      expect(result.toolResultContent[0]._meta?.interrupted).toBe(true);
    });

    it('builds error tool correctly', () => {
      const toolCall: ToolCallData = {
        toolCallId: 'tool_1',
        toolName: 'Bash',
        arguments: { command: 'exit 1' },
        status: 'error',
        result: 'Command failed with exit code 1',
        isError: true,
        startedAt: '2024-01-01T00:00:00.000Z',
        completedAt: '2024-01-01T00:00:00.500Z',
      };
      const sequence: ContentSequenceItem[] = [
        { type: 'tool_ref', toolCallId: 'tool_1' },
      ];

      const result = buildInterruptedContentBlocks(
        '',
        undefined,
        sequence,
        [toolCall]
      );

      expect(result.assistantContent[0]._meta?.status).toBe('error');
      expect(result.assistantContent[0]._meta?.interrupted).toBe(false);
      expect(result.toolResultContent[0].is_error).toBe(true);
      expect(result.toolResultContent[0].content).toBe('Command failed with exit code 1');
    });

    it('preserves sequence order with thinking first', () => {
      const toolCall: ToolCallData = {
        toolCallId: 'tool_1',
        toolName: 'Read',
        arguments: {},
        status: 'completed',
        result: 'content',
      };
      const sequence: ContentSequenceItem[] = [
        { type: 'text', text: 'Let me read the file' },
        { type: 'tool_ref', toolCallId: 'tool_1' },
      ];

      const result = buildInterruptedContentBlocks(
        'Planning...',
        'sig_plan',
        sequence,
        [toolCall]
      );

      // Order should be: thinking, text, tool_use
      expect(result.assistantContent).toHaveLength(3);
      expect(result.assistantContent[0].type).toBe('thinking');
      expect(result.assistantContent[1].type).toBe('text');
      expect(result.assistantContent[2].type).toBe('tool_use');
    });

    it('handles multiple tool calls', () => {
      const toolCalls: ToolCallData[] = [
        {
          toolCallId: 'tool_1',
          toolName: 'Read',
          arguments: { file_path: '/a' },
          status: 'completed',
          result: 'content a',
        },
        {
          toolCallId: 'tool_2',
          toolName: 'Read',
          arguments: { file_path: '/b' },
          status: 'running', // Interrupted
        },
      ];
      const sequence: ContentSequenceItem[] = [
        { type: 'tool_ref', toolCallId: 'tool_1' },
        { type: 'tool_ref', toolCallId: 'tool_2' },
      ];

      const result = buildInterruptedContentBlocks(
        '',
        undefined,
        sequence,
        toolCalls
      );

      expect(result.assistantContent).toHaveLength(2);
      expect(result.toolResultContent).toHaveLength(2);

      // First tool completed
      expect(result.assistantContent[0]._meta?.interrupted).toBe(false);
      expect(result.toolResultContent[0].content).toBe('content a');

      // Second tool interrupted
      expect(result.assistantContent[1]._meta?.interrupted).toBe(true);
      expect(result.toolResultContent[1]._meta?.interrupted).toBe(true);
    });

    it('uses fallback when sequence is empty but tools exist', () => {
      const toolCall: ToolCallData = {
        toolCallId: 'tool_1',
        toolName: 'Bash',
        arguments: { command: 'echo hi' },
        status: 'completed',
        result: 'hi',
      };

      const result = buildInterruptedContentBlocks(
        'Thinking',
        'sig',
        [], // Empty sequence
        [toolCall],
        'Some text' // accumulatedText fallback
      );

      // Should have thinking, text (from fallback), and tool_use
      expect(result.assistantContent).toHaveLength(3);
      expect(result.assistantContent[0].type).toBe('thinking');
      expect(result.assistantContent[1].type).toBe('text');
      expect(result.assistantContent[1].text).toBe('Some text');
      expect(result.assistantContent[2].type).toBe('tool_use');
    });

    it('skips thinking items in sequence (already handled)', () => {
      const sequence: ContentSequenceItem[] = [
        { type: 'thinking', thinking: 'Duplicate thinking' },
        { type: 'text', text: 'Real text' },
      ];

      const result = buildInterruptedContentBlocks(
        'Main thinking',
        'sig',
        sequence,
        []
      );

      // Should have main thinking + thinking from sequence + text
      // The function adds thinking from sequence as well
      expect(result.assistantContent[0].type).toBe('thinking');
      expect(result.assistantContent[0].thinking).toBe('Main thinking');
    });
  });
});
