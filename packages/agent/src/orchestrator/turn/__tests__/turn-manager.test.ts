/**
 * @fileoverview TurnManager Unit Tests
 *
 * Tests for the TurnManager module which handles turn lifecycle management.
 * These tests define the contract for TurnManager:
 *
 * 1. Turn number tracking and increments
 * 2. Content accumulation (text + tool calls) with proper sequencing
 * 3. Building message.assistant content at turn end
 * 4. Building interrupted content for persistence
 * 5. Token usage tracking
 * 6. Agent run lifecycle (start/end clears state)
 */
import { describe, it, expect, beforeEach } from 'vitest';
import {
  TurnManager,
  createTurnManager,
  type TokenUsage,
  type EndTurnResult,
} from '../turn-manager.js';

describe('TurnManager', () => {
  let turnManager: TurnManager;

  beforeEach(() => {
    turnManager = createTurnManager();
  });

  describe('Basic turn lifecycle', () => {
    it('should start with turn 0', () => {
      expect(turnManager.getCurrentTurn()).toBe(0);
    });

    it('should increment turn number on startTurn', () => {
      turnManager.startTurn(1);
      expect(turnManager.getCurrentTurn()).toBe(1);

      turnManager.startTurn(2);
      expect(turnManager.getCurrentTurn()).toBe(2);
    });

    it('should track turn start time', () => {
      const before = Date.now();
      turnManager.startTurn(1);
      const after = Date.now();

      const startTime = turnManager.getTurnStartTime();
      expect(startTime).toBeDefined();
      expect(startTime).toBeGreaterThanOrEqual(before);
      expect(startTime).toBeLessThanOrEqual(after);
    });

    it('should clear per-turn content on startTurn', () => {
      // Add content to turn 1
      turnManager.startTurn(1);
      turnManager.addTextDelta('Turn 1 text');

      // Start turn 2 - per-turn content should clear
      turnManager.startTurn(2);

      // End turn 2 - should have no content from turn 1
      const result = turnManager.endTurn();
      expect(result.content.length).toBe(0);
    });
  });

  describe('Text accumulation', () => {
    it('should accumulate text deltas', () => {
      turnManager.startTurn(1);
      turnManager.addTextDelta('Hello ');
      turnManager.addTextDelta('world');

      const result = turnManager.endTurn();
      expect(result.content).toEqual([{ type: 'text', text: 'Hello world' }]);
    });

    it('should merge consecutive text deltas into single block', () => {
      turnManager.startTurn(1);
      turnManager.addTextDelta('Part 1');
      turnManager.addTextDelta(' Part 2');
      turnManager.addTextDelta(' Part 3');

      const result = turnManager.endTurn();

      // Should be merged into single text block
      expect(result.content.length).toBe(1);
      expect(result.content[0]).toEqual({
        type: 'text',
        text: 'Part 1 Part 2 Part 3',
      });
    });

    it('should preserve accumulated text across turns', () => {
      turnManager.startTurn(1);
      turnManager.addTextDelta('Turn 1');
      turnManager.endTurn();

      turnManager.startTurn(2);
      turnManager.addTextDelta('Turn 2');
      turnManager.endTurn();

      const accumulated = turnManager.getAccumulatedContent();
      expect(accumulated.text).toContain('Turn 1');
      expect(accumulated.text).toContain('Turn 2');
    });
  });

  describe('Tool call tracking', () => {
    it('should track tool call start and end', () => {
      turnManager.startTurn(1);
      turnManager.startToolCall('tc_1', 'Read', { file_path: '/test.ts' });
      turnManager.endToolCall('tc_1', 'file contents', false);

      const result = turnManager.endTurn();

      expect(result.content).toEqual([
        {
          type: 'tool_use',
          id: 'tc_1',
          name: 'Read',
          input: { file_path: '/test.ts' },
        },
      ]);

      expect(result.toolResults).toEqual([
        {
          type: 'tool_result',
          tool_use_id: 'tc_1',
          content: 'file contents',
          is_error: false,
        },
      ]);
    });

    it('should track multiple tool calls in sequence', () => {
      turnManager.startTurn(1);

      turnManager.startToolCall('tc_1', 'Read', { path: 'a.ts' });
      turnManager.endToolCall('tc_1', 'content A', false);

      turnManager.startToolCall('tc_2', 'Write', { path: 'b.ts' });
      turnManager.endToolCall('tc_2', 'success', false);

      const result = turnManager.endTurn();

      expect(result.content.length).toBe(2);
      expect(result.content[0]).toMatchObject({ type: 'tool_use', id: 'tc_1' });
      expect(result.content[1]).toMatchObject({ type: 'tool_use', id: 'tc_2' });
    });

    it('should handle tool call errors', () => {
      turnManager.startTurn(1);
      turnManager.startToolCall('tc_1', 'Bash', { command: 'bad-cmd' });
      turnManager.endToolCall('tc_1', 'command not found', true);

      const result = turnManager.endTurn();

      expect(result.toolResults[0]).toMatchObject({
        tool_use_id: 'tc_1',
        is_error: true,
        content: 'command not found',
      });
    });

    it('should preserve interleaving of text and tool calls', () => {
      turnManager.startTurn(1);

      turnManager.addTextDelta('Let me read the file');
      turnManager.startToolCall('tc_1', 'Read', { path: 'test.ts' });
      turnManager.endToolCall('tc_1', 'content', false);
      turnManager.addTextDelta('Now I understand');

      const result = turnManager.endTurn();

      // Should be: text, tool_use, text
      expect(result.content.length).toBe(3);
      expect(result.content[0]).toMatchObject({ type: 'text', text: 'Let me read the file' });
      expect(result.content[1]).toMatchObject({ type: 'tool_use', id: 'tc_1' });
      expect(result.content[2]).toMatchObject({ type: 'text', text: 'Now I understand' });
    });
  });

  describe('endTurn()', () => {
    it('should return turn content and clear per-turn state', () => {
      turnManager.startTurn(1);
      turnManager.addTextDelta('Content');

      const result1 = turnManager.endTurn();
      expect(result1.content.length).toBe(1);

      // Second endTurn should return empty (per-turn cleared)
      const result2 = turnManager.endTurn();
      expect(result2.content.length).toBe(0);
    });

    it('should track token usage when set before endTurn', () => {
      const tokenUsage: TokenUsage = {
        inputTokens: 100,
        outputTokens: 50,
        cacheReadTokens: 10,
        cacheCreationTokens: 5,
      };

      turnManager.startTurn(1);
      turnManager.addTextDelta('Response');
      turnManager.setResponseTokenUsage(tokenUsage);

      const result = turnManager.endTurn();

      expect(result.tokenUsage).toEqual(tokenUsage);
    });

    it('should return turn number', () => {
      turnManager.startTurn(3);
      turnManager.addTextDelta('Content');

      const result = turnManager.endTurn();
      expect(result.turn).toBe(3);
    });
  });

  describe('Interrupted content', () => {
    it('should build interrupted content with pending tool calls', () => {
      turnManager.startTurn(1);
      turnManager.addTextDelta('Starting work');
      turnManager.startToolCall('tc_1', 'Bash', { command: 'long-running' });
      // Tool call not ended - simulates interruption mid-execution

      const interrupted = turnManager.buildInterruptedContent();

      expect(interrupted.assistantContent.length).toBe(2);
      expect(interrupted.assistantContent[0]).toMatchObject({
        type: 'text',
        text: 'Starting work',
      });
      expect(interrupted.assistantContent[1]).toMatchObject({
        type: 'tool_use',
        id: 'tc_1',
        name: 'Bash',
        _meta: { status: 'running', interrupted: true },
      });
    });

    it('should include completed tool results in interrupted content', () => {
      turnManager.startTurn(1);
      turnManager.startToolCall('tc_1', 'Read', { path: 'a.ts' });
      turnManager.endToolCall('tc_1', 'file content', false);
      turnManager.addTextDelta('Analyzing...');
      // Interrupted after tool completed but mid-response

      const interrupted = turnManager.buildInterruptedContent();

      // Should have tool_use, text
      expect(interrupted.assistantContent.length).toBe(2);

      // Should have tool_result for completed tool
      expect(interrupted.toolResultContent.length).toBe(1);
      expect(interrupted.toolResultContent[0]).toMatchObject({
        tool_use_id: 'tc_1',
        content: 'file content',
        is_error: false,
      });
    });

    it('should mark interrupted tool calls with proper metadata', () => {
      turnManager.startTurn(1);
      turnManager.startToolCall('tc_1', 'Bash', { command: 'sleep 100' });
      // Not ended - interrupted

      const interrupted = turnManager.buildInterruptedContent();

      const toolUse = interrupted.assistantContent.find(
        c => c.type === 'tool_use'
      );
      expect(toolUse?._meta).toMatchObject({
        status: 'running',
        interrupted: true,
      });

      // Should also have a tool_result with interrupted marker
      expect(interrupted.toolResultContent.length).toBe(1);
      expect(interrupted.toolResultContent[0]._meta?.interrupted).toBe(true);
    });
  });

  describe('Accumulated content (for client catch-up)', () => {
    it('should accumulate content across multiple turns', () => {
      turnManager.startTurn(1);
      turnManager.addTextDelta('Response 1');
      turnManager.endTurn();

      turnManager.startTurn(2);
      turnManager.addTextDelta('Response 2');
      turnManager.endTurn();

      const accumulated = turnManager.getAccumulatedContent();
      expect(accumulated.text).toContain('Response 1');
      expect(accumulated.text).toContain('Response 2');
    });

    it('should track tool calls across turns', () => {
      turnManager.startTurn(1);
      turnManager.startToolCall('tc_1', 'Read', {});
      turnManager.endToolCall('tc_1', 'result 1', false);
      turnManager.endTurn();

      turnManager.startTurn(2);
      turnManager.startToolCall('tc_2', 'Write', {});
      turnManager.endToolCall('tc_2', 'result 2', false);
      turnManager.endTurn();

      const accumulated = turnManager.getAccumulatedContent();
      expect(accumulated.toolCalls.length).toBe(2);
    });

    it('should report hasAccumulatedContent correctly', () => {
      expect(turnManager.hasAccumulatedContent()).toBe(false);

      turnManager.startTurn(1);
      turnManager.addTextDelta('Some text');
      turnManager.endTurn();

      expect(turnManager.hasAccumulatedContent()).toBe(true);
    });
  });

  describe('Agent lifecycle', () => {
    it('should clear all state on onAgentStart', () => {
      // Build up state
      turnManager.startTurn(1);
      turnManager.addTextDelta('Some content');
      turnManager.startToolCall('tc_1', 'Read', {});
      turnManager.endToolCall('tc_1', 'result', false);
      turnManager.endTurn();

      // Start new agent run
      turnManager.onAgentStart();

      // All state should be cleared
      expect(turnManager.getCurrentTurn()).toBe(0);
      expect(turnManager.hasAccumulatedContent()).toBe(false);
    });

    it('should clear all state on onAgentEnd', () => {
      turnManager.startTurn(1);
      turnManager.addTextDelta('Content');
      turnManager.endTurn();

      turnManager.onAgentEnd();

      expect(turnManager.hasAccumulatedContent()).toBe(false);
    });
  });

  describe('Edge cases', () => {
    it('should handle empty turn', () => {
      turnManager.startTurn(1);
      const result = turnManager.endTurn();

      expect(result.content).toEqual([]);
      expect(result.toolResults).toEqual([]);
    });

    it('should handle turn with only tool calls (no text)', () => {
      turnManager.startTurn(1);
      turnManager.startToolCall('tc_1', 'Bash', { command: 'ls' });
      turnManager.endToolCall('tc_1', 'files', false);

      const result = turnManager.endTurn();

      expect(result.content.length).toBe(1);
      expect(result.content[0].type).toBe('tool_use');
    });

    it('should handle multiple startTurn calls without endTurn', () => {
      turnManager.startTurn(1);
      turnManager.addTextDelta('Turn 1');

      // Start turn 2 without ending turn 1
      turnManager.startTurn(2);
      turnManager.addTextDelta('Turn 2');

      const result = turnManager.endTurn();

      // Should only have turn 2 content
      expect(result.turn).toBe(2);
      expect(result.content[0]).toMatchObject({ text: 'Turn 2' });
    });

    it('should handle endTurn without startTurn', () => {
      // Should not throw, just return empty content
      const result = turnManager.endTurn();
      expect(result.content).toEqual([]);
      expect(result.turn).toBe(0);
    });
  });

  describe('Thinking support', () => {
    it('should accumulate thinking deltas', () => {
      turnManager.startTurn(1);
      turnManager.addThinkingDelta('Let me ');
      turnManager.addThinkingDelta('think...');

      const result = turnManager.endTurn();

      // Thinking should be the first content block
      expect(result.content.length).toBeGreaterThanOrEqual(1);
      expect(result.content[0]).toMatchObject({
        type: 'thinking',
        thinking: 'Let me think...',
      });
    });

    it('should place thinking before text in content blocks', () => {
      turnManager.startTurn(1);
      turnManager.addThinkingDelta('Internal reasoning');
      turnManager.addTextDelta('External response');

      const result = turnManager.endTurn();

      // Thinking should come first
      expect(result.content.length).toBe(2);
      expect(result.content[0]).toMatchObject({ type: 'thinking' });
      expect(result.content[1]).toMatchObject({ type: 'text' });
    });

    it('should preserve thinking with tool calls', () => {
      turnManager.startTurn(1);
      turnManager.addThinkingDelta('Analyzing the request');
      turnManager.addTextDelta('Let me read that file');
      turnManager.startToolCall('tc_1', 'Read', { file_path: '/test.ts' });
      turnManager.endToolCall('tc_1', 'file contents', false);

      const result = turnManager.endTurn();

      // Order should be: thinking, text, tool_use
      expect(result.content.length).toBe(3);
      expect(result.content[0]).toMatchObject({ type: 'thinking' });
      expect(result.content[1]).toMatchObject({ type: 'text' });
      expect(result.content[2]).toMatchObject({ type: 'tool_use' });
    });

    it('should clear thinking on new turn', () => {
      turnManager.startTurn(1);
      turnManager.addThinkingDelta('Turn 1 thinking');
      turnManager.endTurn();

      turnManager.startTurn(2);
      turnManager.addTextDelta('Turn 2 text only');

      const result = turnManager.endTurn();

      // Turn 2 should not have thinking from Turn 1
      expect(result.content.length).toBe(1);
      expect(result.content[0]).toMatchObject({ type: 'text' });
    });

    it('should include thinking in accumulated content', () => {
      turnManager.startTurn(1);
      turnManager.addThinkingDelta('First turn thinking');
      turnManager.addTextDelta('First turn text');
      turnManager.endTurn();

      turnManager.startTurn(2);
      turnManager.addThinkingDelta('Second turn thinking');
      turnManager.addTextDelta('Second turn text');
      turnManager.endTurn();

      const accumulated = turnManager.getAccumulatedContent();
      expect(accumulated.thinking).toContain('First turn thinking');
      expect(accumulated.thinking).toContain('Second turn thinking');
    });

    it('should include thinking in interrupted content', () => {
      turnManager.startTurn(1);
      turnManager.addThinkingDelta('Interrupted thoughts');
      turnManager.addTextDelta('Working on it...');
      turnManager.startToolCall('tc_1', 'Bash', { command: 'long-task' });
      // Tool not ended - interruption

      const interrupted = turnManager.buildInterruptedContent();

      // Thinking should be first in assistant content
      expect(interrupted.assistantContent.length).toBeGreaterThan(0);
      expect(interrupted.assistantContent[0]).toMatchObject({
        type: 'thinking',
        thinking: 'Interrupted thoughts',
      });
    });

    it('should handle turn with only thinking (no text)', () => {
      turnManager.startTurn(1);
      turnManager.addThinkingDelta('Just thinking, no response yet');

      const result = turnManager.endTurn();

      expect(result.content.length).toBe(1);
      expect(result.content[0]).toMatchObject({
        type: 'thinking',
        thinking: 'Just thinking, no response yet',
      });
    });

    it('should clear thinking on agent start', () => {
      turnManager.startTurn(1);
      turnManager.addThinkingDelta('Some thinking');
      turnManager.endTurn();

      turnManager.onAgentStart();

      expect(turnManager.hasAccumulatedContent()).toBe(false);
    });

    it('should clear thinking on agent end', () => {
      turnManager.startTurn(1);
      turnManager.addThinkingDelta('Some thinking');
      turnManager.endTurn();

      turnManager.onAgentEnd();

      expect(turnManager.hasAccumulatedContent()).toBe(false);
    });
  });
});
