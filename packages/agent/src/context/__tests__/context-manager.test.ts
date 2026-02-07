/**
 * @fileoverview ContextManager Tests (TDD)
 *
 * Tests written FIRST to define expected behavior.
 * Implementation follows to make these pass.
 *
 * NOTE: getCurrentTokens() returns API-reported tokens (0 if no API data).
 * Tests must call setApiContextTokens() to simulate what happens after a turn.
 * For tests using ContextSimulator, use session.estimatedTokens.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import {
  ContextManager,
  createContextManager,
  type ContextManagerConfig,
  type ThresholdLevel,
} from '../context-manager.js';
import { ContextSimulator, createContextSimulator } from '../__helpers__/context-simulator.js';
import { MockSummarizer, createMockSummarizer } from '../__helpers__/mock-summarizer.js';

/**
 * Helper to set up a context manager with simulated session and API tokens.
 * This mimics what happens after a turn completes in production.
 */
function setupWithSimulatedSession(
  cm: ContextManager,
  session: ReturnType<ContextSimulator['generateSession']>
): void {
  cm.setMessages(session.messages);
  cm.setApiContextTokens(session.estimatedTokens);
}

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
      // Gemini 2.5 Pro has 2M context window
      expect(cm.getContextLimit()).toBe(2_097_152);
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
        { name: 'read_file', description: 'Read a file', parameters: { type: 'object' as const } },
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

    it('adds messages to the context', () => {
      cm.addMessage({ role: 'user', content: 'Hello world' });
      expect(cm.getMessages()).toHaveLength(1);
    });

    it('returns estimate before API data, then API value after', () => {
      cm.addMessage({ role: 'user', content: 'Hello world' });
      // Before API reports, falls back to component estimates (> 0)
      expect(cm.getCurrentTokens()).toBeGreaterThan(0);
      // After turn completes, API reports actual tokens
      cm.setApiContextTokens(1500);
      expect(cm.getCurrentTokens()).toBe(1500);
    });

    it('returns messages array', () => {
      cm.addMessage({ role: 'user', content: 'Hello' });
      cm.addMessage({ role: 'assistant', content: [{ type: 'text', text: 'Hi!' }] });
      expect(cm.getMessages()).toHaveLength(2);
    });

    it('setMessages replaces all messages and falls back to estimates', () => {
      cm.addMessage({ role: 'user', content: 'First' });
      cm.addMessage({ role: 'user', content: 'Second' });
      cm.setApiContextTokens(5000);
      expect(cm.getMessages()).toHaveLength(2);
      expect(cm.getCurrentTokens()).toBe(5000);

      cm.setMessages([{ role: 'user', content: 'Only one' }]);
      expect(cm.getMessages()).toHaveLength(1);
      // API tokens reset after setMessages — falls back to estimate from new messages
      const tokens = cm.getCurrentTokens();
      expect(tokens).toBeGreaterThan(0);
      expect(tokens).not.toBe(5000);
    });

    it('handles complex assistant messages', () => {
      cm.addMessage({
        role: 'assistant',
        content: [
          { type: 'text', text: 'Let me help you with that.' },
          {
            type: 'tool_use',
            id: 'tool_123',
            name: 'read_file',
            arguments: { path: '/src/index.ts' },
          },
        ],
      });
      expect(cm.getMessages()).toHaveLength(1);
      // Before API data, falls back to estimates (> 0)
      expect(cm.getCurrentTokens()).toBeGreaterThan(0);
      // After API reports, uses ground truth
      cm.setApiContextTokens(2000);
      expect(cm.getCurrentTokens()).toBe(2000);
    });

    it('handles tool results', () => {
      cm.addMessage({
        role: 'toolResult',
        toolCallId: 'tool_123',
        content: 'File contents here...',
      });
      expect(cm.getMessages()).toHaveLength(1);
    });

    it('returns consistent token count from API', () => {
      cm.addMessage({ role: 'user', content: 'Test message' });
      cm.setApiContextTokens(1000);

      // Multiple calls should return same API value
      const first = cm.getCurrentTokens();
      const second = cm.getCurrentTokens();
      expect(second).toBe(first);
      expect(first).toBe(1000);
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
    it('returns current token usage from API', () => {
      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      cm.addMessage({ role: 'user', content: 'Hello' });
      cm.setApiContextTokens(5000); // Simulate API reporting 5k tokens

      const snapshot = cm.getSnapshot();

      expect(snapshot.currentTokens).toBe(5000);
      expect(snapshot.contextLimit).toBe(200_000);
      expect(snapshot.usagePercent).toBe(5000 / 200_000);
    });

    it('includes breakdown of token usage when API data available', () => {
      const cm = createContextManager({
        model: 'claude-sonnet-4-20250514',
        systemPrompt: 'You are a helpful assistant.',
        tools: [{ name: 'test', description: 'A test tool', parameters: { type: 'object' as const } }],
      });
      cm.addMessage({ role: 'user', content: 'Hello' });
      cm.setApiContextTokens(5000); // Simulate API reporting tokens

      const snapshot = cm.getSnapshot();

      expect(snapshot.breakdown).toBeDefined();
      expect(snapshot.breakdown.systemPrompt).toBeGreaterThan(0);
      expect(snapshot.breakdown.tools).toBeGreaterThan(0);
      expect(snapshot.breakdown.messages).toBeGreaterThan(0);
    });

    it('returns estimated currentTokens from components before first turn', () => {
      const cm = createContextManager({
        model: 'claude-sonnet-4-20250514',
        systemPrompt: 'You are a helpful assistant.',
        tools: [
          {
            name: 'test_tool',
            description: 'A test tool for unit tests',
            parameters: { type: 'object' as const, properties: {} },
          },
        ],
      });
      cm.addMessage({ role: 'user', content: 'Hello' });

      const snapshot = cm.getSnapshot();

      // Before API data, currentTokens is sum of component estimates (not 0)
      expect(snapshot.currentTokens).toBeGreaterThan(0);
      expect(snapshot.breakdown.systemPrompt).toBeGreaterThan(0);
      expect(snapshot.breakdown.tools).toBeGreaterThan(0);
      expect(snapshot.breakdown.messages).toBeGreaterThan(0);
      // currentTokens should be at least the sum of breakdowns
      const breakdownSum = snapshot.breakdown.systemPrompt + snapshot.breakdown.tools + snapshot.breakdown.messages;
      expect(snapshot.currentTokens).toBeGreaterThanOrEqual(breakdownSum);
    });

    it('returns normal threshold for low usage', () => {
      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      cm.addMessage({ role: 'user', content: 'Hello' });
      cm.setApiContextTokens(10000); // 5% of 200k

      const snapshot = cm.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('normal');
    });

    it('returns warning threshold at 50-70%', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(60, 200_000);

      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      setupWithSimulatedSession(cm, session);

      const snapshot = cm.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('warning');
    });

    it('returns alert threshold at 70-85%', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);

      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      setupWithSimulatedSession(cm, session);

      const snapshot = cm.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('alert');
    });

    it('returns critical threshold at 85-95%', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(90, 200_000);

      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      setupWithSimulatedSession(cm, session);

      const snapshot = cm.getSnapshot();
      expect(snapshot.thresholdLevel).toBe('critical');
    });

    it('returns exceeded threshold above 95%', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(98, 200_000);

      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      setupWithSimulatedSession(cm, session);

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
      cm.setApiContextTokens(5000); // Low usage

      const validation = cm.canAcceptTurn({ estimatedResponseTokens: 4000 });

      expect(validation.canProceed).toBe(true);
      expect(validation.needsCompaction).toBe(false);
      expect(validation.wouldExceedLimit).toBe(false);
    });

    it('allows turn but signals compaction at alert level', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);

      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      setupWithSimulatedSession(cm, session);

      const validation = cm.canAcceptTurn({ estimatedResponseTokens: 4000 });

      expect(validation.canProceed).toBe(true);
      expect(validation.needsCompaction).toBe(true);
    });

    it('blocks turn at critical level', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(92, 200_000);

      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      setupWithSimulatedSession(cm, session);

      const validation = cm.canAcceptTurn({ estimatedResponseTokens: 4000 });

      expect(validation.canProceed).toBe(false);
      expect(validation.needsCompaction).toBe(true);
    });

    it('detects when turn would exceed limit', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(95, 200_000);

      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      setupWithSimulatedSession(cm, session);

      const validation = cm.canAcceptTurn({ estimatedResponseTokens: 20000 });

      expect(validation.wouldExceedLimit).toBe(true);
    });

    it('returns token details in validation', () => {
      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      cm.addMessage({ role: 'user', content: 'Hello' });
      cm.setApiContextTokens(10000);

      const validation = cm.canAcceptTurn({ estimatedResponseTokens: 4000 });

      expect(validation.currentTokens).toBe(10000);
      expect(validation.estimatedAfterTurn).toBe(14000);
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

      // Use empty systemPrompt to avoid loading from project .tron/SYSTEM.md
      const cm = createContextManager({ model: 'claude-sonnet-4-20250514', systemPrompt: '' });
      setupWithSimulatedSession(cm, session);

      // At 75% of 200k, should be "alert"
      expect(cm.getSnapshot().thresholdLevel).toBe('alert');

      // Switch to GPT-4o (128k limit)
      // 150k tokens = 117% of 128k = exceeded
      cm.switchModel('gpt-4o');

      expect(cm.getSnapshot().thresholdLevel).toBe('exceeded');
    });

    it('improves threshold after switch to larger model', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      // 88% of 128k = ~113k tokens (use 88% to stay safely in critical zone)
      const session = simulator.generateAtUtilization(88, 128_000);

      // Use empty systemPrompt to avoid loading from project .tron/SYSTEM.md
      const cm = createContextManager({ model: 'gpt-4o', systemPrompt: '' });
      setupWithSimulatedSession(cm, session);

      // At 88% of 128k, should be "critical" (85-95%)
      expect(cm.getSnapshot().thresholdLevel).toBe('critical');

      // Switch to Gemini (1M limit)
      // 115k tokens = 11.5% of 1M = normal
      cm.switchModel('gemini-2.5-pro');

      expect(cm.getSnapshot().thresholdLevel).toBe('normal');
    });

    it('triggers callback when compaction needed after switch', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(75, 200_000);

      // Use empty systemPrompt to avoid loading from project .tron/SYSTEM.md
      const cm = createContextManager({ model: 'claude-sonnet-4-20250514', systemPrompt: '' });
      setupWithSimulatedSession(cm, session);

      const callback = vi.fn();
      cm.onCompactionNeeded(callback);

      // Switch to smaller model - should trigger callback
      cm.switchModel('gpt-4o');

      expect(callback).toHaveBeenCalled();
    });

    it('does not trigger callback if context is fine after switch', () => {
      const cm = createContextManager({ model: 'gpt-4o' });
      cm.addMessage({ role: 'user', content: 'Hello' });
      cm.setApiContextTokens(5000); // Low usage

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
      setupWithSimulatedSession(cm, session);

      // With very tight budget, max tool result size should be smaller than the cap
      const maxSize = cm.getMaxToolResultSize();
      expect(maxSize).toBeLessThan(100_000);
    });

    it('returns minimum result size even when very tight', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(98, 200_000);

      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      setupWithSimulatedSession(cm, session);

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
      setupWithSimulatedSession(cm, session);

      expect(cm.shouldCompact()).toBe(false);
    });

    it('needs compaction above default threshold (70%)', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(75, 200_000);

      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      setupWithSimulatedSession(cm, session);

      expect(cm.shouldCompact()).toBe(true);
    });

    it('respects custom threshold', () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(60, 200_000);

      const cm = createContextManager({
        model: 'claude-sonnet-4-20250514',
        compaction: { threshold: 0.50 }, // 50% threshold
      });
      setupWithSimulatedSession(cm, session);

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
      setupWithSimulatedSession(cm, session);

      const originalTokens = cm.getCurrentTokens();
      const originalCount = cm.getMessages().length;

      const preview = await cm.previewCompaction({ summarizer: mockSummarizer });

      // State should be unchanged
      expect(cm.getCurrentTokens()).toBe(originalTokens);
      expect(cm.getMessages().length).toBe(originalCount);

      // Preview reports messages-only tokens (excludes system prompt + tools overhead)
      const snapshot = cm.getSnapshot();
      const expectedMessageTokens = originalTokens - snapshot.breakdown.systemPrompt - snapshot.breakdown.tools;
      expect(preview.tokensBefore).toBe(expectedMessageTokens);
      expect(preview.tokensAfter).toBeLessThan(expectedMessageTokens);
    });

    it('returns compression ratio in preview', async () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);
      setupWithSimulatedSession(cm, session);

      const preview = await cm.previewCompaction({ summarizer: mockSummarizer });

      expect(preview.compressionRatio).toBeGreaterThan(0);
      expect(preview.compressionRatio).toBeLessThan(1);
    });

    it('shows preserved and summarized turn counts', async () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);
      setupWithSimulatedSession(cm, session);

      const preview = await cm.previewCompaction({ summarizer: mockSummarizer });

      expect(preview.preservedTurns).toBe(3);
      expect(preview.summarizedTurns).toBeGreaterThan(0);
    });

    it('includes generated summary in preview', async () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);
      setupWithSimulatedSession(cm, session);

      const preview = await cm.previewCompaction({ summarizer: mockSummarizer });

      expect(preview.summary).toBeDefined();
      expect(preview.summary.length).toBeGreaterThan(0);
    });

    it('includes extracted data in preview', async () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);
      setupWithSimulatedSession(cm, session);

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
      setupWithSimulatedSession(cm, session);

      // tokensBefore/tokensAfter report messages-only (excludes system + tools overhead)
      const snapshot = cm.getSnapshot();
      const messageTokensBefore = cm.getCurrentTokens() - snapshot.breakdown.systemPrompt - snapshot.breakdown.tools;
      const result = await cm.executeCompaction({ summarizer: mockSummarizer });

      expect(result.success).toBe(true);
      expect(result.tokensBefore).toBe(messageTokensBefore);
      expect(result.tokensAfter).toBeLessThan(messageTokensBefore);
    });

    it('preserves recent turns', async () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);
      setupWithSimulatedSession(cm, session);

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
      setupWithSimulatedSession(cm, session);

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
      setupWithSimulatedSession(cm, session);

      await cm.executeCompaction({ summarizer: mockSummarizer });

      const messages = cm.getMessages();
      const secondMessage = messages[1];

      expect(secondMessage.role).toBe('assistant');
    });

    it('supports custom edited summary', async () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);
      setupWithSimulatedSession(cm, session);

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
      setupWithSimulatedSession(cm, session);

      const result = await cm.executeCompaction({ summarizer: mockSummarizer });

      // tokensAfter is an estimate based on preserved messages + summary
      // since API tokens won't be available until next turn completes
      expect(result.tokensAfter).toBeGreaterThan(0);
      expect(result.tokensAfter).toBeLessThan(result.tokensBefore);
      expect(result.tokensBefore).toBeGreaterThan(0);
      // Compression ratio = tokensAfter / tokensBefore (should be < 1)
      expect(result.compressionRatio).toBeGreaterThan(0);
      expect(result.compressionRatio).toBeLessThan(1);
    });

    it('returns extracted data in result', async () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);
      setupWithSimulatedSession(cm, session);

      const result = await cm.executeCompaction({ summarizer: mockSummarizer });

      expect(result.extractedData).toBeDefined();
    });

    it('falls back to estimates after compaction, then uses API on next turn', async () => {
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);
      setupWithSimulatedSession(cm, session);

      const tokensBefore = cm.getCurrentTokens();
      await cm.executeCompaction({ summarizer: mockSummarizer });

      // After compaction, API tokens are reset — falls back to component estimates
      // reflecting the compacted (smaller) message set
      const estimateAfter = cm.getCurrentTokens();
      expect(estimateAfter).toBeGreaterThan(0);
      expect(estimateAfter).toBeLessThan(tokensBefore);

      // Simulate next turn reporting reduced tokens (API ground truth)
      cm.setApiContextTokens(50000);
      expect(cm.getCurrentTokens()).toBe(50000);
      expect(cm.getCurrentTokens()).toBeLessThan(tokensBefore);
    });
  });

  // ===========================================================================
  // Edge Cases
  // ===========================================================================

  describe('Edge Cases', () => {
    it('handles empty messages gracefully', () => {
      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });

      // Before any API data, falls back to estimates (system prompt + tools, no messages)
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
      cm.setApiContextTokens(100); // Small token count

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
      // Before API data, returns estimate (system prompt overhead at minimum)
      expect(cm.getCurrentTokens()).toBeGreaterThanOrEqual(0);
    });

    it('handles concurrent calls to getCurrentTokens', () => {
      const cm = createContextManager({ model: 'claude-sonnet-4-20250514' });
      cm.addMessage({ role: 'user', content: 'Hello' });
      cm.setApiContextTokens(1500);

      // Multiple rapid calls should all return same API value
      const results = Array.from({ length: 10 }, () => cm.getCurrentTokens());
      const unique = new Set(results);

      expect(unique.size).toBe(1);
      expect(results[0]).toBe(1500);
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
