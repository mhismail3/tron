/**
 * @fileoverview Tests for cross-provider model switching
 *
 * Verifies that context (messages, state) persists correctly when
 * switching between different models and providers mid-session.
 */

import { describe, it, expect } from 'vitest';
import { createContextManager } from '../../src/context/context-manager.js';
import type { Message } from '../../src/types/index.js';

describe('Cross-Provider Model Switching', () => {
  // Sample conversation to preserve across switches
  const sampleMessages: Message[] = [
    { role: 'user', content: 'Help me refactor this code' },
    {
      role: 'assistant',
      content: [
        { type: 'text', text: 'I\'ll help you refactor. Let me read the file first.' },
        { type: 'tool_use', id: 'tool_1', name: 'Read', arguments: { file_path: '/src/index.ts' } },
      ],
    },
    { role: 'toolResult', toolCallId: 'tool_1', content: 'export function main() { console.log("hello"); }' },
    {
      role: 'assistant',
      content: [{ type: 'text', text: 'Here are my refactoring suggestions...' }],
    },
    { role: 'user', content: 'Looks good, please apply the changes' },
  ];

  describe('Anthropic → OpenAI', () => {
    it('preserves messages when switching from Claude to GPT', () => {
      const cm = createContextManager({
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      // Add messages
      for (const msg of sampleMessages) {
        cm.addMessage(msg);
      }

      expect(cm.getMessages()).toHaveLength(5);
      expect(cm.getProviderType()).toBe('anthropic');

      // Switch to OpenAI
      cm.switchModel('gpt-4o');

      // Messages should persist
      expect(cm.getMessages()).toHaveLength(5);
      expect(cm.getProviderType()).toBe('openai');

      // Verify message content preserved
      const messages = cm.getMessages();
      expect(messages[0].content).toBe('Help me refactor this code');
      expect(messages[2].role).toBe('toolResult');
    });

    it('updates context limit when switching providers', () => {
      const cm = createContextManager({
        model: 'claude-sonnet-4-20250514', // 200k context
        workingDirectory: '/test/project',
      });

      const claudeLimit = cm.getContextLimit();
      expect(claudeLimit).toBe(200000);

      cm.switchModel('gpt-4o'); // 128k context

      const gptLimit = cm.getContextLimit();
      expect(gptLimit).toBe(128000);
    });
  });

  describe('OpenAI → OpenAI Codex', () => {
    it('preserves messages when switching to Codex', () => {
      const cm = createContextManager({
        model: 'gpt-4o',
        workingDirectory: '/test/project',
      });

      for (const msg of sampleMessages) {
        cm.addMessage(msg);
      }

      expect(cm.getProviderType()).toBe('openai');
      expect(cm.getSystemPrompt()).toContain('You are Tron');

      // Switch to Codex
      cm.switchModel('gpt-5.2-codex');

      // Messages preserved
      expect(cm.getMessages()).toHaveLength(5);
      expect(cm.getProviderType()).toBe('openai-codex');

      // System prompt changes for Codex (empty, uses tool clarification)
      expect(cm.getSystemPrompt()).toBe('');
      expect(cm.getToolClarificationMessage()).toContain('You are Tron');
    });
  });

  describe('OpenAI Codex → Anthropic', () => {
    it('preserves messages when switching from Codex to Claude', () => {
      const cm = createContextManager({
        model: 'gpt-5.2-codex',
        workingDirectory: '/test/project',
      });

      for (const msg of sampleMessages) {
        cm.addMessage(msg);
      }

      expect(cm.getProviderType()).toBe('openai-codex');

      // Switch to Claude
      cm.switchModel('claude-sonnet-4-20250514');

      // Messages preserved
      expect(cm.getMessages()).toHaveLength(5);
      expect(cm.getProviderType()).toBe('anthropic');

      // System prompt restored for Anthropic
      expect(cm.getSystemPrompt()).toContain('You are Tron');
      expect(cm.getToolClarificationMessage()).toBeNull();
    });
  });

  describe('Full Circuit: Anthropic → OpenAI → Codex → Anthropic', () => {
    it('preserves all context through multiple provider switches', () => {
      const cm = createContextManager({
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      // Add initial messages
      for (const msg of sampleMessages) {
        cm.addMessage(msg);
      }

      const originalMessages = cm.getMessages();
      expect(originalMessages).toHaveLength(5);

      // Switch 1: Anthropic → OpenAI
      cm.switchModel('gpt-4o');
      expect(cm.getProviderType()).toBe('openai');
      expect(cm.getMessages()).toHaveLength(5);

      // Add a message mid-session
      cm.addMessage({ role: 'user', content: 'Continue with next step' });
      expect(cm.getMessages()).toHaveLength(6);

      // Switch 2: OpenAI → Codex
      cm.switchModel('gpt-5.2-codex');
      expect(cm.getProviderType()).toBe('openai-codex');
      expect(cm.getMessages()).toHaveLength(6);

      // Add another message
      cm.addMessage({
        role: 'assistant',
        content: [{ type: 'text', text: 'Processing your request...' }],
      });
      expect(cm.getMessages()).toHaveLength(7);

      // Switch 3: Codex → Anthropic
      cm.switchModel('claude-sonnet-4-20250514');
      expect(cm.getProviderType()).toBe('anthropic');
      expect(cm.getMessages()).toHaveLength(7);

      // Verify all messages preserved correctly
      const finalMessages = cm.getMessages();
      expect(finalMessages[0].content).toBe('Help me refactor this code');
      expect(finalMessages[5].content).toBe('Continue with next step');
      expect(finalMessages[6].role).toBe('assistant');
    });
  });

  describe('Token Tracking Across Switches', () => {
    it('recalculates tokens with new model context limit', () => {
      const cm = createContextManager({
        model: 'claude-sonnet-4-20250514', // 200k
        workingDirectory: '/test/project',
      });

      for (const msg of sampleMessages) {
        cm.addMessage(msg);
      }

      const snapshot1 = cm.getSnapshot();
      const tokens = snapshot1.currentTokens;
      const usage1 = snapshot1.usagePercent;

      // Switch to smaller context model
      cm.switchModel('gpt-4o'); // 128k

      const snapshot2 = cm.getSnapshot();

      // Same token count
      expect(snapshot2.currentTokens).toBe(tokens);

      // Higher usage percentage (same tokens, smaller limit)
      expect(snapshot2.usagePercent).toBeGreaterThan(usage1);
    });

    it('triggers compaction callback when switching to smaller context', () => {
      const cm = createContextManager({
        model: 'claude-sonnet-4-20250514', // 200k
        workingDirectory: '/test/project',
      });

      // Fill to 75% of Claude's limit (150k tokens)
      // This is within Claude's threshold but would exceed smaller models
      const largeContent = 'x'.repeat(150000 * 4); // ~150k tokens
      cm.addMessage({ role: 'user', content: largeContent });

      let callbackCalled = false;
      cm.onCompactionNeeded(() => {
        callbackCalled = true;
      });

      // With Claude: 75% usage - within alert threshold
      expect(cm.getSnapshot().thresholdLevel).toBe('alert');

      // Switch to a model with smaller context (128k)
      // 150k tokens in 128k context = 117% - exceeded!
      cm.switchModel('gpt-4o');

      // Callback should have been triggered
      expect(callbackCalled).toBe(true);
      expect(cm.getSnapshot().thresholdLevel).toBe('exceeded');
    });
  });

  describe('Working Directory Preservation', () => {
    it('preserves working directory across model switches', () => {
      const cm = createContextManager({
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/my/special/path',
      });

      expect(cm.getWorkingDirectory()).toBe('/my/special/path');
      expect(cm.getSystemPrompt()).toContain('/my/special/path');

      cm.switchModel('gpt-4o');

      expect(cm.getWorkingDirectory()).toBe('/my/special/path');
      expect(cm.getSystemPrompt()).toContain('/my/special/path');

      cm.switchModel('gpt-5.2-codex');

      expect(cm.getWorkingDirectory()).toBe('/my/special/path');
      expect(cm.getToolClarificationMessage()).toContain('/my/special/path');
    });
  });
});
