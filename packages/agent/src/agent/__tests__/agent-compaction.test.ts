/**
 * @fileoverview Tests for TronAgent compaction integration
 *
 * Verifies the compaction system:
 * - Pre-turn guardrail: Auto-compact when context would exceed limit
 * - Turn logging moved to database at trace level (see agent-turn-logging.test.ts)
 */

import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest';
import { existsSync, mkdirSync, rmSync } from 'fs';
import { TronAgent } from '../tron-agent.js';
import { createMockSummarizer } from '../../context/__helpers__/mock-summarizer.js';
import { createContextSimulator } from '../../context/__helpers__/context-simulator.js';
import type { TronTool } from '../../types/index.js';
import type { AgentConfig } from '../types.js';

// Create temp directory for tests
const tempDir = `/tmp/tron-test-${Date.now()}`;

// Mock only getTronDataDir
vi.mock('../../settings/loader.js', async (importOriginal) => {
  const original = await importOriginal<typeof import('../../settings/loader.js')>();
  return {
    ...original,
    getTronDataDir: () => tempDir,
  };
});

const createMockTool = (name: string): TronTool => ({
  name,
  description: `Mock tool: ${name}`,
  parameters: { type: 'object', properties: {} },
  execute: vi.fn().mockResolvedValue({ content: 'Tool result', isError: false }),
});

const createTestConfig = (): AgentConfig => ({
  provider: {
    model: 'claude-sonnet-4-20250514',
    auth: { type: 'api_key', apiKey: 'test-key' },
  },
  tools: [createMockTool('test_tool')],
  systemPrompt: 'You are a helpful assistant.',
});

describe('TronAgent Compaction Integration', () => {
  beforeEach(() => {
    // Ensure temp directory exists
    if (!existsSync(tempDir)) {
      mkdirSync(tempDir, { recursive: true });
    }
  });

  afterEach(() => {
    // Clean up temp files
    if (existsSync(tempDir)) {
      rmSync(tempDir, { recursive: true, force: true });
    }
  });

  describe('Summarizer Configuration', () => {
    it('allows setting a summarizer for auto-compaction', () => {
      const agent = new TronAgent(createTestConfig());
      const summarizer = createMockSummarizer();

      expect(agent.canAutoCompact()).toBe(false);

      agent.setSummarizer(summarizer);

      expect(agent.canAutoCompact()).toBe(true);
    });

    it('allows enabling/disabling auto-compaction', () => {
      const agent = new TronAgent(createTestConfig());
      const summarizer = createMockSummarizer();

      agent.setSummarizer(summarizer);
      expect(agent.canAutoCompact()).toBe(true);

      agent.setAutoCompaction(false);
      expect(agent.canAutoCompact()).toBe(false);

      agent.setAutoCompaction(true);
      expect(agent.canAutoCompact()).toBe(true);
    });
  });

  describe('Pre-Turn Guardrail', () => {
    it('blocks turn when context exceeds limit and no summarizer', async () => {
      const agent = new TronAgent(createTestConfig());
      const cm = agent.getContextManager();

      // Fill context to 100% capacity
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(100, 200_000);
      cm.setMessages(session.messages);
      // Set API tokens to simulate what happens after a turn completes
      cm.setApiContextTokens(session.estimatedTokens);

      // Try to run a turn without summarizer
      const result = await agent.turn();

      expect(result.success).toBe(false);
      expect(result.error).toContain('Context limit exceeded');
    });

    it('auto-compacts when context exceeds limit and summarizer is set', async () => {
      const agent = new TronAgent(createTestConfig());
      const cm = agent.getContextManager();
      const summarizer = createMockSummarizer();

      agent.setSummarizer(summarizer);

      // Fill context to 95%+ capacity (would trigger pre-turn guardrail)
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(96, 200_000);
      cm.setMessages(session.messages);
      // Set API tokens to simulate what happens after a turn completes
      cm.setApiContextTokens(session.estimatedTokens);

      const tokensBefore = cm.getCurrentTokens();

      // Capture compaction events
      const events: Array<{ type: string; tokensBefore?: number; tokensAfter?: number }> = [];
      agent.onEvent((event) => {
        if (event.type === 'compaction_start' || event.type === 'compaction_complete') {
          events.push({
            type: event.type,
            tokensBefore: (event as { tokensBefore?: number }).tokensBefore,
            tokensAfter: (event as { tokensAfter?: number }).tokensAfter,
          });
        }
      });

      // Turn will fail due to no provider but compaction should have run
      await agent.turn();

      // Check that compaction was triggered
      expect(events.length).toBeGreaterThanOrEqual(1);
      expect(events[0].type).toBe('compaction_start');

      // Tokens should be reduced
      expect(cm.getCurrentTokens()).toBeLessThan(tokensBefore);
    });
  });

  describe('Context Manager Access', () => {
    it('provides access to context manager for advanced operations', () => {
      const agent = new TronAgent(createTestConfig());
      const cm = agent.getContextManager();

      expect(cm).toBeDefined();
      expect(cm.getModel()).toBe('claude-sonnet-4-20250514');
      expect(cm.getContextLimit()).toBe(200_000);
    });

    it('can preview compaction without executing', async () => {
      const agent = new TronAgent(createTestConfig());
      const cm = agent.getContextManager();

      // Add some messages
      const simulator = createContextSimulator({ targetTokens: 500 });
      const session = simulator.generateAtUtilization(50, 200_000);
      cm.setMessages(session.messages);
      // Set API tokens to simulate what happens after a turn completes
      cm.setApiContextTokens(session.estimatedTokens);

      const preview = await cm.previewCompaction({
        summarizer: createMockSummarizer(),
      });

      expect(preview.tokensBefore).toBeGreaterThan(0);
      expect(preview.tokensAfter).toBeLessThan(preview.tokensBefore);
      expect(preview.compressionRatio).toBeGreaterThan(0);
      expect(preview.compressionRatio).toBeLessThan(1);

      // Messages should be unchanged
      expect(cm.getMessages().length).toBe(session.messages.length);
    });
  });
});
