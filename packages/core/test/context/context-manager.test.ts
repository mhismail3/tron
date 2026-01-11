/**
 * @fileoverview ContextManager Tests (TDD)
 *
 * Tests written FIRST to define expected behavior.
 * Implementation follows to make these pass.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import {
  ContextManager,
  createContextManager,
  type ContextManagerConfig,
  type ThresholdLevel,
} from '../../src/context/context-manager.js';
import { ContextSimulator, createContextSimulator } from './context-simulator.js';
import { MockSummarizer, createMockSummarizer } from './mock-summarizer.js';

// =============================================================================
// Construction Tests
// =============================================================================

describe('ContextManager', () => {
  describe('Construction', () => {
    it('initializes with correct Claude context limit', () => {
      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      expect(cm.getContextLimit()).toBe(200_000);
    });

    it('initializes with GPT-4o context limit', () => {
      const cm = createContextManager({ model: 'gpt-4o' });
      expect(cm.getContextLimit()).toBe(128_000);
    });

    it('initializes with Gemini context limit', () => {
      const cm = createContextManager({ model: 'gemini-2.5-pro' });
      expect(cm.getContextLimit()).toBe(1_000_000);
    });

    it('starts with empty messages', () => {
      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      expect(cm.getMessages()).toHaveLength(0);
    });

    it('accepts initial system prompt', () => {
      const cm = createContextManager({
        model: 'claude-sonnet-4-20250514',
        systemPrompt: 'You are a helpful assistant.',
      });
      // getRawSystemPrompt returns the exact input
      expect(cm.getRawSystemPrompt()).toBe('You are a helpful assistant.');
      // getSystemPrompt returns the provider-built prompt with working directory
      expect(cm.getSystemPrompt()).toContain('You are a helpful assistant.');
    });

    it('accepts initial tools', () => {
      const tools = [
        { name: 'read_file', description: 'Read a file', inputSchema: { type: 'object' } },
      ];
      const cm = createContextManager({
        model: 'claude-sonnet-4-20250514',
        tools,
      });
      expect(cm.getTools()).toHaveLength(1);
    });
  });

  // ===========================================================================
  // Message Management
  // ===========================================================================

  describe('Message Management', () => {
    let cm: ContextManager;

    beforeEach(() => {
      cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
    });

    it('adds messages and updates token count', () => {
      const before = cm.getCurrentTokens();
      cm.addMessage({ role: 'user', content: 'Hello world' });
      expect(cm.getCurrentTokens()).toBeGreaterThan(before);
    });

    it('returns messages array', () => {
      cm.addMessage({ role: 'user', content: 'Hello' });
      cm.addMessage({ role: 'assistant', content: [{ type: 'text', text: 'Hi!' }] });
      expect(cm.getMessages()).toHaveLength(2);
    });

    it('setMessages replaces all messages', () => {
      cm.addMessage({ role: 'user', content: 'First' });
      cm.addMessage({ role: 'user', content: 'Second' });
      expect(cm.getMessages()).toHaveLength(2);

      cm.setMessages([{ role: 'user', content: 'Only one' }]);
      expect(cm.getMessages()).toHaveLength(1);
    });

    it('tracks tokens for complex assistant messages', () => {
      const before = cm.getCurrentTokens();
      cm.addMessage({
        role: 'assistant',
        content: [
          { type: 'text', text: 'Let me help you with that.' },
          {
            type: 'tool_use',
            id: 'tool_123',
            name: 'read_file',
            input: { path: '/src/index.ts' },
          },
        ],
      });
      expect(cm.getCurrentTokens()).toBeGreaterThan(before);
    });

    it('tracks tokens for tool results', () => {
      const before = cm.getCurrentTokens();
      cm.addMessage({
        role: 'user',
        content: [
          {
            type: 'tool_result',
            tool_use_id: 'tool_123',
            content: 'File contents here...',
          },
        ],
      });
      expect(cm.getCurrentTokens()).toBeGreaterThan(before);
    });

    it('caches token estimates for performance', () => {
      const msg = { role: 'user' as const, content: 'Test message' };
      cm.addMessage(msg);

      // Multiple calls should use cached value
      const first = cm.getCurrentTokens();
      const second = cm.getCurrentTokens();
      expect(second).toBe(first);
    });

    it('returns defensive copy of messages', () => {
      cm.addMessage({ role: 'user', content: 'Hello' });
      const messages = cm.getMessages();
      messages.push({ role: 'user', content: 'Injected' });

      // Original should be unaffected
      expect(cm.getMessages()).toHaveLength(1);
    });
  });

  // ===========================================================================
  // Snapshot
  // ===========================================================================

  describe('Snapshot', () => {
    it('returns current token usage', () => {
      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      cm.addMessage({ role: 'user', content: 'Hello' });

      const snapshot = cm.getSnapshot();

      expect(snapshot.currentTokens).toBeGreaterThan(0);
      expect(snapshot.contextLimit).toBe(200_000);
      expect(snapshot.usagePercent).toBeGreaterThan(0);
      expect(snapshot.usagePercent).toBeLessThan(0.01); // Very low for simple message
    });

    it('includes breakdown of token usage', () => {
      const cm = createContextManager({
        model: 'claude-sonnet-4-20250514',
        systemPrompt: 'You are a helpful assistant.',
        tools: [{ name: 'test', description: 'A test tool', inputSchema: { type: 'object' } }],
      });
      cm.addMessage({ role: 'user', content: 'Hello' });

      const snapshot = cm.getSnapshot();

      expect(snapshot.breakdown).toBeDefined();
      expect(snapshot.breakdown.systemPrompt).toBeGreaterThan(0);
      expect(snapshot.breakdown.tools).toBeGreaterThan(0);
      expect(snapshot.breakdown.messages).toBeGreaterThan(0);
    });

    it('returns normal threshold for low usage', () => {
      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      cm.addMessage({ role: 'user', content: 'Hello' });

      const snapshot = cm.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('normal');
    });

    it('returns warning threshold at 50-70%', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(60, 200_000);

      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      cm.setMessages(session.messages);

      const snapshot = cm.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('warning');
    });

    it('returns alert threshold at 70-85%', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);

      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      cm.setMessages(session.messages);

      const snapshot = cm.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('alert');
    });

    it('returns critical threshold at 85-95%', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(90, 200_000);

      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      cm.setMessages(session.messages);

      const snapshot = cm.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('critical');
    });

    it('returns exceeded threshold above 95%', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(98, 200_000);

      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      cm.setMessages(session.messages);

      const snapshot = cm.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('exceeded');
    });
  });

  // ===========================================================================
  // Pre-Turn Validation
  // ===========================================================================

  describe('Pre-Turn Validation', () => {
    it('allows turn when context is low', () => {
      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      cm.addMessage({ role: 'user', content: 'Short message' });

      const validation = cm.canAcceptTurn({ estimatedResponseTokens: 4000 });

      expect(validation.canProceed).toBe(true);
      expect(validation.needsCompaction).toBe(false);
      expect(validation.wouldExceedLimit).toBe(false);
    });

    it('allows turn but signals compaction at alert level', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);

      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      cm.setMessages(session.messages);

      const validation = cm.canAcceptTurn({ estimatedResponseTokens: 4000 });

      expect(validation.canProceed).toBe(true);
      expect(validation.needsCompaction).toBe(true);
    });

    it('blocks turn at critical level', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(92, 200_000);

      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      cm.setMessages(session.messages);

      const validation = cm.canAcceptTurn({ estimatedResponseTokens: 4000 });

      expect(validation.canProceed).toBe(false);
      expect(validation.needsCompaction).toBe(true);
    });

    it('detects when turn would exceed limit', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(95, 200_000);

      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      cm.setMessages(session.messages);

      const validation = cm.canAcceptTurn({ estimatedResponseTokens: 20000 });

      expect(validation.wouldExceedLimit).toBe(true);
    });

    it('returns token details in validation', () => {
      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      cm.addMessage({ role: 'user', content: 'Hello' });

      const validation = cm.canAcceptTurn({ estimatedResponseTokens: 4000 });

      expect(validation.currentTokens).toBeGreaterThan(0);
      expect(validation.estimatedAfterTurn).toBeGreaterThan(validation.currentTokens);
      expect(validation.contextLimit).toBe(200_000);
    });
  });

  // ===========================================================================
  // Model Switching
  // ===========================================================================

  describe('Model Switching', () => {
    it('updates context limit on model switch', () => {
      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      expect(cm.getContextLimit()).toBe(200_000);

      cm.switchModel('gpt-4o');

      expect(cm.getContextLimit()).toBe(128_000);
      expect(cm.getModel()).toBe('gpt-4o');
    });

    it('revalidates threshold after switch to smaller model', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      // 75% of 200k = 150k tokens
      const session = simulator.generateAtUtilization(75, 200_000);

      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      cm.setMessages(session.messages);

      // At 75% of 200k, should be "alert"
      expect(cm.getSnapshot().thresholdLevel).toBe('alert');

      // Switch to GPT-4o (128k limit)
      // 150k tokens = 117% of 128k = exceeded
      cm.switchModel('gpt-4o');

      expect(cm.getSnapshot().thresholdLevel).toBe('exceeded');
    });

    it('improves threshold after switch to larger model', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      // 90% of 128k = ~115k tokens
      const session = simulator.generateAtUtilization(90, 128_000);

      const cm = createContextManager({ model: 'gpt-4o' });
      cm.setMessages(session.messages);

      // At 90% of 128k, should be "critical"
      expect(cm.getSnapshot().thresholdLevel).toBe('critical');

      // Switch to Gemini (1M limit)
      // 115k tokens = 11.5% of 1M = normal
      cm.switchModel('gemini-2.5-pro');

      expect(cm.getSnapshot().thresholdLevel).toBe('normal');
    });

    it('triggers callback when compaction needed after switch', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(75, 200_000);

      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      cm.setMessages(session.messages);

      const callback = vi.fn();
      cm.onCompactionNeeded(callback);

      // Switch to smaller model - should trigger callback
      cm.switchModel('gpt-4o');

      expect(callback).toHaveBeenCalled();
    });

    it('does not trigger callback if context is fine after switch', () => {
      const cm = createContextManager({ model: 'gpt-4o' });
      cm.addMessage({ role: 'user', content: 'Hello' });

      const callback = vi.fn();
      cm.onCompactionNeeded(callback);

      // Switch to larger model - should NOT trigger
      cm.switchModel('gemini-2.5-pro');

      expect(callback).not.toHaveBeenCalled();
    });
  });

  // ===========================================================================
  // Tool Result Processing
  // ===========================================================================

  describe('Tool Result Processing', () => {
    it('preserves small tool results', () => {
      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      const smallResult = 'Small output';

      const processed = cm.processToolResult({
        toolCallId: 'test',
        content: smallResult,
      });

      expect(processed.content).toBe(smallResult);
      expect(processed.truncated).toBe(false);
    });

    it('truncates large tool results', () => {
      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      // Use 150k chars to exceed the 100k char cap
      const largeResult = 'x'.repeat(150_000);

      const processed = cm.processToolResult({
        toolCallId: 'test',
        content: largeResult,
      });

      expect(processed.content.length).toBeLessThan(largeResult.length);
      expect(processed.truncated).toBe(true);
      expect(processed.originalSize).toBe(largeResult.length);
    });

    it('adds truncation marker when truncating', () => {
      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      // Use 150k chars to exceed the 100k char cap
      const largeResult = 'x'.repeat(150_000);

      const processed = cm.processToolResult({
        toolCallId: 'test',
        content: largeResult,
      });

      expect(processed.content).toContain('[truncated]');
    });

    it('adapts truncation based on remaining budget', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      // At 95% utilization, budget should be very tight
      const session = simulator.generateAtUtilization(95, 200_000);

      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      cm.setMessages(session.messages);

      // With very tight budget, max tool result size should be smaller than the cap
      const maxSize = cm.getMaxToolResultSize();
      expect(maxSize).toBeLessThan(100_000);
    });

    it('returns minimum result size even when very tight', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(98, 200_000);

      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      cm.setMessages(session.messages);

      // Should always allow at least some output
      const maxSize = cm.getMaxToolResultSize();
      expect(maxSize).toBeGreaterThan(1000);
    });
  });

  // ===========================================================================
  // Compaction Detection
  // ===========================================================================

  describe('Compaction Detection', () => {
    it('does not need compaction below threshold', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(50, 200_000);

      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      cm.setMessages(session.messages);

      expect(cm.shouldCompact()).toBe(false);
    });

    it('needs compaction above default threshold (70%)', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(75, 200_000);

      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      cm.setMessages(session.messages);

      expect(cm.shouldCompact()).toBe(true);
    });

    it('respects custom threshold', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(60, 200_000);

      const cm = createContextManager({
        model: 'claude-sonnet-4-20250514',
        compaction: { threshold: 0.50 }, // 50% threshold
      });
      cm.setMessages(session.messages);

      expect(cm.shouldCompact()).toBe(true);
    });
  });

  // ===========================================================================
  // Compaction Preview
  // ===========================================================================

  describe('Compaction Preview', () => {
    let cm: ContextManager;
    let mockSummarizer: MockSummarizer;

    beforeEach(() => {
      cm = createContextManager({
        model: 'claude-sonnet-4-20250514',
        compaction: {
          threshold: 0.70,
          preserveRecentTurns: 3,
        },
      });
      mockSummarizer = createMockSummarizer();
    });

    it('generates preview without modifying state', async () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);
      cm.setMessages(session.messages);

      const originalTokens = cm.getCurrentTokens();
      const originalCount = cm.getMessages().length;

      const preview = await cm.previewCompaction({ summarizer: mockSummarizer });

      // State should be unchanged
      expect(cm.getCurrentTokens()).toBe(originalTokens);
      expect(cm.getMessages().length).toBe(originalCount);

      // Preview should show reduction
      expect(preview.tokensBefore).toBe(originalTokens);
      expect(preview.tokensAfter).toBeLessThan(originalTokens);
    });

    it('returns compression ratio in preview', async () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);
      cm.setMessages(session.messages);

      const preview = await cm.previewCompaction({ summarizer: mockSummarizer });

      expect(preview.compressionRatio).toBeGreaterThan(0);
      expect(preview.compressionRatio).toBeLessThan(1);
    });

    it('shows preserved and summarized turn counts', async () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);
      cm.setMessages(session.messages);

      const preview = await cm.previewCompaction({ summarizer: mockSummarizer });

      expect(preview.preservedTurns).toBe(3);
      expect(preview.summarizedTurns).toBeGreaterThan(0);
    });

    it('includes generated summary in preview', async () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);
      cm.setMessages(session.messages);

      const preview = await cm.previewCompaction({ summarizer: mockSummarizer });

      expect(preview.summary).toBeDefined();
      expect(preview.summary.length).toBeGreaterThan(0);
    });

    it('includes extracted data in preview', async () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);
      cm.setMessages(session.messages);

      const preview = await cm.previewCompaction({ summarizer: mockSummarizer });

      expect(preview.extractedData).toBeDefined();
      expect(preview.extractedData!.currentGoal).toBeDefined();
    });
  });

  // ===========================================================================
  // Compaction Execution
  // ===========================================================================

  describe('Compaction Execution', () => {
    let cm: ContextManager;
    let mockSummarizer: MockSummarizer;

    beforeEach(() => {
      cm = createContextManager({
        model: 'claude-sonnet-4-20250514',
        compaction: {
          threshold: 0.70,
          preserveRecentTurns: 3,
        },
      });
      mockSummarizer = createMockSummarizer();
    });

    it('executes compaction and reduces tokens', async () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);
      cm.setMessages(session.messages);

      const tokensBefore = cm.getCurrentTokens();
      const result = await cm.executeCompaction({ summarizer: mockSummarizer });

      expect(result.success).toBe(true);
      expect(result.tokensBefore).toBe(tokensBefore);
      expect(result.tokensAfter).toBeLessThan(tokensBefore);
      expect(cm.getCurrentTokens()).toBe(result.tokensAfter);
    });

    it('preserves recent turns', async () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);
      cm.setMessages(session.messages);

      // Get last 6 messages (3 turns)
      const originalMessages = cm.getMessages();
      const lastMessages = originalMessages.slice(-6);

      await cm.executeCompaction({ summarizer: mockSummarizer });

      const currentMessages = cm.getMessages();
      // Should have context message + ack + preserved messages
      const preservedSection = currentMessages.slice(-6);

      // Content should match (deep comparison)
      expect(JSON.stringify(preservedSection)).toBe(JSON.stringify(lastMessages));
    });

    it('adds context summary message at start', async () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);
      cm.setMessages(session.messages);

      await cm.executeCompaction({ summarizer: mockSummarizer });

      const messages = cm.getMessages();
      const firstMessage = messages[0];

      expect(firstMessage.role).toBe('user');
      expect(typeof firstMessage.content).toBe('string');
      expect(firstMessage.content).toContain('[Context from earlier');
    });

    it('adds assistant acknowledgment after context', async () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);
      cm.setMessages(session.messages);

      await cm.executeCompaction({ summarizer: mockSummarizer });

      const messages = cm.getMessages();
      const secondMessage = messages[1];

      expect(secondMessage.role).toBe('assistant');
    });

    it('supports custom edited summary', async () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);
      cm.setMessages(session.messages);

      const customSummary = 'User-edited custom summary for testing purposes.';
      await cm.executeCompaction({
        summarizer: mockSummarizer,
        editedSummary: customSummary,
      });

      const messages = cm.getMessages();
      expect(messages[0].content).toContain(customSummary);
    });

    it('returns compression ratio in result', async () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);
      cm.setMessages(session.messages);

      const result = await cm.executeCompaction({ summarizer: mockSummarizer });

      expect(result.compressionRatio).toBeGreaterThan(0);
      expect(result.compressionRatio).toBeLessThan(1);
      expect(result.compressionRatio).toBe(result.tokensAfter / result.tokensBefore);
    });

    it('returns extracted data in result', async () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);
      cm.setMessages(session.messages);

      const result = await cm.executeCompaction({ summarizer: mockSummarizer });

      expect(result.extractedData).toBeDefined();
    });

    it('clears token cache after compaction', async () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);
      cm.setMessages(session.messages);

      const tokensBefore = cm.getCurrentTokens();
      await cm.executeCompaction({ summarizer: mockSummarizer });

      // Tokens should be different and cache should be recalculated
      const tokensAfter = cm.getCurrentTokens();
      expect(tokensAfter).toBeLessThan(tokensBefore);
      expect(tokensAfter).not.toBe(tokensBefore);
    });
  });

  // ===========================================================================
  // Edge Cases
  // ===========================================================================

  describe('Edge Cases', () => {
    it('handles empty messages gracefully', () => {
      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });

      expect(cm.getCurrentTokens()).toBeGreaterThanOrEqual(0);
      expect(cm.getMessages()).toHaveLength(0);
      expect(cm.shouldCompact()).toBe(false);
    });

    it('handles very small message counts', async () => {
      const cm = createContextManager({
        model: 'claude-sonnet-4-20250514',
        compaction: { preserveRecentTurns: 3 },
      });
      cm.addMessage({ role: 'user', content: 'Hello' });
      cm.addMessage({ role: 'assistant', content: [{ type: 'text', text: 'Hi' }] });

      // With only 1 turn (2 messages), compaction should preserve all
      const preview = await cm.previewCompaction({
        summarizer: createMockSummarizer(),
      });

      expect(preview.summarizedTurns).toBe(0);
    });

    it('handles unknown model with default limit', () => {
      const cm = createContextManager({ model: 'unknown-model-xyz' });
      // Should default to Claude limit
      expect(cm.getContextLimit()).toBe(200_000);
    });

    it('handles messages with empty content', () => {
      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      cm.addMessage({ role: 'user', content: '' });

      expect(cm.getMessages()).toHaveLength(1);
      expect(cm.getCurrentTokens()).toBeGreaterThan(0); // At least role overhead
    });

    it('handles concurrent calls to getCurrentTokens', () => {
      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      cm.addMessage({ role: 'user', content: 'Hello' });

      // Multiple rapid calls should all return same cached value
      const results = Array.from({ length: 10 }, () => cm.getCurrentTokens());
      const unique = new Set(results);

      expect(unique.size).toBe(1);
    });
  });

  // ===========================================================================
  // Serialization (for persistence)
  // ===========================================================================

  describe('Serialization', () => {
    it('exports state for persistence', () => {
      const cm = createContextManager({
        model: 'claude-sonnet-4-20250514',
        systemPrompt: 'Be helpful',
      });
      cm.addMessage({ role: 'user', content: 'Hello' });

      const state = cm.exportState();

      expect(state.model).toBe('claude-sonnet-4-20250514');
      // exportState includes the provider-built prompt with working directory
      expect(state.systemPrompt).toContain('Be helpful');
      expect(state.messages).toHaveLength(1);
    });

    it('restores from exported state', () => {
      const original = createContextManager({
        model: 'claude-sonnet-4-20250514',
        systemPrompt: 'Be helpful',
      });
      original.addMessage({ role: 'user', content: 'Hello' });

      const state = original.exportState();

      const restored = createContextManager({
        model: state.model,
        systemPrompt: state.systemPrompt,
      });
      restored.setMessages(state.messages);

      expect(restored.getModel()).toBe(original.getModel());
      // Both should contain the same base prompt
      expect(restored.getSystemPrompt()).toContain('Be helpful');
      expect(original.getSystemPrompt()).toContain('Be helpful');
      expect(restored.getMessages()).toHaveLength(1);
    });
  });
});
