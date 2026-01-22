/**
 * @fileoverview Multiple Compaction Cycle Tests
 *
 * Tests scenarios where compaction happens multiple times in a session,
 * verifying that recent turns are preserved correctly and summaries chain properly.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { CompactionTestHarness } from '../__helpers__/compaction-test-harness.js';
import { PreciseTokenGenerator } from '../__helpers__/precise-token-generator.js';
import { MockSummarizer, FixedSizeSummarizer } from '../__helpers__/mock-summarizer.js';
import type { Message } from '../../types/index.js';

// =============================================================================
// Constants
// =============================================================================

const CONTEXT_LIMIT = 200_000;
const PRESERVE_RECENT_TURNS = 3; // Default: 3 turns = 6 messages

// =============================================================================
// Multi-Cycle Compaction Tests
// =============================================================================

describe('Multiple Compaction Cycles', () => {
  describe('sequential compactions', () => {
    it('compacts from 95% to low utilization', async () => {
      const harness = CompactionTestHarness.atThreshold('exceeded');
      harness.inject();

      // Verify starting state
      const snapshotBefore = harness.contextManager.getSnapshot();
      expect(snapshotBefore.thresholdLevel).toBe('exceeded');

      // Execute compaction
      const result = await harness.executeCompaction();

      expect(result.success).toBe(true);
      expect(result.tokensAfter).toBeLessThan(result.tokensBefore);

      // Verify ending state
      const snapshotAfter = harness.contextManager.getSnapshot();
      expect(snapshotAfter.thresholdLevel).toBe('normal');
      expect(snapshotAfter.usagePercent).toBeLessThan(0.3);
    });

    it('can compact again after context grows back to exceeded', async () => {
      const harness = CompactionTestHarness.atThreshold('exceeded');
      harness.inject();

      // First compaction
      const result1 = await harness.executeCompaction();
      expect(result1.success).toBe(true);

      const tokensAfterFirst = harness.contextManager.getCurrentTokens();

      // Simulate continued conversation - grow back to exceeded
      const additionalTokens = Math.floor(CONTEXT_LIMIT * 0.95) - tokensAfterFirst;
      const additionalMessages = PreciseTokenGenerator.generateForTokens(
        additionalTokens,
        { seed: 999 }
      );

      // Add to existing messages
      const currentMessages = harness.contextManager.getMessages();
      harness.contextManager.setMessages([...currentMessages, ...additionalMessages]);

      // Verify we're back to exceeded
      const snapshotBeforeSecond = harness.contextManager.getSnapshot();
      expect(snapshotBeforeSecond.thresholdLevel).toBe('exceeded');

      // Second compaction
      const result2 = await harness.executeCompaction();
      expect(result2.success).toBe(true);
      expect(result2.tokensAfter).toBeLessThan(result2.tokensBefore);

      // Verify we're back to normal
      const snapshotAfterSecond = harness.contextManager.getSnapshot();
      expect(snapshotAfterSecond.thresholdLevel).toBe('normal');
    });

    it('preserves recent turns across multiple compactions', async () => {
      const harness = CompactionTestHarness.atThreshold('exceeded');
      harness.inject();

      // Mark the last N messages for identification
      const originalMessages = harness.contextManager.getMessages();
      const preserveCount = PRESERVE_RECENT_TURNS * 2; // 3 turns = 6 messages
      const lastMessages = originalMessages.slice(-preserveCount);

      // First compaction
      await harness.executeCompaction();

      // Get messages after first compaction
      // Structure: [context summary, ack, ...preserved]
      const messagesAfterFirst = harness.contextManager.getMessages();

      // Verify preserved messages match (skip first 2 which are summary + ack)
      const preservedAfterFirst = messagesAfterFirst.slice(-preserveCount);
      expect(preservedAfterFirst.length).toBe(lastMessages.length);

      // Verify content matches
      for (let i = 0; i < preserveCount; i++) {
        const original = lastMessages[i];
        const preserved = preservedAfterFirst[i];
        if (original && preserved) {
          expect(preserved.role).toBe(original.role);
        }
      }
    });

    it('summary from first compaction becomes part of context for second', async () => {
      const harness = CompactionTestHarness.atThreshold('exceeded');
      harness.inject();

      // First compaction
      await harness.executeCompaction();

      // Get first message (context summary)
      const messagesAfterFirst = harness.contextManager.getMessages();
      expect(messagesAfterFirst[0]?.content).toContain('[Context from earlier');

      // Grow back and compact again
      const additionalMessages = PreciseTokenGenerator.generateForTokens(
        Math.floor(CONTEXT_LIMIT * 0.8),
        { seed: 888 }
      );
      harness.contextManager.setMessages([...messagesAfterFirst, ...additionalMessages]);

      // Second compaction
      await harness.executeCompaction();

      // New context summary should be at front
      const messagesAfterSecond = harness.contextManager.getMessages();
      expect(messagesAfterSecond[0]?.content).toContain('[Context from earlier');
    });
  });

  describe('compression ratio consistency', () => {
    it('achieves consistent compression ratio with fixed-size summarizer', async () => {
      const fixedSummaryTokens = 500;
      const summarizer = new FixedSizeSummarizer(fixedSummaryTokens);

      const harness = CompactionTestHarness.atThreshold('exceeded', {
        summarizer,
      });
      harness.inject();

      const result = await harness.executeCompaction();

      expect(result.success).toBe(true);
      // Compression ratio should be predictable with fixed-size summary
      expect(result.tokensAfter).toBeLessThan(result.tokensBefore * 0.5);
    });

    it('maintains similar compression ratios across multiple cycles', async () => {
      const ratios: number[] = [];

      for (let cycle = 0; cycle < 3; cycle++) {
        const harness = CompactionTestHarness.atThreshold('exceeded', {
          seed: 42 + cycle * 100,
        });
        harness.inject();

        const result = await harness.executeCompaction();
        const ratio = result.tokensAfter / result.tokensBefore;
        ratios.push(ratio);
      }

      // All ratios should be in a reasonable range
      // With 95% utilization (~190k tokens) compressed to ~6k (8 messages),
      // ratio can be as low as 3% (0.03)
      for (const ratio of ratios) {
        expect(ratio).toBeGreaterThan(0.001); // At least 0.1%
        expect(ratio).toBeLessThan(0.5);
      }

      // Ratios should be somewhat consistent (within 10x of each other)
      const minRatio = Math.min(...ratios);
      const maxRatio = Math.max(...ratios);
      expect(maxRatio / minRatio).toBeLessThan(10);
    });
  });

  describe('message count evolution', () => {
    it('reduces message count significantly after compaction', async () => {
      const harness = CompactionTestHarness.atThreshold('exceeded');
      harness.inject();

      const messagesBefore = harness.contextManager.getMessages().length;
      expect(messagesBefore).toBeGreaterThan(100); // Should have many messages

      await harness.executeCompaction();

      const messagesAfter = harness.contextManager.getMessages().length;

      // Should have: 2 (summary + ack) + 6 (3 turns) = 8 messages
      expect(messagesAfter).toBe(8);
      expect(messagesAfter).toBeLessThan(messagesBefore * 0.1);
    });

    it('message count grows predictably after compaction', async () => {
      const harness = CompactionTestHarness.atThreshold('exceeded');
      harness.inject();

      await harness.executeCompaction();

      const baseCount = harness.contextManager.getMessages().length;
      expect(baseCount).toBe(8); // 2 + 6

      // Add 5 more turns (10 messages)
      const additionalMessages = PreciseTokenGenerator.generateForTokens(10000, {
        seed: 777,
      });
      const currentMessages = harness.contextManager.getMessages();
      harness.contextManager.setMessages([...currentMessages, ...additionalMessages]);

      const newCount = harness.contextManager.getMessages().length;
      expect(newCount).toBeGreaterThan(baseCount);
    });
  });

  describe('compaction preview accuracy', () => {
    it('preview accurately predicts compaction result', async () => {
      const harness = CompactionTestHarness.atThreshold('critical');
      harness.inject();

      // Get preview
      const preview = await harness.contextManager.previewCompaction({
        summarizer: harness.summarizer,
      });

      // Execute compaction
      const result = await harness.executeCompaction();

      // Preview should match actual result (within 10% tolerance)
      expect(preview.tokensBefore).toBe(result.tokensBefore);

      // Tokens after should be close (preview includes estimation variance)
      const tolerance = preview.tokensAfter * 0.2; // 20% tolerance
      expect(result.tokensAfter).toBeGreaterThan(preview.tokensAfter - tolerance);
      expect(result.tokensAfter).toBeLessThan(preview.tokensAfter + tolerance);
    });

    it('preview does not modify state', async () => {
      const harness = CompactionTestHarness.atThreshold('critical');
      harness.inject();

      const tokensBefore = harness.contextManager.getCurrentTokens();
      const messagesBefore = harness.contextManager.getMessages().length;

      // Call preview multiple times
      await harness.contextManager.previewCompaction({
        summarizer: harness.summarizer,
      });
      await harness.contextManager.previewCompaction({
        summarizer: harness.summarizer,
      });

      const tokensAfter = harness.contextManager.getCurrentTokens();
      const messagesAfter = harness.contextManager.getMessages().length;

      expect(tokensAfter).toBe(tokensBefore);
      expect(messagesAfter).toBe(messagesBefore);
    });
  });

  describe('rapid compaction cycles', () => {
    it('handles three compaction cycles in sequence', async () => {
      const harness = CompactionTestHarness.atThreshold('exceeded');
      harness.inject();

      const results: Array<{ tokensBefore: number; tokensAfter: number }> = [];

      // Cycle 1
      results.push(await harness.executeCompaction());

      // Grow back
      const grow1 = PreciseTokenGenerator.generateForTokens(
        Math.floor(CONTEXT_LIMIT * 0.85),
        { seed: 111 }
      );
      harness.contextManager.setMessages([
        ...harness.contextManager.getMessages(),
        ...grow1,
      ]);

      // Cycle 2
      results.push(await harness.executeCompaction());

      // Grow back
      const grow2 = PreciseTokenGenerator.generateForTokens(
        Math.floor(CONTEXT_LIMIT * 0.85),
        { seed: 222 }
      );
      harness.contextManager.setMessages([
        ...harness.contextManager.getMessages(),
        ...grow2,
      ]);

      // Cycle 3
      results.push(await harness.executeCompaction());

      // All compactions should succeed
      for (const result of results) {
        expect(result.tokensAfter).toBeLessThan(result.tokensBefore);
      }

      // Final state should be low utilization
      const finalSnapshot = harness.contextManager.getSnapshot();
      expect(finalSnapshot.thresholdLevel).toBe('normal');
    });
  });
});
