/**
 * @fileoverview TronAgent + ContextManager Integration Tests (TDD)
 *
 * Tests that verify TronAgent properly integrates with ContextManager
 * for all context management operations.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { TronAgent } from '../tron-agent.js';
import { ContextManager } from '../../context/context-manager.js';
import { ContextSimulator, createContextSimulator } from '../../context/__helpers__/context-simulator.js';
import { createMockSummarizer } from '../../context/__helpers__/mock-summarizer.js';
import type { TronTool } from '../../types/index.js';
import type { AgentConfig } from '../types.js';

// =============================================================================
// Test Fixtures
// =============================================================================

const createMockTool = (name: string): TronTool => ({
  name,
  description: `Mock tool: ${name}`,
  parameters: { type: 'object', properties: {} },
  execute: vi.fn().mockResolvedValue({ content: 'Tool result', isError: false }),
});

const createTestConfig = (): AgentConfig => ({
  provider: {
    model: 'claude-sonnet-4-20250514',
    auth: { apiKey: 'test-key' },
  },
  tools: [createMockTool('test_tool')],
  systemPrompt: 'You are a helpful assistant.',
});

// =============================================================================
// Tests
// =============================================================================

describe('TronAgent + ContextManager Integration', () => {
  describe('ContextManager Access', () => {
    it('exposes ContextManager via getContextManager()', () => {
      const agent = new TronAgent(createTestConfig());
      const cm = agent.getContextManager();

      expect(cm).toBeInstanceOf(ContextManager);
    });

    it('ContextManager has correct model', () => {
      const agent = new TronAgent(createTestConfig());
      const cm = agent.getContextManager();

      expect(cm.getModel()).toBe('claude-sonnet-4-20250514');
    });

    it('ContextManager has system prompt from config', () => {
      const agent = new TronAgent(createTestConfig());
      const cm = agent.getContextManager();

      // getSystemPrompt returns the provider-built prompt with working directory
      expect(cm.getSystemPrompt()).toContain('You are a helpful assistant.');
      // getRawSystemPrompt returns the exact config input
      expect(cm.getRawSystemPrompt()).toBe('You are a helpful assistant.');
    });

    it('ContextManager has tools from config', () => {
      const config = createTestConfig();
      config.tools = [createMockTool('tool1'), createMockTool('tool2')];

      const agent = new TronAgent(config);
      const cm = agent.getContextManager();

      expect(cm.getTools()).toHaveLength(2);
    });
  });

  describe('Message Delegation', () => {
    it('addMessage delegates to ContextManager', () => {
      const agent = new TronAgent(createTestConfig());
      const cm = agent.getContextManager();

      expect(cm.getMessages()).toHaveLength(0);

      agent.addMessage({ role: 'user', content: 'Hello' });

      expect(cm.getMessages()).toHaveLength(1);
      expect(cm.getMessages()[0].content).toBe('Hello');
    });

    it('getState().messages comes from ContextManager', () => {
      const agent = new TronAgent(createTestConfig());

      agent.addMessage({ role: 'user', content: 'Hello' });
      agent.addMessage({
        role: 'assistant',
        content: [{ type: 'text', text: 'Hi!' }],
      });

      const state = agent.getState();
      expect(state.messages).toHaveLength(2);
    });

    it('clearMessages clears ContextManager', () => {
      const agent = new TronAgent(createTestConfig());
      const cm = agent.getContextManager();

      agent.addMessage({ role: 'user', content: 'Hello' });
      expect(cm.getMessages()).toHaveLength(1);

      agent.clearMessages();
      expect(cm.getMessages()).toHaveLength(0);
    });
  });

  describe('Token Tracking', () => {
    it('provides token count via ContextManager', () => {
      const agent = new TronAgent(createTestConfig());
      const cm = agent.getContextManager();

      const beforeTokens = cm.getCurrentTokens();

      agent.addMessage({ role: 'user', content: 'Hello world' });

      expect(cm.getCurrentTokens()).toBeGreaterThan(beforeTokens);
    });

    it('provides context snapshot with usage info', () => {
      const agent = new TronAgent(createTestConfig());
      const cm = agent.getContextManager();

      agent.addMessage({ role: 'user', content: 'Hello' });

      const snapshot = cm.getSnapshot();

      expect(snapshot.currentTokens).toBeGreaterThan(0);
      expect(snapshot.contextLimit).toBe(200_000);
      expect(snapshot.usagePercent).toBeGreaterThan(0);
      expect(snapshot.thresholdLevel).toBe('normal');
    });
  });

  describe('Model Switching', () => {
    it('switchModel updates ContextManager model', () => {
      const agent = new TronAgent(createTestConfig());
      const cm = agent.getContextManager();

      expect(cm.getModel()).toBe('claude-sonnet-4-20250514');

      // Switch to another Claude model (same auth type)
      agent.switchModel('claude-opus-4-20250514');

      expect(cm.getModel()).toBe('claude-opus-4-20250514');
    });

    it('ContextManager context limit changes with model', () => {
      // Test ContextManager directly since switchModel requires compatible auth
      const agent = new TronAgent(createTestConfig());
      const cm = agent.getContextManager();

      expect(cm.getContextLimit()).toBe(200_000);

      // Directly test ContextManager's switchModel
      cm.switchModel('gpt-4o');

      expect(cm.getContextLimit()).toBe(128_000);
    });

    it('ContextManager triggers compaction callback when needed after switch', () => {
      // Test ContextManager directly since switchModel requires compatible auth
      const agent = new TronAgent(createTestConfig());
      const cm = agent.getContextManager();

      // Generate high context session (75% of 200k = 150k tokens)
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(75, 200_000);
      cm.setMessages(session.messages);

      const callback = vi.fn();
      cm.onCompactionNeeded(callback);

      // Switch to smaller model via ContextManager - should trigger callback
      cm.switchModel('gpt-4o');

      expect(callback).toHaveBeenCalled();
    });
  });

  describe('Pre-Turn Validation', () => {
    it('allows turn when context is low', () => {
      const agent = new TronAgent(createTestConfig());
      const cm = agent.getContextManager();

      agent.addMessage({ role: 'user', content: 'Hello' });

      const validation = cm.canAcceptTurn({ estimatedResponseTokens: 4000 });

      expect(validation.canProceed).toBe(true);
      expect(validation.needsCompaction).toBe(false);
    });

    it('signals compaction needed at high context', () => {
      const agent = new TronAgent(createTestConfig());
      const cm = agent.getContextManager();

      // Load high context
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);
      cm.setMessages(session.messages);

      const validation = cm.canAcceptTurn({ estimatedResponseTokens: 4000 });

      expect(validation.needsCompaction).toBe(true);
    });
  });

  describe('Compaction Support', () => {
    it('shouldCompact returns correct status', () => {
      const agent = new TronAgent(createTestConfig());
      const cm = agent.getContextManager();

      // Low context - should not compact
      agent.addMessage({ role: 'user', content: 'Hello' });
      expect(cm.shouldCompact()).toBe(false);

      // High context - should compact
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(75, 200_000);
      cm.setMessages(session.messages);
      expect(cm.shouldCompact()).toBe(true);
    });

    it('previewCompaction works via ContextManager', async () => {
      const agent = new TronAgent(createTestConfig());
      const cm = agent.getContextManager();

      // Load high context
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);
      cm.setMessages(session.messages);

      const preview = await cm.previewCompaction({
        summarizer: createMockSummarizer(),
      });

      expect(preview.tokensBefore).toBeGreaterThan(0);
      expect(preview.tokensAfter).toBeLessThan(preview.tokensBefore);
    });

    it('executeCompaction works via ContextManager', async () => {
      const agent = new TronAgent(createTestConfig());
      const cm = agent.getContextManager();

      // Load high context
      const simulator = createContextSimulator({ targetTokens: 1000 });
      const session = simulator.generateAtUtilization(80, 200_000);
      cm.setMessages(session.messages);

      const tokensBefore = cm.getCurrentTokens();
      const result = await cm.executeCompaction({
        summarizer: createMockSummarizer(),
      });

      expect(result.success).toBe(true);
      expect(cm.getCurrentTokens()).toBeLessThan(tokensBefore);
    });
  });

  describe('Tool Result Processing', () => {
    it('processToolResult preserves small results', () => {
      const agent = new TronAgent(createTestConfig());
      const cm = agent.getContextManager();

      const processed = cm.processToolResult({
        toolCallId: 'test',
        content: 'Small output',
      });

      expect(processed.content).toBe('Small output');
      expect(processed.truncated).toBe(false);
    });

    it('processToolResult truncates large results', () => {
      const agent = new TronAgent(createTestConfig());
      const cm = agent.getContextManager();

      // Use 150k chars to exceed the 100k char cap
      const largeContent = 'x'.repeat(150_000);
      const processed = cm.processToolResult({
        toolCallId: 'test',
        content: largeContent,
      });

      expect(processed.content.length).toBeLessThan(largeContent.length);
      expect(processed.truncated).toBe(true);
    });
  });

  describe('State Export/Restore', () => {
    it('exportState captures context state', () => {
      const agent = new TronAgent(createTestConfig());
      const cm = agent.getContextManager();

      agent.addMessage({ role: 'user', content: 'Hello' });

      const state = cm.exportState();

      expect(state.model).toBe('claude-sonnet-4-20250514');
      expect(state.messages).toHaveLength(1);
    });
  });
});
