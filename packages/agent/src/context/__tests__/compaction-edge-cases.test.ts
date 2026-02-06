/**
 * @fileoverview Compaction Edge Cases Tests
 *
 * Tests edge cases and boundary conditions for compaction:
 * - Empty/minimal context
 * - Custom preserveRecentTurns values
 * - Model switching
 * - Summarizer failures
 * - User-edited summaries
 */

import { describe, it, expect, beforeEach } from 'vitest';
import {
  CompactionTestHarness,
  FailingSummarizer,
  SlowSummarizer,
} from '../__helpers__/compaction-test-harness.js';
import { PreciseTokenGenerator } from '../__helpers__/precise-token-generator.js';
import { MockSummarizer } from '../__helpers__/mock-summarizer.js';
import {
  createContextManager,
  type ContextManagerConfig,
} from '../context-manager.js';
import type { Message } from '../../types/index.js';

// =============================================================================
// Constants
// =============================================================================

const CONTEXT_LIMIT = 200_000;
const DEFAULT_PRESERVE_TURNS = 5; // 5 turns = 10 messages

// =============================================================================
// Edge Cases Tests
// =============================================================================

describe('Compaction Edge Cases', () => {
  describe('empty/minimal context', () => {
    it('compaction with 0 messages preserves empty state', async () => {
      const contextManager = createContextManager({
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test',
      });

      // No messages added
      expect(contextManager.getMessages().length).toBe(0);

      const summarizer = new MockSummarizer();
      const result = await contextManager.executeCompaction({ summarizer });

      // Should complete successfully but with minimal effect
      expect(result.success).toBe(true);
      // After compaction of empty: 2 messages (summary + ack)
      expect(contextManager.getMessages().length).toBe(2);
    });

    it('compaction with 1 message preserves it', async () => {
      const contextManager = createContextManager({
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test',
      });

      contextManager.addMessage({
        role: 'user',
        content: 'Hello',
      });

      const summarizer = new MockSummarizer();
      const result = await contextManager.executeCompaction({ summarizer });

      expect(result.success).toBe(true);
      const messages = contextManager.getMessages();

      // Should have: summary + ack + original message
      expect(messages.length).toBeGreaterThanOrEqual(2);
    });

    it('compaction with fewer messages than preserveRecentTurns preserves all', async () => {
      const contextManager = createContextManager({
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test',
        compaction: {
          preserveRecentTurns: 5, // 5 turns = 10 messages
        },
      });

      // Add only 4 messages (2 turns)
      const messages: Message[] = [
        { role: 'user', content: 'Message 1' },
        { role: 'assistant', content: [{ type: 'text', text: 'Response 1' }] },
        { role: 'user', content: 'Message 2' },
        { role: 'assistant', content: [{ type: 'text', text: 'Response 2' }] },
      ];
      contextManager.setMessages(messages);

      const summarizer = new MockSummarizer();
      const result = await contextManager.executeCompaction({ summarizer });

      expect(result.success).toBe(true);

      // All original messages should be preserved (plus summary + ack)
      const afterMessages = contextManager.getMessages();
      expect(afterMessages.length).toBe(6); // 2 (summary + ack) + 4 (original)
    });
  });

  describe('message preservation', () => {
    it('preserves exactly preserveRecentTurns turns (default 5)', async () => {
      const harness = CompactionTestHarness.atThreshold('critical');
      harness.inject();

      const messagesBefore = harness.contextManager.getMessages();
      const preserveCount = DEFAULT_PRESERVE_TURNS * 2; // 10 messages
      const lastPreservedBefore = messagesBefore.slice(-preserveCount);

      await harness.executeCompaction();

      const messagesAfter = harness.contextManager.getMessages();

      // Should have: 2 (summary + ack) + 10 (preserved) = 12
      expect(messagesAfter.length).toBe(12);

      // Last preserved should match original last preserved
      const lastPreservedAfter = messagesAfter.slice(-preserveCount);
      for (let i = 0; i < preserveCount; i++) {
        expect(lastPreservedAfter[i]?.role).toBe(lastPreservedBefore[i]?.role);
      }
    });

    it('custom preserveRecentTurns=1 preserves 2 messages', async () => {
      const harness = CompactionTestHarness.atThreshold('critical', {
        compaction: {
          preserveRecentTurns: 1,
        },
      });
      harness.inject();

      await harness.executeCompaction();

      const messagesAfter = harness.contextManager.getMessages();

      // Should have: 2 (summary + ack) + 2 (1 turn) = 4
      expect(messagesAfter.length).toBe(4);
    });

    it('custom preserveRecentTurns=5 preserves 10 messages', async () => {
      const harness = CompactionTestHarness.atThreshold('critical', {
        compaction: {
          preserveRecentTurns: 5,
        },
      });
      harness.inject();

      await harness.executeCompaction();

      const messagesAfter = harness.contextManager.getMessages();

      // Should have: 2 (summary + ack) + 10 (5 turns) = 12
      expect(messagesAfter.length).toBe(12);
    });

    it('preserveRecentTurns=0 preserves no messages', async () => {
      const harness = CompactionTestHarness.atThreshold('critical', {
        compaction: {
          preserveRecentTurns: 0,
        },
      });
      harness.inject();

      await harness.executeCompaction();

      const messagesAfter = harness.contextManager.getMessages();

      // Should have only: 2 (summary + ack)
      expect(messagesAfter.length).toBe(2);
    });
  });

  describe('model switching', () => {
    it('switching model updates context limit', () => {
      const contextManager = createContextManager({
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test',
      });

      // Initial limit for Claude
      expect(contextManager.getContextLimit()).toBe(200_000);

      // Switch to GPT-4o (128k limit)
      contextManager.switchModel('gpt-4o');
      expect(contextManager.getContextLimit()).toBe(128_000);

      // Switch back
      contextManager.switchModel('claude-sonnet-4-20250514');
      expect(contextManager.getContextLimit()).toBe(200_000);
    });

    it('model switch to smaller limit triggers compaction callback', () => {
      const contextManager = createContextManager({
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test',
      });

      // Fill to 70% of 200k = 140k tokens
      const messages = PreciseTokenGenerator.generateForTokens(140_000);
      contextManager.setMessages(messages);
      contextManager.setApiContextTokens(140_000); // 70% of 200k

      // Register callback
      let callbackCalled = false;
      contextManager.onCompactionNeeded(() => {
        callbackCalled = true;
      });

      // Switch to smaller model - 140k is now over 100% of 128k limit!
      contextManager.switchModel('gpt-4o');

      expect(callbackCalled).toBe(true);
    });

    it('model switch to larger limit does not trigger callback', () => {
      const contextManager = createContextManager({
        model: 'gpt-4o', // 128k limit
        workingDirectory: '/test',
      });

      // Fill to 50% of 128k = 64k tokens
      const messages = PreciseTokenGenerator.generateForTokens(64_000);
      contextManager.setMessages(messages);
      contextManager.setApiContextTokens(64_000); // 50% of 128k

      let callbackCalled = false;
      contextManager.onCompactionNeeded(() => {
        callbackCalled = true;
      });

      // Switch to larger model (200k) - 64k is now only 32%
      contextManager.switchModel('claude-sonnet-4-20250514');

      expect(callbackCalled).toBe(false);
    });
  });

  describe('summarizer failures', () => {
    it('handles summarizer throwing error', async () => {
      const harness = CompactionTestHarness.atThreshold('critical', {
        summarizer: new FailingSummarizer('Test error'),
      });
      harness.inject();

      const tokensBefore = harness.contextManager.getCurrentTokens();

      await expect(harness.executeCompaction()).rejects.toThrow('Test error');

      // Context should be unchanged after failed compaction
      const tokensAfter = harness.contextManager.getCurrentTokens();
      expect(tokensAfter).toBe(tokensBefore);
    });

    it('handles slow summarizer completing successfully', async () => {
      const harness = CompactionTestHarness.atThreshold('critical', {
        summarizer: new SlowSummarizer(100), // 100ms delay
      });
      harness.inject();

      const result = await harness.executeCompaction();

      expect(result.success).toBe(true);
      expect(result.tokensAfter).toBeLessThan(result.tokensBefore);
    });

    it('summarizer returning empty narrative is handled', async () => {
      const contextManager = createContextManager({
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test',
      });

      const messages = PreciseTokenGenerator.generateForTokens(50_000);
      contextManager.setMessages(messages);

      // Custom summarizer that returns empty narrative
      const emptySummarizer = {
        async summarize() {
          return {
            extractedData: {
              currentGoal: '',
              completedSteps: [],
              pendingTasks: [],
              keyDecisions: [],
              filesModified: [],
              topicsDiscussed: [],
              userPreferences: [],
              importantContext: [],
            },
            narrative: '', // Empty!
          };
        },
      };

      const result = await contextManager.executeCompaction({
        summarizer: emptySummarizer,
      });

      // Should still succeed even with empty narrative
      expect(result.success).toBe(true);
    });
  });

  describe('edited summary', () => {
    it('uses user-provided editedSummary instead of generated', async () => {
      const harness = CompactionTestHarness.atThreshold('critical');
      harness.inject();

      const customSummary = 'This is a custom user-edited summary for testing.';
      const result = await harness.contextManager.executeCompaction({
        summarizer: harness.summarizer,
        editedSummary: customSummary,
      });

      expect(result.success).toBe(true);
      expect(result.summary).toBe(customSummary);

      // Check the summary is in the context
      const messages = harness.contextManager.getMessages();
      expect(messages[0]?.content).toContain(customSummary);
    });

    it('editedSummary appears in first message after compaction', async () => {
      const harness = CompactionTestHarness.atThreshold('critical');
      harness.inject();

      const editedSummary =
        'User was working on implementing a new feature. Key files modified: src/index.ts';
      await harness.contextManager.executeCompaction({
        summarizer: harness.summarizer,
        editedSummary,
      });

      const messages = harness.contextManager.getMessages();

      // First message should be user message with context
      expect(messages[0]?.role).toBe('user');
      expect(messages[0]?.content).toContain('[Context from earlier');
      expect(messages[0]?.content).toContain(editedSummary);
    });

    it('editedSummary overrides even when summarizer would fail', async () => {
      const harness = CompactionTestHarness.atThreshold('critical', {
        summarizer: new FailingSummarizer('Should not be called'),
      });
      harness.inject();

      // Even with failing summarizer, providing editedSummary should work
      const editedSummary = 'Pre-written summary that bypasses summarizer';
      const result = await harness.contextManager.executeCompaction({
        summarizer: harness.summarizer,
        editedSummary,
      });

      expect(result.success).toBe(true);
      expect(result.summary).toBe(editedSummary);
    });
  });

  describe('custom compaction threshold', () => {
    it('respects custom threshold of 0.50', () => {
      const contextManager = createContextManager({
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test',
        compaction: {
          threshold: 0.50, // Custom: trigger at 50%
        },
      });

      // Fill to 55%
      const messages = PreciseTokenGenerator.generateForTokens(110_000);
      contextManager.setMessages(messages);
      contextManager.setApiContextTokens(110_000); // 55% of 200k

      // Should recommend compaction at 55% with 50% threshold
      expect(contextManager.shouldCompact()).toBe(true);
    });

    it('respects custom threshold of 0.90', () => {
      const contextManager = createContextManager({
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test',
        compaction: {
          threshold: 0.90, // Custom: only trigger at 90%
        },
      });

      // Fill to 85% (would trigger default 70% threshold)
      const messages = PreciseTokenGenerator.generateForTokens(170_000);
      contextManager.setMessages(messages);
      contextManager.setApiContextTokens(170_000); // 85% of 200k

      // Should NOT recommend compaction at 85% with 90% threshold
      expect(contextManager.shouldCompact()).toBe(false);

      // Add more to get to 91%
      const moreMessages = PreciseTokenGenerator.generateForTokens(12_000, {
        seed: 999,
      });
      contextManager.setMessages([...messages, ...moreMessages]);
      contextManager.setApiContextTokens(182_000); // 91% of 200k

      // Now should recommend
      expect(contextManager.shouldCompact()).toBe(true);
    });
  });

  describe('tool result messages', () => {
    it('preserves tool result messages in recent turns', async () => {
      const contextManager = createContextManager({
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test',
        compaction: {
          preserveRecentTurns: 2,
        },
      });

      // Create messages with tool results
      const messages: Message[] = [];

      // Add older messages
      for (let i = 0; i < 50; i++) {
        messages.push({ role: 'user', content: `Old message ${i}` });
        messages.push({
          role: 'assistant',
          content: [{ type: 'text', text: `Old response ${i}` }],
        });
      }

      // Add recent turn with tool call
      messages.push({ role: 'user', content: 'Recent user message 1' });
      messages.push({
        role: 'assistant',
        content: [
          { type: 'text', text: 'Let me check that file' },
          {
            type: 'tool_use',
            id: 'tool_recent_1',
            name: 'Read',
            arguments: { file_path: '/test.ts' },
          },
        ],
      });
      messages.push({
        role: 'toolResult',
        toolCallId: 'tool_recent_1',
        content: 'File contents here',
      });

      // Add another turn
      messages.push({ role: 'user', content: 'Recent user message 2' });
      messages.push({
        role: 'assistant',
        content: [{ type: 'text', text: 'Recent response 2' }],
      });

      contextManager.setMessages(messages);

      const summarizer = new MockSummarizer();
      await contextManager.executeCompaction({ summarizer });

      const afterMessages = contextManager.getMessages();

      // Check tool result is preserved
      const hasToolResult = afterMessages.some(m => m.role === 'toolResult');
      expect(hasToolResult).toBe(true);
    });
  });

  describe('context snapshot after compaction', () => {
    it('snapshot accurately reflects post-compaction state', async () => {
      const harness = CompactionTestHarness.atThreshold('exceeded');
      harness.inject();

      const snapshotBefore = harness.contextManager.getSnapshot();
      expect(snapshotBefore.thresholdLevel).toBe('exceeded');

      await harness.executeCompaction();

      // Simulate API reporting reduced tokens after compaction
      const reducedTokens = Math.floor(harness.contextLimit * 0.2);
      harness.contextManager.setApiContextTokens(reducedTokens);

      const snapshotAfter = harness.contextManager.getSnapshot();

      // Should be in normal range
      expect(snapshotAfter.thresholdLevel).toBe('normal');
      expect(snapshotAfter.usagePercent).toBeLessThan(0.3);
      expect(snapshotAfter.currentTokens).toBeLessThan(snapshotBefore.currentTokens);

      // Breakdown should show estimates (non-zero since we have API data)
      expect(snapshotAfter.breakdown.messages).toBeGreaterThan(0);
      expect(snapshotAfter.breakdown.messages).toBeLessThan(
        snapshotBefore.breakdown.messages
      );
    });
  });
});
