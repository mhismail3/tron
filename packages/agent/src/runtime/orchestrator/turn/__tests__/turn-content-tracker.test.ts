/**
 * @fileoverview Tests for TurnContentTracker
 *
 * Tests the tool intent batching and pre-tool content flush behavior
 * that enables linear event ordering.
 */
import { describe, it, expect, beforeEach } from 'vitest';
import { TurnContentTracker } from '../turn-content-tracker.js';

describe('TurnContentTracker', () => {
  let tracker: TurnContentTracker;

  beforeEach(() => {
    tracker = new TurnContentTracker();
  });

  describe('registerToolIntents', () => {
    it('should register all tool intents at once', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);

      tracker.registerToolIntents([
        { id: 'tc_1', name: 'Read', arguments: { file_path: 'a.ts' } },
        { id: 'tc_2', name: 'Read', arguments: { file_path: 'b.ts' } },
        { id: 'tc_3', name: 'Read', arguments: { file_path: 'c.ts' } },
      ]);

      const content = tracker.getThisTurnContent();
      expect(content.toolCalls.size).toBe(3);
      expect(content.sequence).toHaveLength(3);

      // All tools should be registered as pending
      expect(content.toolCalls.get('tc_1')?.status).toBe('pending');
      expect(content.toolCalls.get('tc_2')?.status).toBe('pending');
      expect(content.toolCalls.get('tc_3')?.status).toBe('pending');
    });

    it('should not duplicate tools if called multiple times with same ID', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);

      tracker.registerToolIntents([
        { id: 'tc_1', name: 'Read', arguments: { file_path: 'a.ts' } },
      ]);

      // Try to register same tool again
      tracker.registerToolIntents([
        { id: 'tc_1', name: 'Read', arguments: { file_path: 'a.ts' } },
      ]);

      const content = tracker.getThisTurnContent();
      expect(content.toolCalls.size).toBe(1);
      expect(content.sequence).toHaveLength(1);
    });
  });

  describe('startToolCall with pre-registered tools', () => {
    it('should update status to running for pre-registered tool', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);

      // Pre-register tools
      tracker.registerToolIntents([
        { id: 'tc_1', name: 'Read', arguments: { file_path: 'a.ts' } },
        { id: 'tc_2', name: 'Read', arguments: { file_path: 'b.ts' } },
      ]);

      // Start executing first tool
      tracker.startToolCall('tc_1', 'Read', { file_path: 'a.ts' }, '2024-01-01T00:00:00Z');

      const content = tracker.getThisTurnContent();
      // Should not add duplicate sequence entry
      expect(content.sequence).toHaveLength(2);
      // Status should be updated
      expect(content.toolCalls.get('tc_1')?.status).toBe('running');
      expect(content.toolCalls.get('tc_1')?.startedAt).toBe('2024-01-01T00:00:00Z');
      // Other tool still pending
      expect(content.toolCalls.get('tc_2')?.status).toBe('pending');
    });
  });

  describe('flushPreToolContent', () => {
    it('should return all registered tool_use blocks on first flush', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);
      tracker.addTextDelta('Let me read those files.');

      // Pre-register multiple tools (simulating tool_use_batch event)
      tracker.registerToolIntents([
        { id: 'tc_1', name: 'Read', arguments: { file_path: 'a.ts' } },
        { id: 'tc_2', name: 'Ls', arguments: { path: '.' } },
        { id: 'tc_3', name: 'Bash', arguments: { command: 'echo test' } },
      ]);

      // Flush should include ALL tools
      const flushed = tracker.flushPreToolContent();
      expect(flushed).not.toBeNull();
      expect(flushed).toHaveLength(4); // 1 text + 3 tool_use

      // Verify structure
      expect(flushed![0]).toEqual({ type: 'text', text: 'Let me read those files.' });
      expect(flushed![1]).toEqual({
        type: 'tool_use',
        id: 'tc_1',
        name: 'Read',
        input: { file_path: 'a.ts' },
      });
      expect(flushed![2]).toEqual({
        type: 'tool_use',
        id: 'tc_2',
        name: 'Ls',
        input: { path: '.' },
      });
      expect(flushed![3]).toEqual({
        type: 'tool_use',
        id: 'tc_3',
        name: 'Bash',
        input: { command: 'echo test' },
      });
    });

    it('should return null on subsequent flush attempts', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);
      tracker.addTextDelta('Hello');
      tracker.registerToolIntents([
        { id: 'tc_1', name: 'Read', arguments: {} },
      ]);

      // First flush succeeds
      const first = tracker.flushPreToolContent();
      expect(first).not.toBeNull();

      // Second flush returns null (already flushed)
      const second = tracker.flushPreToolContent();
      expect(second).toBeNull();
    });

    it('should reset flush flag on new turn', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);
      tracker.addTextDelta('Turn 1');
      tracker.registerToolIntents([{ id: 'tc_1', name: 'Read', arguments: {} }]);

      // Flush turn 1
      tracker.flushPreToolContent();
      expect(tracker.hasPreToolContentFlushed()).toBe(true);

      // Start new turn
      tracker.onTurnStart(2);
      expect(tracker.hasPreToolContentFlushed()).toBe(false);

      // Can flush turn 2
      tracker.addTextDelta('Turn 2');
      tracker.registerToolIntents([{ id: 'tc_2', name: 'Ls', arguments: {} }]);
      const flushed = tracker.flushPreToolContent();
      expect(flushed).not.toBeNull();
      expect(flushed).toHaveLength(2);
    });

    it('should include thinking block with signature when flushing', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);

      // Add thinking content with signature
      tracker.addThinkingDelta('I should read the file first');
      tracker.setThinkingSignature('sig_abc123');

      // Add text and tools
      tracker.addTextDelta('Let me read that file.');
      tracker.registerToolIntents([
        { id: 'tc_1', name: 'Read', arguments: { file_path: 'test.ts' } },
      ]);

      const flushed = tracker.flushPreToolContent();
      expect(flushed).not.toBeNull();
      expect(flushed).toHaveLength(3); // thinking + text + tool_use

      // CRITICAL: Thinking must be first
      expect(flushed![0]).toEqual({
        type: 'thinking',
        thinking: 'I should read the file first',
        signature: 'sig_abc123',
      });
      expect(flushed![1]).toEqual({ type: 'text', text: 'Let me read that file.' });
      expect(flushed![2]).toEqual({
        type: 'tool_use',
        id: 'tc_1',
        name: 'Read',
        input: { file_path: 'test.ts' },
      });
    });

    it('should include thinking block without signature when signature not set', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);

      // Add thinking content WITHOUT signature
      tracker.addThinkingDelta('I should check the status');

      // Add tool
      tracker.registerToolIntents([
        { id: 'tc_1', name: 'Bash', arguments: { command: 'git status' } },
      ]);

      const flushed = tracker.flushPreToolContent();
      expect(flushed).not.toBeNull();
      expect(flushed).toHaveLength(2); // thinking + tool_use

      // Thinking should be included even without signature
      expect(flushed![0]).toEqual({
        type: 'thinking',
        thinking: 'I should check the status',
        signature: undefined,
      });
      expect(flushed![1]).toEqual({
        type: 'tool_use',
        id: 'tc_1',
        name: 'Bash',
        input: { command: 'git status' },
      });
    });

    it('should flush thinking-only content (no text or tools)', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);

      // Only thinking, no text or tools
      tracker.addThinkingDelta('Just analyzing the situation');
      tracker.setThinkingSignature('sig_xyz789');

      const flushed = tracker.flushPreToolContent();
      expect(flushed).not.toBeNull();
      expect(flushed).toHaveLength(1); // only thinking

      expect(flushed![0]).toEqual({
        type: 'thinking',
        thinking: 'Just analyzing the situation',
        signature: 'sig_xyz789',
      });
    });

    it('should preserve thinking signature across multiple thinking deltas', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);

      // Multiple thinking deltas (simulating streaming)
      tracker.addThinkingDelta('I need to ');
      tracker.addThinkingDelta('read the file ');
      tracker.addThinkingDelta('to understand the code.');
      tracker.setThinkingSignature('sig_complete');

      tracker.registerToolIntents([
        { id: 'tc_1', name: 'Read', arguments: { file_path: 'app.ts' } },
      ]);

      const flushed = tracker.flushPreToolContent();
      expect(flushed).not.toBeNull();

      // Thinking should be accumulated
      expect(flushed![0]).toEqual({
        type: 'thinking',
        thinking: 'I need to read the file to understand the code.',
        signature: 'sig_complete',
      });
    });
  });

  describe('backward compatibility', () => {
    it('should work without registerToolIntents (old behavior)', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);
      tracker.addTextDelta('Hello');

      // Old behavior: startToolCall directly without pre-registration
      tracker.startToolCall('tc_1', 'Read', { file_path: 'test.ts' }, '2024-01-01T00:00:00Z');

      // Should still work
      const flushed = tracker.flushPreToolContent();
      expect(flushed).not.toBeNull();
      expect(flushed).toHaveLength(2);
      expect(flushed![0]).toEqual({ type: 'text', text: 'Hello' });
      expect(flushed![1]).toEqual({
        type: 'tool_use',
        id: 'tc_1',
        name: 'Read',
        input: { file_path: 'test.ts' },
      });
    });
  });

  describe('multi-tool scenario (real-world simulation)', () => {
    it('should capture all tools when flushing before first execution', () => {
      // Simulates the flow: model returns multiple tool_use → tool_use_batch event →
      // first tool_execution_start → flush → message.assistant with ALL tools
      tracker.onAgentStart();
      tracker.onTurnStart(1);

      // Model streams text
      tracker.addTextDelta('I will read three files.');

      // Model finishes, tool_use_batch event arrives with ALL tools
      tracker.registerToolIntents([
        { id: 'tc_1', name: 'Read', arguments: { file_path: 'a.ts' } },
        { id: 'tc_2', name: 'Read', arguments: { file_path: 'b.ts' } },
        { id: 'tc_3', name: 'Read', arguments: { file_path: 'c.ts' } },
      ]);

      // First tool_execution_start arrives
      tracker.startToolCall('tc_1', 'Read', { file_path: 'a.ts' }, '2024-01-01T00:00:01Z');

      // Flush at first tool start - should have ALL tools
      const flushed = tracker.flushPreToolContent();
      expect(flushed).not.toBeNull();
      expect(flushed).toHaveLength(4); // 1 text + 3 tools

      // Verify all three tools are in the flushed content
      const toolUseBlocks = flushed!.filter(b => b.type === 'tool_use');
      expect(toolUseBlocks).toHaveLength(3);
      expect(toolUseBlocks.map(b => b.id)).toEqual(['tc_1', 'tc_2', 'tc_3']);

      // Second and third tool starts - flush returns null (already flushed)
      tracker.startToolCall('tc_2', 'Read', { file_path: 'b.ts' }, '2024-01-01T00:00:02Z');
      expect(tracker.flushPreToolContent()).toBeNull();

      tracker.startToolCall('tc_3', 'Read', { file_path: 'c.ts' }, '2024-01-01T00:00:03Z');
      expect(tracker.flushPreToolContent()).toBeNull();
    });
  });

  describe('thinking support', () => {
    it('should accumulate thinking deltas', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);

      tracker.addThinkingDelta('Let me ');
      tracker.addThinkingDelta('think about this...');

      const content = tracker.getThisTurnContent();
      expect(content.thinking).toBe('Let me think about this...');
    });

    it('should preserve thinking separately from text', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);

      tracker.addThinkingDelta('Internal reasoning');
      tracker.addTextDelta('External response');

      const content = tracker.getThisTurnContent();
      expect(content.thinking).toBe('Internal reasoning');
      // Text is stored in the sequence, not a direct property
      const textItem = content.sequence.find(s => s.type === 'text');
      expect(textItem).toBeDefined();
      expect(textItem?.type === 'text' && textItem.text).toBe('External response');
    });

    it('should include thinking in turn end content', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);

      tracker.addThinkingDelta('Deep thoughts');
      tracker.addTextDelta('My answer');

      const turnContent = tracker.onTurnEnd();
      expect(turnContent.thinking).toBe('Deep thoughts');
    });

    it('should clear thinking on turn start', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);
      tracker.addThinkingDelta('Turn 1 thinking');
      tracker.onTurnEnd();

      tracker.onTurnStart(2);
      const content = tracker.getThisTurnContent();
      expect(content.thinking).toBe('');
    });

    it('should clear thinking on agent start', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);
      tracker.addThinkingDelta('Some thinking');
      tracker.onTurnEnd();

      tracker.onAgentStart();
      expect(tracker.getAccumulatedContent().thinking).toBe('');
    });

    it('should accumulate thinking across turns', () => {
      tracker.onAgentStart();

      // Turn 1
      tracker.onTurnStart(1);
      tracker.addThinkingDelta('Turn 1 thoughts');
      tracker.onTurnEnd();

      // Turn 2
      tracker.onTurnStart(2);
      tracker.addThinkingDelta('Turn 2 thoughts');
      tracker.onTurnEnd();

      const accumulated = tracker.getAccumulatedContent();
      expect(accumulated.thinking).toContain('Turn 1 thoughts');
      expect(accumulated.thinking).toContain('Turn 2 thoughts');
    });

    it('should include thinking in interrupted content', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);
      tracker.addThinkingDelta('Interrupted thinking');
      tracker.addTextDelta('Interrupted text');
      tracker.startToolCall('tc_1', 'Bash', { command: 'sleep 100' }, '2024-01-01T00:00:00Z');
      // Tool not ended - simulates interruption

      const interrupted = tracker.buildInterruptedContent();

      // Thinking should come first in the content
      expect(interrupted.assistantContent.length).toBeGreaterThan(0);
      expect(interrupted.assistantContent[0]).toMatchObject({
        type: 'thinking',
        thinking: 'Interrupted thinking',
      });
    });

    it('should handle thinking with tool calls', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);

      tracker.addThinkingDelta('Let me analyze this');
      tracker.addTextDelta('I will read the file');
      tracker.registerToolIntents([
        { id: 'tc_1', name: 'Read', arguments: { file_path: 'test.ts' } },
      ]);
      tracker.startToolCall('tc_1', 'Read', { file_path: 'test.ts' }, '2024-01-01T00:00:00Z');
      tracker.endToolCall('tc_1', 'file contents', false, '2024-01-01T00:00:01Z');

      const turnContent = tracker.onTurnEnd();
      expect(turnContent.thinking).toBe('Let me analyze this');
      expect(turnContent.sequence.length).toBeGreaterThan(0);
    });

    it('should include thinking in pre-tool flush (for session reconstruction)', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);

      tracker.addThinkingDelta('Internal reasoning');
      tracker.setThinkingSignature('sig_test123');
      tracker.addTextDelta('Let me read files');
      tracker.registerToolIntents([
        { id: 'tc_1', name: 'Read', arguments: { file_path: 'a.ts' } },
      ]);
      tracker.startToolCall('tc_1', 'Read', { file_path: 'a.ts' }, '2024-01-01T00:00:00Z');

      const flushed = tracker.flushPreToolContent();
      expect(flushed).not.toBeNull();
      expect(flushed).toHaveLength(3); // thinking + text + tool_use

      // CRITICAL: Thinking must be FIRST with signature
      expect(flushed![0]).toEqual({
        type: 'thinking',
        thinking: 'Internal reasoning',
        signature: 'sig_test123',
      });
      expect(flushed![1]).toEqual({ type: 'text', text: 'Let me read files' });
      expect(flushed![2]).toEqual({
        type: 'tool_use',
        id: 'tc_1',
        name: 'Read',
        input: { file_path: 'a.ts' },
      });
    });
  });

  describe('buildCurrentTurnInterruptedContent', () => {
    it('should only return current turn content, not previous turns', () => {
      tracker.onAgentStart();

      // Turn 1: complete
      tracker.onTurnStart(1);
      tracker.addTextDelta('Turn 1 text');
      tracker.registerToolIntents([
        { id: 'tc_t1', name: 'Read', arguments: { file_path: 'a.ts' } },
      ]);
      tracker.startToolCall('tc_t1', 'Read', { file_path: 'a.ts' }, '2024-01-01T00:00:00Z');
      tracker.endToolCall('tc_t1', 'contents of a', false, '2024-01-01T00:00:01Z');
      tracker.onTurnEnd();

      // Turn 2: complete
      tracker.onTurnStart(2);
      tracker.addTextDelta('Turn 2 text');
      tracker.registerToolIntents([
        { id: 'tc_t2', name: 'Read', arguments: { file_path: 'b.ts' } },
      ]);
      tracker.startToolCall('tc_t2', 'Read', { file_path: 'b.ts' }, '2024-01-01T00:00:02Z');
      tracker.endToolCall('tc_t2', 'contents of b', false, '2024-01-01T00:00:03Z');
      tracker.onTurnEnd();

      // Turn 3: interrupted mid-tool
      tracker.onTurnStart(3);
      tracker.addTextDelta('Turn 3 text');
      tracker.registerToolIntents([
        { id: 'tc_t3', name: 'Bash', arguments: { command: 'sleep 100' } },
      ]);
      tracker.startToolCall('tc_t3', 'Bash', { command: 'sleep 100' }, '2024-01-01T00:00:04Z');
      // Tool NOT ended — interrupted

      const result = tracker.buildCurrentTurnInterruptedContent();

      // Should only contain turn 3 content
      expect(result.assistantContent.length).toBeGreaterThan(0);
      const textBlock = result.assistantContent.find(b => b.type === 'text');
      expect(textBlock?.text).toBe('Turn 3 text');

      // Should not contain turn 1 or turn 2 tool_use blocks
      const toolUseBlocks = result.assistantContent.filter(b => b.type === 'tool_use');
      expect(toolUseBlocks).toHaveLength(1);
      expect(toolUseBlocks[0]!.id).toBe('tc_t3');

      // Should only have tool results for incomplete tools
      expect(result.toolResultContent).toHaveLength(1);
      expect(result.toolResultContent[0]!.tool_use_id).toBe('tc_t3');
    });

    it('should return empty assistantContent when preToolContent already flushed', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);
      tracker.addTextDelta('Some text');
      tracker.registerToolIntents([
        { id: 'tc_1', name: 'Read', arguments: { file_path: 'a.ts' } },
      ]);
      tracker.startToolCall('tc_1', 'Read', { file_path: 'a.ts' }, '2024-01-01T00:00:00Z');

      // Flush pre-tool content (simulates message.assistant already persisted)
      tracker.flushPreToolContent();
      expect(tracker.hasPreToolContentFlushed()).toBe(true);

      // Now interrupt
      const result = tracker.buildCurrentTurnInterruptedContent();

      // assistantContent should be empty since message.assistant was already persisted
      expect(result.assistantContent).toHaveLength(0);

      // But incomplete tool results should still be present
      expect(result.toolResultContent).toHaveLength(1);
      expect(result.toolResultContent[0]!.tool_use_id).toBe('tc_1');
    });

    it('should exclude completed tools from toolResultContent', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);
      tracker.addTextDelta('Working on it');
      tracker.registerToolIntents([
        { id: 'tc_done', name: 'Read', arguments: { file_path: 'a.ts' } },
        { id: 'tc_running', name: 'Bash', arguments: { command: 'sleep 100' } },
        { id: 'tc_pending', name: 'Write', arguments: { file_path: 'c.ts', content: 'x' } },
      ]);
      tracker.startToolCall('tc_done', 'Read', { file_path: 'a.ts' }, '2024-01-01T00:00:00Z');
      tracker.endToolCall('tc_done', 'contents', false, '2024-01-01T00:00:01Z');
      tracker.startToolCall('tc_running', 'Bash', { command: 'sleep 100' }, '2024-01-01T00:00:02Z');
      // tc_running not ended, tc_pending never started

      const result = tracker.buildCurrentTurnInterruptedContent();

      // All 3 tool_use blocks in assistantContent (since preToolContent not flushed)
      const toolUseBlocks = result.assistantContent.filter(b => b.type === 'tool_use');
      expect(toolUseBlocks).toHaveLength(3);

      // Only incomplete tools in toolResultContent
      const toolResultIds = result.toolResultContent.map(tr => tr.tool_use_id);
      expect(toolResultIds).not.toContain('tc_done');
      expect(toolResultIds).toContain('tc_running');
      expect(toolResultIds).toContain('tc_pending');
    });

    it('should return full content for first turn with no tools', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);
      tracker.addTextDelta('Just some text, no tools');

      const result = tracker.buildCurrentTurnInterruptedContent();

      expect(result.assistantContent).toHaveLength(1);
      expect(result.assistantContent[0]!.type).toBe('text');
      expect(result.assistantContent[0]!.text).toBe('Just some text, no tools');
      expect(result.toolResultContent).toHaveLength(0);
    });

    it('should return empty content between turns (empty current turn)', () => {
      tracker.onAgentStart();

      // Complete turn 1
      tracker.onTurnStart(1);
      tracker.addTextDelta('Done');
      tracker.onTurnEnd();

      // Turn 2 not started yet (or just started with no content)
      tracker.onTurnStart(2);

      const result = tracker.buildCurrentTurnInterruptedContent();

      expect(result.assistantContent).toHaveLength(0);
      expect(result.toolResultContent).toHaveLength(0);
    });

    it('should return empty when all tools in current turn completed', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);
      tracker.addTextDelta('All done');
      tracker.registerToolIntents([
        { id: 'tc_1', name: 'Read', arguments: { file_path: 'a.ts' } },
      ]);
      tracker.startToolCall('tc_1', 'Read', { file_path: 'a.ts' }, '2024-01-01T00:00:00Z');
      tracker.endToolCall('tc_1', 'contents', false, '2024-01-01T00:00:01Z');

      // Simulate pre-tool content flushed (message.assistant already persisted)
      tracker.flushPreToolContent();

      const result = tracker.buildCurrentTurnInterruptedContent();

      // message.assistant already persisted, all tools completed → nothing to persist
      expect(result.assistantContent).toHaveLength(0);
      expect(result.toolResultContent).toHaveLength(0);
    });

    it('should include thinking content in current turn', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);
      tracker.addThinkingDelta('Deep thoughts about the problem');
      tracker.setThinkingSignature('sig_abc');
      tracker.addTextDelta('Let me work on this');

      const result = tracker.buildCurrentTurnInterruptedContent();

      expect(result.assistantContent.length).toBeGreaterThanOrEqual(2);
      expect(result.assistantContent[0]!.type).toBe('thinking');
      expect(result.assistantContent[0]!.thinking).toBe('Deep thoughts about the problem');
      expect(result.assistantContent[0]!.signature).toBe('sig_abc');
    });

    it('should handle error-status tools same as completed (exclude from results)', () => {
      tracker.onAgentStart();
      tracker.onTurnStart(1);
      tracker.addTextDelta('Trying');
      tracker.registerToolIntents([
        { id: 'tc_err', name: 'Bash', arguments: { command: 'fail' } },
        { id: 'tc_run', name: 'Read', arguments: { file_path: 'x.ts' } },
      ]);
      tracker.startToolCall('tc_err', 'Bash', { command: 'fail' }, '2024-01-01T00:00:00Z');
      tracker.endToolCall('tc_err', 'command failed', true, '2024-01-01T00:00:01Z');
      tracker.startToolCall('tc_run', 'Read', { file_path: 'x.ts' }, '2024-01-01T00:00:02Z');
      // tc_run still running

      // Flush pre-tool content
      tracker.flushPreToolContent();

      const result = tracker.buildCurrentTurnInterruptedContent();

      // assistantContent empty (already flushed)
      expect(result.assistantContent).toHaveLength(0);

      // Only running tool in results (error tool already has tool.result event)
      const resultIds = result.toolResultContent.map(tr => tr.tool_use_id);
      expect(resultIds).not.toContain('tc_err');
      expect(resultIds).toContain('tc_run');
    });
  });
});
