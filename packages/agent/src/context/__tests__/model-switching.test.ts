/**
 * @fileoverview Tests for cross-provider model switching
 *
 * Verifies that context (messages, state) persists correctly when
 * switching between different models and providers mid-session.
 */

import { describe, it, expect } from 'vitest';
import { createContextManager } from '../context-manager.js';
import type { Message } from '../../types/index.js';

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

  describe('Anthropic → OpenAI Codex', () => {
    it('preserves messages when switching from Claude to Codex', () => {
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

      // Switch to OpenAI Codex
      cm.switchModel('gpt-5.3-codex');

      // Messages should persist
      expect(cm.getMessages()).toHaveLength(5);
      expect(cm.getProviderType()).toBe('openai-codex');

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

      cm.switchModel('gpt-5.3-codex'); // 400k context

      const codexLimit = cm.getContextLimit();
      expect(codexLimit).toBe(400000);
    });
  });

  describe('Codex → Codex (model upgrade)', () => {
    it('preserves messages when switching between Codex models', () => {
      const cm = createContextManager({
        model: 'gpt-5.2-codex',
        workingDirectory: '/test/project',
      });

      for (const msg of sampleMessages) {
        cm.addMessage(msg);
      }

      expect(cm.getProviderType()).toBe('openai-codex');

      // Switch to newer Codex
      cm.switchModel('gpt-5.3-codex');

      // Messages preserved
      expect(cm.getMessages()).toHaveLength(5);
      expect(cm.getProviderType()).toBe('openai-codex');

      // System prompt stays empty for Codex (uses tool clarification)
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

  describe('Full Circuit: Anthropic → Codex → Gemini → Anthropic', () => {
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

      // Switch 1: Anthropic → Codex
      cm.switchModel('gpt-5.3-codex');
      expect(cm.getProviderType()).toBe('openai-codex');
      expect(cm.getMessages()).toHaveLength(5);

      // Add a message mid-session
      cm.addMessage({ role: 'user', content: 'Continue with next step' });
      expect(cm.getMessages()).toHaveLength(6);

      // Switch 2: Codex → Gemini
      cm.switchModel('gemini-2.5-pro');
      expect(cm.getProviderType()).toBe('google');
      expect(cm.getMessages()).toHaveLength(6);

      // Add another message
      cm.addMessage({
        role: 'assistant',
        content: [{ type: 'text', text: 'Processing your request...' }],
      });
      expect(cm.getMessages()).toHaveLength(7);

      // Switch 3: Gemini → Anthropic
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
        model: 'gpt-5.3-codex', // 400k
        workingDirectory: '/test/project',
      });

      for (const msg of sampleMessages) {
        cm.addMessage(msg);
      }

      // Simulate API reporting token usage after a turn
      const tokens = 50000; // Simulate 50k tokens used
      cm.setApiContextTokens(tokens);

      const snapshot1 = cm.getSnapshot();
      const usage1 = snapshot1.usagePercent;
      expect(snapshot1.currentTokens).toBe(tokens);

      // Switch to smaller context model
      cm.switchModel('claude-sonnet-4-20250514'); // 200k

      // API tokens persist across model switch
      cm.setApiContextTokens(tokens);

      const snapshot2 = cm.getSnapshot();

      // Same token count
      expect(snapshot2.currentTokens).toBe(tokens);

      // Higher usage percentage (same tokens, smaller limit)
      expect(snapshot2.usagePercent).toBeGreaterThan(usage1);
    });

    it('triggers compaction callback when switching to smaller context', () => {
      const cm = createContextManager({
        model: 'gpt-5.3-codex', // 400k
        workingDirectory: '/test/project',
      });

      // Fill to 60% of Codex limit (240k tokens)
      const largeContent = 'x'.repeat(240000 * 4);
      cm.addMessage({ role: 'user', content: largeContent });

      // Simulate API reporting 240k tokens after turn
      cm.setApiContextTokens(240000);

      let callbackCalled = false;
      cm.onCompactionNeeded(() => {
        callbackCalled = true;
      });

      // With Codex: 60% usage - within warning threshold
      expect(cm.getSnapshot().thresholdLevel).toBe('warning');

      // Switch to Claude (200k context)
      // 240k tokens in 200k context = 120% - exceeded!
      cm.switchModel('claude-sonnet-4-20250514');

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

      cm.switchModel('gpt-5.2-codex');

      expect(cm.getWorkingDirectory()).toBe('/my/special/path');
      expect(cm.getToolClarificationMessage()).toContain('/my/special/path');

      cm.switchModel('gpt-5.3-codex');

      expect(cm.getWorkingDirectory()).toBe('/my/special/path');
      expect(cm.getToolClarificationMessage()).toContain('/my/special/path');
    });
  });

  // ===========================================================================
  // Gemini Model Switching Tests
  // ===========================================================================

  describe('Anthropic → Google Gemini', () => {
    it('preserves messages when switching from Claude to Gemini', () => {
      const cm = createContextManager({
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      for (const msg of sampleMessages) {
        cm.addMessage(msg);
      }

      expect(cm.getMessages()).toHaveLength(5);
      expect(cm.getProviderType()).toBe('anthropic');

      // Switch to Gemini
      cm.switchModel('gemini-3-pro-preview');

      // Messages should persist
      expect(cm.getMessages()).toHaveLength(5);
      expect(cm.getProviderType()).toBe('google');

      // Verify message content preserved
      const messages = cm.getMessages();
      expect(messages[0].content).toBe('Help me refactor this code');
      expect(messages[2].role).toBe('toolResult');
    });

    it('updates context limit when switching (200k Claude → 1M Gemini)', () => {
      const cm = createContextManager({
        model: 'claude-sonnet-4-20250514', // 200k context
        workingDirectory: '/test/project',
      });

      const claudeLimit = cm.getContextLimit();
      expect(claudeLimit).toBe(200000);

      // Switch to Gemini 3 Pro (1M context)
      cm.switchModel('gemini-3-pro-preview');

      const geminiLimit = cm.getContextLimit();
      expect(geminiLimit).toBe(1048576);
    });
  });

  describe('Google Gemini → Anthropic', () => {
    it('preserves messages when switching from Gemini to Claude', () => {
      const cm = createContextManager({
        model: 'gemini-3-pro-preview',
        workingDirectory: '/test/project',
      });

      for (const msg of sampleMessages) {
        cm.addMessage(msg);
      }

      expect(cm.getProviderType()).toBe('google');

      // Switch to Claude
      cm.switchModel('claude-sonnet-4-20250514');

      // Messages preserved
      expect(cm.getMessages()).toHaveLength(5);
      expect(cm.getProviderType()).toBe('anthropic');

      // System prompt works for Anthropic
      expect(cm.getSystemPrompt()).toContain('You are Tron');
    });

    it('handles context limit decrease when switching from Gemini to Claude', () => {
      const cm = createContextManager({
        model: 'gemini-3-pro-preview', // 1M context
        workingDirectory: '/test/project',
      });

      const geminiLimit = cm.getContextLimit();
      expect(geminiLimit).toBe(1048576);

      // Switch to Claude (200k context)
      cm.switchModel('claude-sonnet-4-20250514');

      const claudeLimit = cm.getContextLimit();
      expect(claudeLimit).toBe(200000);
    });
  });

  describe('Full Circuit with Gemini', () => {
    it('preserves context: Anthropic → Gemini → Codex → Anthropic', () => {
      const cm = createContextManager({
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      // Add initial messages
      for (const msg of sampleMessages) {
        cm.addMessage(msg);
      }

      const originalCount = cm.getMessages().length;
      expect(originalCount).toBe(5);

      // Switch 1: Anthropic → Gemini
      cm.switchModel('gemini-3-pro-preview');
      expect(cm.getProviderType()).toBe('google');
      expect(cm.getMessages()).toHaveLength(5);
      expect(cm.getContextLimit()).toBe(1048576);

      // Add a message mid-session
      cm.addMessage({ role: 'user', content: 'Continue with Gemini' });
      expect(cm.getMessages()).toHaveLength(6);

      // Switch 2: Gemini → Codex
      cm.switchModel('gpt-5.2-codex');
      expect(cm.getProviderType()).toBe('openai-codex');
      expect(cm.getMessages()).toHaveLength(6);

      // Add another message
      cm.addMessage({
        role: 'assistant',
        content: [{ type: 'text', text: 'Processing with Codex...' }],
      });
      expect(cm.getMessages()).toHaveLength(7);

      // Switch 3: Codex → Anthropic
      cm.switchModel('claude-sonnet-4-20250514');
      expect(cm.getProviderType()).toBe('anthropic');
      expect(cm.getMessages()).toHaveLength(7);

      // Verify all messages preserved correctly
      const finalMessages = cm.getMessages();
      expect(finalMessages[0].content).toBe('Help me refactor this code');
      expect(finalMessages[5].content).toBe('Continue with Gemini');
      expect(finalMessages[6].role).toBe('assistant');
    });
  });

  describe('Gemini Context Compaction Trigger', () => {
    it('triggers compaction when switching from Gemini (1M) to Claude (200k) with large context', () => {
      const cm = createContextManager({
        model: 'gemini-3-pro-preview', // 1M context
        workingDirectory: '/test/project',
      });

      // Fill to 30% of Gemini's limit (~300k tokens)
      const largeContent = 'x'.repeat(300000 * 4);
      cm.addMessage({ role: 'user', content: largeContent });

      // Simulate API reporting 300k tokens after turn
      cm.setApiContextTokens(300000);

      let callbackCalled = false;
      cm.onCompactionNeeded(() => {
        callbackCalled = true;
      });

      // With Gemini: 30% usage - normal threshold
      expect(cm.getSnapshot().thresholdLevel).toBe('normal');

      // Switch to Claude (200k context)
      // 300k tokens in 200k context = 150% - exceeded!
      cm.switchModel('claude-sonnet-4-20250514');

      // Callback should have been triggered
      expect(callbackCalled).toBe(true);
      expect(cm.getSnapshot().thresholdLevel).toBe('exceeded');
    });
  });
});
