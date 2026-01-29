/**
 * @fileoverview Tests for ContextSnapshotBuilder
 *
 * ContextSnapshotBuilder handles snapshot generation for context state:
 * - Basic snapshots with token breakdown
 * - Detailed snapshots with per-message information
 * - Threshold level determination
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import {
  ContextSnapshotBuilder,
  createContextSnapshotBuilder,
  type SnapshotDeps,
} from '../context-snapshot-builder.js';
import type { Message, Tool } from '../../types/index.js';

describe('ContextSnapshotBuilder', () => {
  let builder: ContextSnapshotBuilder;
  let mockDeps: SnapshotDeps;

  beforeEach(() => {
    mockDeps = {
      getCurrentTokens: vi.fn(() => 50000),
      getContextLimit: vi.fn(() => 100000),
      getMessages: vi.fn(() => []),
      estimateSystemPromptTokens: vi.fn(() => 1000),
      estimateToolsTokens: vi.fn(() => 500),
      estimateRulesTokens: vi.fn(() => 200),
      getMessagesTokens: vi.fn(() => 5000),
      getMessageTokens: vi.fn(() => 100),
      getSystemPrompt: vi.fn(() => 'You are a helpful assistant.'),
      getToolClarificationMessage: vi.fn(() => null),
      getTools: vi.fn(() => []),
    };

    builder = createContextSnapshotBuilder(mockDeps);
  });

  describe('getThresholdLevel', () => {
    it('should return "normal" below warning threshold', () => {
      expect(builder.getThresholdLevel(40000)).toBe('normal');
    });

    it('should return "warning" at warning threshold (50%)', () => {
      expect(builder.getThresholdLevel(50000)).toBe('warning');
    });

    it('should return "alert" at alert threshold (70%)', () => {
      expect(builder.getThresholdLevel(70000)).toBe('alert');
    });

    it('should return "critical" at critical threshold (85%)', () => {
      expect(builder.getThresholdLevel(85000)).toBe('critical');
    });

    it('should return "exceeded" at exceeded threshold (95%)', () => {
      expect(builder.getThresholdLevel(95000)).toBe('exceeded');
    });
  });

  describe('build (basic snapshot)', () => {
    it('should return correct snapshot structure', () => {
      const snapshot = builder.build();

      expect(snapshot).toEqual({
        currentTokens: 50000,
        contextLimit: 100000,
        usagePercent: 0.5,
        thresholdLevel: 'warning',
        breakdown: {
          systemPrompt: 1000,
          tools: 500,
          rules: 200,
          messages: 5000,
        },
      });
    });

    it('should calculate usage percent correctly', () => {
      (mockDeps.getCurrentTokens as ReturnType<typeof vi.fn>).mockReturnValue(25000);

      const snapshot = builder.build();

      expect(snapshot.usagePercent).toBe(0.25);
    });

    it('should determine threshold level correctly', () => {
      (mockDeps.getCurrentTokens as ReturnType<typeof vi.fn>).mockReturnValue(90000);

      const snapshot = builder.build();

      expect(snapshot.thresholdLevel).toBe('critical');
    });

    it('should include breakdown from deps', () => {
      (mockDeps.estimateSystemPromptTokens as ReturnType<typeof vi.fn>).mockReturnValue(2000);
      (mockDeps.estimateToolsTokens as ReturnType<typeof vi.fn>).mockReturnValue(1500);
      (mockDeps.estimateRulesTokens as ReturnType<typeof vi.fn>).mockReturnValue(300);
      (mockDeps.getMessagesTokens as ReturnType<typeof vi.fn>).mockReturnValue(10000);

      const snapshot = builder.build();

      expect(snapshot.breakdown).toEqual({
        systemPrompt: 2000,
        tools: 1500,
        rules: 300,
        messages: 10000,
      });
    });
  });

  describe('buildDetailed', () => {
    it('should include basic snapshot fields', () => {
      const detailed = builder.buildDetailed();

      expect(detailed.currentTokens).toBe(50000);
      expect(detailed.contextLimit).toBe(100000);
      expect(detailed.thresholdLevel).toBe('warning');
    });

    it('should include system prompt content', () => {
      (mockDeps.getSystemPrompt as ReturnType<typeof vi.fn>).mockReturnValue('Custom prompt');

      const detailed = builder.buildDetailed();

      expect(detailed.systemPromptContent).toBe('Custom prompt');
    });

    it('should include tool clarification when present', () => {
      (mockDeps.getToolClarificationMessage as ReturnType<typeof vi.fn>).mockReturnValue(
        'Tool clarification message'
      );

      const detailed = builder.buildDetailed();

      expect(detailed.systemPromptContent).toBe('Tool clarification message');
      expect(detailed.toolClarificationContent).toBe('Tool clarification message');
    });

    it('should include tools content', () => {
      const tools: Tool[] = [
        { name: 'read', description: 'Read a file', parameters: { type: 'object' } },
        { name: 'write', description: 'Write a file', parameters: { type: 'object' } },
      ];
      (mockDeps.getTools as ReturnType<typeof vi.fn>).mockReturnValue(tools);

      const detailed = builder.buildDetailed();

      expect(detailed.toolsContent).toEqual([
        'read: Read a file',
        'write: Write a file',
      ]);
    });

    it('should handle tools without description', () => {
      const tools: Tool[] = [
        { name: 'bash', description: '', parameters: { type: 'object' } },
      ];
      (mockDeps.getTools as ReturnType<typeof vi.fn>).mockReturnValue(tools);

      const detailed = builder.buildDetailed();

      expect(detailed.toolsContent).toEqual(['bash: No description']);
    });
  });

  describe('buildDetailed with messages', () => {
    it('should include user message details', () => {
      const messages: Message[] = [
        { role: 'user', content: 'Hello, how are you?' },
      ];
      (mockDeps.getMessages as ReturnType<typeof vi.fn>).mockReturnValue(messages);

      const detailed = builder.buildDetailed();

      expect(detailed.messages).toHaveLength(1);
      expect(detailed.messages[0]).toMatchObject({
        index: 0,
        role: 'user',
        content: 'Hello, how are you?',
      });
    });

    it('should truncate long user messages in summary', () => {
      const longContent = 'A'.repeat(150);
      const messages: Message[] = [{ role: 'user', content: longContent }];
      (mockDeps.getMessages as ReturnType<typeof vi.fn>).mockReturnValue(messages);

      const detailed = builder.buildDetailed();

      expect(detailed.messages[0]?.summary?.length).toBeLessThan(150);
      expect(detailed.messages[0]?.summary).toContain('...');
      expect(detailed.messages[0]?.content).toBe(longContent);
    });

    it('should include assistant message details', () => {
      const messages: Message[] = [
        {
          role: 'assistant',
          content: [{ type: 'text', text: 'I am doing well!' }],
        },
      ];
      (mockDeps.getMessages as ReturnType<typeof vi.fn>).mockReturnValue(messages);

      const detailed = builder.buildDetailed();

      expect(detailed.messages[0]).toMatchObject({
        index: 0,
        role: 'assistant',
        content: 'I am doing well!',
      });
    });

    it('should handle tool calls in assistant messages', () => {
      const messages: Message[] = [
        {
          role: 'assistant',
          content: [
            { type: 'text', text: 'Let me read the file.' },
            {
              type: 'tool_use',
              id: 'tool_123',
              name: 'read',
              arguments: { path: '/test.ts' },
            },
          ],
        },
      ];
      (mockDeps.getMessages as ReturnType<typeof vi.fn>).mockReturnValue(messages);

      const detailed = builder.buildDetailed();

      expect(detailed.messages[0]?.toolCalls).toHaveLength(1);
      expect(detailed.messages[0]?.toolCalls?.[0]).toMatchObject({
        id: 'tool_123',
        name: 'read',
      });
    });

    it('should include tool result details', () => {
      const messages: Message[] = [
        {
          role: 'toolResult',
          toolCallId: 'tool_123',
          content: 'File contents here',
          isError: false,
        },
      ];
      (mockDeps.getMessages as ReturnType<typeof vi.fn>).mockReturnValue(messages);

      const detailed = builder.buildDetailed();

      expect(detailed.messages[0]).toMatchObject({
        role: 'toolResult',
        toolCallId: 'tool_123',
        content: 'File contents here',
        isError: false,
      });
    });

    it('should handle error tool results', () => {
      const messages: Message[] = [
        {
          role: 'toolResult',
          toolCallId: 'tool_456',
          content: 'Error: File not found',
          isError: true,
        },
      ];
      (mockDeps.getMessages as ReturnType<typeof vi.fn>).mockReturnValue(messages);

      const detailed = builder.buildDetailed();

      expect(detailed.messages[0]?.isError).toBe(true);
    });

    it('should handle user messages with content blocks', () => {
      const messages: Message[] = [
        {
          role: 'user',
          content: [
            { type: 'text', text: 'Look at this image:' },
            { type: 'image', data: 'abc', mimeType: 'image/png' },
          ],
        },
      ];
      (mockDeps.getMessages as ReturnType<typeof vi.fn>).mockReturnValue(messages);

      const detailed = builder.buildDetailed();

      expect(detailed.messages[0]?.content).toContain('Look at this image:');
      expect(detailed.messages[0]?.content).toContain('[image]');
    });
  });

  describe('factory function', () => {
    it('should create ContextSnapshotBuilder instance', () => {
      const builder = createContextSnapshotBuilder(mockDeps);

      expect(builder).toBeInstanceOf(ContextSnapshotBuilder);
    });
  });
});
