/**
 * @fileoverview Tests for Testing Infrastructure
 *
 * Verifies that ContextSimulator and MockSummarizer work correctly
 * for testing the context management system.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { ContextSimulator, createContextSimulator } from './context-simulator.js';
import { MockSummarizer, createMockSummarizer } from './mock-summarizer.js';
import type { SimulatedSession } from './context-simulator.js';

// =============================================================================
// ContextSimulator Tests
// =============================================================================

describe('ContextSimulator', () => {
  describe('Token Generation', () => {
    it('generates session near target token count', () => {
      const targetTokens = 50000;
      const simulator = createContextSimulator({ targetTokens });
      const session = simulator.generateSession();

      // Should be within 20% of target (due to message boundaries)
      expect(session.estimatedTokens).toBeGreaterThan(targetTokens * 0.8);
      expect(session.estimatedTokens).toBeLessThan(targetTokens * 1.2);
    });

    it('generates higher token counts for larger targets', () => {
      const small = createContextSimulator({ targetTokens: 10000 }).generateSession();
      const large = createContextSimulator({ targetTokens: 100000 }).generateSession();

      expect(large.estimatedTokens).toBeGreaterThan(small.estimatedTokens);
      expect(large.messages.length).toBeGreaterThan(small.messages.length);
    });

    it('generates consistent results with same seed', () => {
      const config = { targetTokens: 50000, seed: 12345 };
      const session1 = createContextSimulator(config).generateSession();
      const session2 = createContextSimulator(config).generateSession();

      expect(session1.estimatedTokens).toBe(session2.estimatedTokens);
      expect(session1.messages.length).toBe(session2.messages.length);
      expect(session1.turnCount).toBe(session2.turnCount);
    });

    it('generates different results with different seeds', () => {
      const session1 = createContextSimulator({ targetTokens: 50000, seed: 12345 }).generateSession();
      const session2 = createContextSimulator({ targetTokens: 50000, seed: 54321 }).generateSession();

      // Content should differ even if token counts are similar
      const text1 = JSON.stringify(session1.messages[0]);
      const text2 = JSON.stringify(session2.messages[0]);
      expect(text1).not.toBe(text2);
    });
  });

  describe('Message Structure', () => {
    let session: SimulatedSession;

    beforeEach(() => {
      session = createContextSimulator({
        targetTokens: 50000,
        toolCallRatio: 0.5, // 50% tool calls for easier testing
        seed: 12345,
      }).generateSession();
    });

    it('generates valid user messages', () => {
      const userMessages = session.messages.filter(m => m.role === 'user');
      expect(userMessages.length).toBeGreaterThan(0);

      for (const msg of userMessages) {
        expect(msg.role).toBe('user');
        expect(typeof msg.content === 'string' || Array.isArray(msg.content)).toBe(true);
        if (typeof msg.content === 'string') {
          expect(msg.content.length).toBeGreaterThan(0);
        }
      }
    });

    it('generates valid assistant messages', () => {
      const assistantMessages = session.messages.filter(m => m.role === 'assistant');
      expect(assistantMessages.length).toBeGreaterThan(0);

      for (const msg of assistantMessages) {
        expect(msg.role).toBe('assistant');
        expect(Array.isArray(msg.content)).toBe(true);
        expect(msg.content.length).toBeGreaterThan(0);

        // At least one text block
        const hasText = msg.content.some(b =>
          typeof b === 'object' && 'type' in b && b.type === 'text'
        );
        expect(hasText).toBe(true);
      }
    });

    it('generates tool calls with proper structure', () => {
      const toolCalls = session.messages
        .filter(m => m.role === 'assistant')
        .flatMap(m => (m.content as Array<unknown>).filter((b: unknown) =>
          typeof b === 'object' && b !== null && 'type' in b && (b as { type: string }).type === 'tool_use'
        ));

      if (toolCalls.length > 0) {
        for (const tool of toolCalls) {
          const t = tool as { type: string; id: string; name: string; arguments: Record<string, unknown> };
          expect(t.type).toBe('tool_use');
          expect(typeof t.id).toBe('string');
          expect(typeof t.name).toBe('string');
          expect(typeof t.arguments).toBe('object');
        }
      }
    });

    it('generates tool results for tool calls', () => {
      const toolResults = session.messages.filter(m => m.role === 'toolResult');
      const toolCalls = session.messages
        .filter(m => m.role === 'assistant')
        .flatMap(m => (m.content as Array<unknown>).filter((b: unknown) =>
          typeof b === 'object' && b !== null && 'type' in b && (b as { type: string }).type === 'tool_use'
        ));

      // Should have roughly equal tool calls and results
      expect(Math.abs(toolResults.length - toolCalls.length)).toBeLessThan(2);
    });
  });

  describe('Tool Call Ratio', () => {
    it('respects low tool call ratio', () => {
      const session = createContextSimulator({
        targetTokens: 100000,
        toolCallRatio: 0.1,
        seed: 12345,
      }).generateSession();

      const toolRatio = session.toolCalls / session.turnCount;
      expect(toolRatio).toBeLessThan(0.3); // Allow some variance
    });

    it('respects high tool call ratio', () => {
      const session = createContextSimulator({
        targetTokens: 100000,
        toolCallRatio: 0.9,
        seed: 12345,
      }).generateSession();

      const toolRatio = session.toolCalls / session.turnCount;
      expect(toolRatio).toBeGreaterThan(0.5);
    });
  });

  describe('generateAtUtilization', () => {
    it('generates session at 50% utilization', () => {
      const contextLimit = 200000;
      const simulator = createContextSimulator({ targetTokens: 1000 }); // Initial doesn't matter
      const session = simulator.generateAtUtilization(50, contextLimit);

      const utilization = session.estimatedTokens / contextLimit;
      expect(utilization).toBeGreaterThan(0.4);
      expect(utilization).toBeLessThan(0.6);
    });

    it('generates session at 85% utilization', () => {
      const contextLimit = 200000;
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(85, contextLimit);

      const utilization = session.estimatedTokens / contextLimit;
      expect(utilization).toBeGreaterThan(0.75);
      expect(utilization).toBeLessThan(0.95);
    });

    it('generates session at 95% utilization', () => {
      const contextLimit = 200000;
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(95, contextLimit);

      const utilization = session.estimatedTokens / contextLimit;
      expect(utilization).toBeGreaterThan(0.85);
      expect(utilization).toBeLessThan(1.05);
    });
  });

  describe('generateTestSuite', () => {
    it('generates sessions at all threshold levels', () => {
      const suite = ContextSimulator.generateTestSuite(200000);

      expect(suite.has('normal_50')).toBe(true);
      expect(suite.has('warning_70')).toBe(true);
      expect(suite.has('alert_85')).toBe(true);
      expect(suite.has('critical_95')).toBe(true);
    });

    it('generates sessions in increasing token order', () => {
      const suite = ContextSimulator.generateTestSuite(200000);

      const normal = suite.get('normal_50')!;
      const warning = suite.get('warning_70')!;
      const alert = suite.get('alert_85')!;
      const critical = suite.get('critical_95')!;

      expect(warning.estimatedTokens).toBeGreaterThan(normal.estimatedTokens);
      expect(alert.estimatedTokens).toBeGreaterThan(warning.estimatedTokens);
      expect(critical.estimatedTokens).toBeGreaterThan(alert.estimatedTokens);
    });

    it('generates reproducible test suite', () => {
      const suite1 = ContextSimulator.generateTestSuite(200000);
      const suite2 = ContextSimulator.generateTestSuite(200000);

      expect(suite1.get('normal_50')!.estimatedTokens)
        .toBe(suite2.get('normal_50')!.estimatedTokens);
      expect(suite1.get('critical_95')!.estimatedTokens)
        .toBe(suite2.get('critical_95')!.estimatedTokens);
    });
  });

  describe('Metadata Extraction', () => {
    it('tracks files modified', () => {
      const session = createContextSimulator({
        targetTokens: 100000,
        toolCallRatio: 0.8, // High ratio to ensure file tools are used
        seed: 12345,
      }).generateSession();

      // Should extract some file paths (may be empty if no Read/Write tools)
      expect(Array.isArray(session.filesModified)).toBe(true);
    });

    it('tracks tools used', () => {
      const session = createContextSimulator({
        targetTokens: 100000,
        toolCallRatio: 0.8,
        seed: 12345,
      }).generateSession();

      expect(session.toolsUsed.length).toBeGreaterThan(0);
      for (const tool of session.toolsUsed) {
        expect(typeof tool).toBe('string');
      }
    });

    it('counts turns correctly', () => {
      const session = createContextSimulator({
        targetTokens: 50000,
        seed: 12345,
      }).generateSession();

      const userMessages = session.messages.filter(m => m.role === 'user');
      const assistantMessages = session.messages.filter(m => m.role === 'assistant');

      // Turn count should match user messages (since each turn starts with user)
      expect(session.turnCount).toBe(userMessages.length);
      // Should have roughly equal user and assistant messages
      expect(Math.abs(userMessages.length - assistantMessages.length)).toBeLessThanOrEqual(1);
    });
  });
});

// =============================================================================
// MockSummarizer Tests
// =============================================================================

describe('MockSummarizer', () => {
  let summarizer: MockSummarizer;

  beforeEach(() => {
    summarizer = createMockSummarizer();
  });

  describe('Basic Functionality', () => {
    it('returns SummaryResult with extractedData and narrative', async () => {
      const messages = createContextSimulator({ targetTokens: 10000, seed: 12345 }).generateSession().messages;
      const result = await summarizer.summarize(messages);

      expect(result).toHaveProperty('extractedData');
      expect(result).toHaveProperty('narrative');
      expect(typeof result.narrative).toBe('string');
      expect(typeof result.extractedData).toBe('object');
    });

    it('includes message count in extractedData', async () => {
      const messages = createContextSimulator({ targetTokens: 10000, seed: 12345 }).generateSession().messages;
      const result = await summarizer.summarize(messages);

      expect(result.extractedData.currentGoal).toContain(`${messages.length} messages`);
    });

    it('marks narrative with [MOCK SUMMARY] prefix', async () => {
      const messages = createContextSimulator({ targetTokens: 5000, seed: 12345 }).generateSession().messages;
      const result = await summarizer.summarize(messages);

      expect(result.narrative).toContain('[MOCK SUMMARY]');
    });
  });

  describe('Tool Extraction', () => {
    it('extracts tool names from messages', async () => {
      const session = createContextSimulator({
        targetTokens: 50000,
        toolCallRatio: 0.8,
        seed: 12345,
      }).generateSession();

      const result = await summarizer.summarize(session.messages);

      if (session.toolsUsed.length > 0) {
        expect(result.narrative).toContain('Tools used:');
      }
    });
  });

  describe('File Extraction', () => {
    it('extracts file paths from tool arguments', async () => {
      const session = createContextSimulator({
        targetTokens: 50000,
        toolCallRatio: 0.9,
        seed: 12345,
      }).generateSession();

      const result = await summarizer.summarize(session.messages);

      if (session.filesModified.length > 0) {
        expect(result.extractedData.filesModified.length).toBeGreaterThan(0);
      }
    });
  });

  describe('Configuration', () => {
    it('respects custom delay', async () => {
      const delayedSummarizer = createMockSummarizer({ delay: 50 });
      const messages = createContextSimulator({ targetTokens: 5000, seed: 12345 }).generateSession().messages;

      const start = Date.now();
      await delayedSummarizer.summarize(messages);
      const elapsed = Date.now() - start;

      expect(elapsed).toBeGreaterThanOrEqual(40); // Allow some variance
    });

    it('respects custom narrative prefix', async () => {
      const customSummarizer = createMockSummarizer({ narrativePrefix: '[TEST]' });
      const messages = createContextSimulator({ targetTokens: 5000, seed: 12345 }).generateSession().messages;

      const result = await customSummarizer.summarize(messages);

      expect(result.narrative).toContain('[TEST]');
      expect(result.narrative).not.toContain('[MOCK SUMMARY]');
    });

    it('respects override extracted data', async () => {
      const customSummarizer = createMockSummarizer({
        overrideExtractedData: {
          currentGoal: 'Custom goal for testing',
          keyDecisions: [{ decision: 'Custom decision', reason: 'Testing' }],
        },
      });
      const messages = createContextSimulator({ targetTokens: 5000, seed: 12345 }).generateSession().messages;

      const result = await customSummarizer.summarize(messages);

      expect(result.extractedData.currentGoal).toBe('Custom goal for testing');
      expect(result.extractedData.keyDecisions).toHaveLength(1);
      expect(result.extractedData.keyDecisions[0].decision).toBe('Custom decision');
    });
  });

  describe('Edge Cases', () => {
    it('handles empty messages array', async () => {
      const result = await summarizer.summarize([]);

      expect(result.extractedData.currentGoal).toContain('0 messages');
      expect(result.narrative).toBeDefined();
    });

    it('handles messages without tool calls', async () => {
      const session = createContextSimulator({
        targetTokens: 10000,
        toolCallRatio: 0,
        seed: 12345,
      }).generateSession();

      const result = await summarizer.summarize(session.messages);

      expect(result.extractedData.filesModified).toHaveLength(0);
      expect(result.extractedData.completedSteps).toContain('No tools used');
    });
  });
});

// =============================================================================
// Integration: Simulator + Summarizer
// =============================================================================

describe('Integration: Simulator + Summarizer', () => {
  it('summarizer correctly processes simulated sessions', async () => {
    const session = createContextSimulator({
      targetTokens: 100000,
      toolCallRatio: 0.5,
      seed: 12345,
    }).generateSession();

    const summarizer = createMockSummarizer();
    const result = await summarizer.summarize(session.messages);

    // Verify consistency between session metadata and summary
    if (session.toolsUsed.length > 0) {
      // Check that at least some tools are mentioned
      const toolsInSummary = session.toolsUsed.filter(t =>
        result.narrative.includes(t) || result.extractedData.importantContext.some(c => c.includes(t))
      );
      expect(toolsInSummary.length).toBeGreaterThan(0);
    }
  });

  it('summarizes sessions at all threshold levels', async () => {
    const suite = ContextSimulator.generateTestSuite(200000);
    const summarizer = createMockSummarizer();

    for (const [name, session] of suite) {
      const result = await summarizer.summarize(session.messages);
      expect(result.narrative.length).toBeGreaterThan(0);
      expect(result.extractedData.currentGoal).toContain('messages');
    }
  });
});
