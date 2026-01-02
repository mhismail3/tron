/**
 * @fileoverview Tests for Context Compactor
 *
 * TDD tests for the context compaction mechanism that:
 * - Monitors token usage in conversation
 * - Triggers compaction at configurable thresholds
 * - Generates continuation summaries to preserve context
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  ContextCompactor,
  createContextCompactor,
  type CompactorConfig,
  type CompactResult,
} from '../../src/context/compactor.js';
import type { Message } from '../../src/agent/types.js';

describe('ContextCompactor', () => {
  // ==========================================================================
  // Basic Setup
  // ==========================================================================

  describe('initialization', () => {
    it('should create with default config', () => {
      const compactor = createContextCompactor();
      expect(compactor).toBeInstanceOf(ContextCompactor);
    });

    it('should accept custom token thresholds', () => {
      const compactor = createContextCompactor({
        maxTokens: 30000,
        compactionThreshold: 0.8,
        targetTokens: 15000,
      });
      expect(compactor.getConfig().maxTokens).toBe(30000);
      expect(compactor.getConfig().compactionThreshold).toBe(0.8);
      expect(compactor.getConfig().targetTokens).toBe(15000);
    });

    it('should have sensible defaults', () => {
      const compactor = createContextCompactor();
      const config = compactor.getConfig();
      expect(config.maxTokens).toBe(25000);
      expect(config.compactionThreshold).toBe(0.85);
      expect(config.targetTokens).toBe(10000);
    });
  });

  // ==========================================================================
  // Token Estimation
  // ==========================================================================

  describe('token estimation', () => {
    it('should estimate tokens for a message', () => {
      const compactor = createContextCompactor();
      const message: Message = { role: 'user', content: 'Hello world' };

      const tokens = compactor.estimateTokens([message]);
      // Rough estimate: ~4 chars per token
      expect(tokens).toBeGreaterThan(0);
      expect(tokens).toBeLessThan(100);
    });

    it('should estimate tokens for multiple messages', () => {
      const compactor = createContextCompactor();
      const messages: Message[] = [
        { role: 'user', content: 'Hello world' },
        { role: 'assistant', content: 'Hi there! How can I help you today?' },
        { role: 'user', content: 'Tell me about TypeScript' },
      ];

      const tokens = compactor.estimateTokens(messages);
      expect(tokens).toBeGreaterThan(10);
    });

    it('should estimate tokens for complex content blocks', () => {
      const compactor = createContextCompactor();
      const messages: Message[] = [
        {
          role: 'assistant',
          content: [
            { type: 'text', text: 'Here is some code:' },
            { type: 'text', text: 'function foo() { return 42; }' },
          ],
        },
      ];

      const tokens = compactor.estimateTokens(messages);
      expect(tokens).toBeGreaterThan(5);
    });

    it('should handle tool use and results in token estimation', () => {
      const compactor = createContextCompactor();
      const messages: Message[] = [
        {
          role: 'assistant',
          content: [
            { type: 'text', text: 'Let me read that file' },
            { type: 'tool_use', id: 'tool_1', name: 'read_file', input: { path: '/test.txt' } },
          ],
        },
        {
          role: 'user',
          content: [
            { type: 'tool_result', tool_use_id: 'tool_1', content: 'File contents here...' },
          ],
        },
      ];

      const tokens = compactor.estimateTokens(messages);
      expect(tokens).toBeGreaterThan(10);
    });
  });

  // ==========================================================================
  // Compaction Trigger
  // ==========================================================================

  describe('compaction trigger', () => {
    it('should indicate when compaction is needed', () => {
      const compactor = createContextCompactor({
        maxTokens: 100, // Low threshold for testing
        compactionThreshold: 0.8, // 80% = 80 tokens
      });

      // Below threshold
      expect(compactor.needsCompaction(70)).toBe(false);

      // Above threshold
      expect(compactor.needsCompaction(85)).toBe(true);
      expect(compactor.needsCompaction(100)).toBe(true);
    });

    it('should check messages against threshold', () => {
      const compactor = createContextCompactor({
        maxTokens: 50,
        compactionThreshold: 0.8,
      });

      // Create messages that exceed threshold
      const messages: Message[] = [
        { role: 'user', content: 'A'.repeat(200) }, // ~50 tokens
      ];

      expect(compactor.shouldCompact(messages)).toBe(true);
    });

    it('should not trigger below threshold', () => {
      const compactor = createContextCompactor({
        maxTokens: 1000,
        compactionThreshold: 0.8,
      });

      const messages: Message[] = [
        { role: 'user', content: 'Hello' },
        { role: 'assistant', content: 'Hi' },
      ];

      expect(compactor.shouldCompact(messages)).toBe(false);
    });
  });

  // ==========================================================================
  // Compaction Process
  // ==========================================================================

  describe('compaction process', () => {
    it('should compact messages to target token count', async () => {
      const compactor = createContextCompactor({
        maxTokens: 50,
        compactionThreshold: 0.5, // 25 tokens trigger
        targetTokens: 20,
      });

      // Longer messages to exceed threshold
      const messages: Message[] = [
        { role: 'user', content: 'First question about TypeScript and how it works in modern development' },
        { role: 'assistant', content: 'TypeScript is a typed superset of JavaScript that compiles to plain JS' },
        { role: 'user', content: 'Second question about interfaces and type definitions in TypeScript' },
        { role: 'assistant', content: 'Interfaces define contracts for objects and enable structural typing' },
        { role: 'user', content: 'Third question about generics and how they enable code reuse' },
        { role: 'assistant', content: 'Generics enable reusable type-safe code by parameterizing types' },
      ];

      const result = await compactor.compact(messages);

      expect(result.compacted).toBe(true);
      expect(result.originalTokens).toBeGreaterThan(0);
      expect(result.messages.length).toBeLessThanOrEqual(messages.length);
    });

    it('should preserve system messages', async () => {
      const compactor = createContextCompactor({
        maxTokens: 100,
        targetTokens: 30,
      });

      const messages: Message[] = [
        { role: 'system', content: 'You are a helpful assistant' },
        { role: 'user', content: 'Question 1' },
        { role: 'assistant', content: 'Answer 1' },
        { role: 'user', content: 'Question 2' },
        { role: 'assistant', content: 'Answer 2' },
      ];

      const result = await compactor.compact(messages);

      // System message should be preserved
      const systemMessages = result.messages.filter(m => m.role === 'system');
      expect(systemMessages.length).toBe(1);
    });

    it('should include continuation summary', async () => {
      const compactor = createContextCompactor({
        maxTokens: 50,
        compactionThreshold: 0.5, // 25 tokens trigger
        targetTokens: 20,
      });

      // Longer messages to exceed threshold
      const messages: Message[] = [
        { role: 'user', content: 'Tell me about React hooks and how they work in functional components' },
        { role: 'assistant', content: 'React hooks are functions that let you use state and lifecycle features' },
        { role: 'user', content: 'What about useEffect and side effects management?' },
        { role: 'assistant', content: 'useEffect handles side effects like data fetching and subscriptions in components' },
      ];

      const result = await compactor.compact(messages);

      expect(result.summary).toBeDefined();
      expect(result.summary.length).toBeGreaterThan(0);
    });

    it('should preserve recent messages', async () => {
      const compactor = createContextCompactor({
        maxTokens: 200,
        targetTokens: 50,
        preserveRecentCount: 2,
      });

      const messages: Message[] = [
        { role: 'user', content: 'Old message 1' },
        { role: 'assistant', content: 'Old response 1' },
        { role: 'user', content: 'Old message 2' },
        { role: 'assistant', content: 'Old response 2' },
        { role: 'user', content: 'Recent message' },
        { role: 'assistant', content: 'Recent response' },
      ];

      const result = await compactor.compact(messages);

      // Recent messages should be preserved verbatim
      const lastMessage = result.messages[result.messages.length - 1];
      expect(lastMessage.content).toBe('Recent response');
    });

    it('should not compact if below threshold', async () => {
      const compactor = createContextCompactor({
        maxTokens: 10000,
        targetTokens: 5000,
      });

      const messages: Message[] = [
        { role: 'user', content: 'Hello' },
        { role: 'assistant', content: 'Hi' },
      ];

      const result = await compactor.compact(messages);

      expect(result.compacted).toBe(false);
      expect(result.messages).toEqual(messages);
    });
  });

  // ==========================================================================
  // Summary Generation
  // ==========================================================================

  describe('summary generation', () => {
    it('should generate a summary from messages', () => {
      const compactor = createContextCompactor();

      const messages: Message[] = [
        { role: 'user', content: 'How do I implement a binary search?' },
        { role: 'assistant', content: 'Binary search works by dividing the search space in half' },
        { role: 'user', content: 'Can you show me code?' },
        { role: 'assistant', content: 'function binarySearch(arr, target) { ... }' },
      ];

      const summary = compactor.generateSummary(messages);

      expect(summary).toBeDefined();
      expect(summary.length).toBeGreaterThan(0);
      expect(summary.length).toBeLessThan(500); // Should be concise
    });

    it('should extract key topics from conversation', () => {
      const compactor = createContextCompactor();

      const messages: Message[] = [
        { role: 'user', content: 'Let me explain the React component structure' },
        { role: 'assistant', content: 'I understand. Components are the building blocks.' },
        { role: 'user', content: 'Now about state management with Redux' },
        { role: 'assistant', content: 'Redux provides a centralized store for state.' },
      ];

      const summary = compactor.generateSummary(messages);

      // Summary should mention key topics
      expect(summary.toLowerCase()).toMatch(/react|component|state|redux/i);
    });

    it('should handle tool interactions in summary', () => {
      const compactor = createContextCompactor();

      const messages: Message[] = [
        { role: 'user', content: 'Read the config file' },
        {
          role: 'assistant',
          content: [
            { type: 'text', text: 'Reading config' },
            { type: 'tool_use', id: 't1', name: 'read_file', input: { path: 'config.json' } },
          ],
        },
        {
          role: 'user',
          content: [{ type: 'tool_result', tool_use_id: 't1', content: '{"debug": true}' }],
        },
        { role: 'assistant', content: 'The config has debug mode enabled.' },
      ];

      const summary = compactor.generateSummary(messages);

      // Summary should mention file/config
      expect(summary.toLowerCase()).toMatch(/config|file|debug/i);
    });
  });

  // ==========================================================================
  // Compaction Hooks
  // ==========================================================================

  describe('compaction hooks', () => {
    it('should call onBeforeCompact callback', async () => {
      const onBeforeCompact = vi.fn();
      const compactor = createContextCompactor({
        maxTokens: 50,
        targetTokens: 20,
        onBeforeCompact,
      });

      const messages: Message[] = [
        { role: 'user', content: 'A'.repeat(100) },
        { role: 'assistant', content: 'B'.repeat(100) },
      ];

      await compactor.compact(messages);

      expect(onBeforeCompact).toHaveBeenCalledWith(expect.objectContaining({
        messageCount: messages.length,
        estimatedTokens: expect.any(Number),
      }));
    });

    it('should call onAfterCompact callback', async () => {
      const onAfterCompact = vi.fn();
      const compactor = createContextCompactor({
        maxTokens: 50,
        targetTokens: 20,
        onAfterCompact,
      });

      const messages: Message[] = [
        { role: 'user', content: 'A'.repeat(100) },
        { role: 'assistant', content: 'B'.repeat(100) },
      ];

      await compactor.compact(messages);

      expect(onAfterCompact).toHaveBeenCalledWith(expect.objectContaining({
        originalTokens: expect.any(Number),
        newTokens: expect.any(Number),
        summary: expect.any(String),
      }));
    });
  });

  // ==========================================================================
  // Edge Cases
  // ==========================================================================

  describe('edge cases', () => {
    it('should handle empty messages', async () => {
      const compactor = createContextCompactor();

      const result = await compactor.compact([]);

      expect(result.compacted).toBe(false);
      expect(result.messages).toEqual([]);
    });

    it('should handle single message', async () => {
      const compactor = createContextCompactor();

      const messages: Message[] = [{ role: 'user', content: 'Hello' }];
      const result = await compactor.compact(messages);

      expect(result.messages.length).toBe(1);
    });

    it('should handle very long single message', async () => {
      const compactor = createContextCompactor({
        maxTokens: 50,
        targetTokens: 20,
      });

      const messages: Message[] = [
        { role: 'user', content: 'X'.repeat(500) },
      ];

      // Should still attempt compaction
      const result = await compactor.compact(messages);
      expect(result).toBeDefined();
    });

    it('should preserve message order', async () => {
      const compactor = createContextCompactor({
        maxTokens: 200,
        targetTokens: 100,
        preserveRecentCount: 4,
      });

      const messages: Message[] = [
        { role: 'system', content: 'System' },
        { role: 'user', content: 'User 1' },
        { role: 'assistant', content: 'Assistant 1' },
        { role: 'user', content: 'User 2' },
        { role: 'assistant', content: 'Assistant 2' },
      ];

      const result = await compactor.compact(messages);

      // Check that roles alternate correctly
      for (let i = 1; i < result.messages.length - 1; i++) {
        const prevRole = result.messages[i - 1].role;
        const currRole = result.messages[i].role;

        if (prevRole !== 'system') {
          // user -> assistant or assistant -> user
          expect(['user', 'assistant']).toContain(currRole);
        }
      }
    });
  });
});
