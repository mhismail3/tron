/**
 * @fileoverview Tests for TurnContentTracker
 *
 * Tests the tool intent batching and pre-tool content flush behavior
 * that enables linear event ordering.
 */
import { describe, it, expect, beforeEach } from 'vitest';
import { TurnContentTracker } from '../../src/orchestrator/turn-content-tracker.js';

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
});
