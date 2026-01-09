/**
 * @fileoverview Tests for provider-aware system prompt building
 */

import { describe, it, expect } from 'vitest';
import {
  createContextManager,
  buildSystemPrompt,
  buildCodexToolClarification,
  TRON_CORE_PROMPT,
} from '../../src/context/index.js';

describe('System Prompts', () => {
  describe('TRON_CORE_PROMPT', () => {
    it('contains Tron identity', () => {
      expect(TRON_CORE_PROMPT).toContain('You are Tron');
      expect(TRON_CORE_PROMPT).toContain('AI coding assistant');
    });

    it('lists all tools', () => {
      expect(TRON_CORE_PROMPT).toContain('read:');
      expect(TRON_CORE_PROMPT).toContain('write:');
      expect(TRON_CORE_PROMPT).toContain('edit:');
      expect(TRON_CORE_PROMPT).toContain('bash:');
      expect(TRON_CORE_PROMPT).toContain('grep:');
      expect(TRON_CORE_PROMPT).toContain('find:');
      expect(TRON_CORE_PROMPT).toContain('ls:');
    });
  });

  describe('buildSystemPrompt for Anthropic', () => {
    it('includes Tron identity and working directory', () => {
      const prompt = buildSystemPrompt({
        providerType: 'anthropic',
        workingDirectory: '/home/user/project',
      });

      expect(prompt).toContain('You are Tron');
      expect(prompt).toContain('Current working directory: /home/user/project');
    });

    it('uses custom prompt when provided', () => {
      const prompt = buildSystemPrompt({
        providerType: 'anthropic',
        workingDirectory: '/home/user/project',
        customPrompt: 'You are a custom assistant.',
      });

      expect(prompt).toContain('You are a custom assistant.');
      expect(prompt).toContain('Current working directory: /home/user/project');
      expect(prompt).not.toContain('You are Tron');
    });
  });

  describe('buildSystemPrompt for OpenAI Codex', () => {
    it('returns empty string (Codex uses tool clarification instead)', () => {
      const prompt = buildSystemPrompt({
        providerType: 'openai-codex',
        workingDirectory: '/home/user/project',
      });

      expect(prompt).toBe('');
    });
  });

  describe('buildCodexToolClarification', () => {
    it('includes Tron identity', () => {
      const clarification = buildCodexToolClarification({
        providerType: 'openai-codex',
        workingDirectory: '/home/user/project',
      });

      expect(clarification).toContain('You are Tron');
      expect(clarification).toContain('[TRON CONTEXT]');
    });

    it('includes working directory', () => {
      const clarification = buildCodexToolClarification({
        providerType: 'openai-codex',
        workingDirectory: '/home/user/project',
      });

      expect(clarification).toContain('Current working directory: /home/user/project');
    });

    it('warns about unavailable tools', () => {
      const clarification = buildCodexToolClarification({
        providerType: 'openai-codex',
        workingDirectory: '/home/user/project',
      });

      expect(clarification).toContain('shell, apply_patch');
      expect(clarification).toContain('NOT available');
    });
  });

  describe('ContextManager integration', () => {
    it('builds Anthropic system prompt with working directory', () => {
      const cm = createContextManager({
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      const prompt = cm.getSystemPrompt();
      expect(prompt).toContain('You are Tron');
      expect(prompt).toContain('Current working directory: /test/project');
    });

    it('returns empty system prompt for Codex model', () => {
      const cm = createContextManager({
        model: 'gpt-5.2-codex',
        workingDirectory: '/test/project',
      });

      // Codex uses tool clarification, not system prompt
      expect(cm.getSystemPrompt()).toBe('');
    });

    it('provides tool clarification for Codex model', () => {
      const cm = createContextManager({
        model: 'gpt-5.2-codex',
        workingDirectory: '/test/project',
      });

      const clarification = cm.getToolClarificationMessage();
      expect(clarification).not.toBeNull();
      expect(clarification).toContain('You are Tron');
      expect(clarification).toContain('/test/project');
    });

    it('returns null tool clarification for Anthropic model', () => {
      const cm = createContextManager({
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      expect(cm.getToolClarificationMessage()).toBeNull();
    });

    it('updates provider type when model is switched', () => {
      const cm = createContextManager({
        model: 'claude-sonnet-4-20250514',
        workingDirectory: '/test/project',
      });

      expect(cm.getProviderType()).toBe('anthropic');
      expect(cm.getSystemPrompt()).toContain('You are Tron');

      cm.switchModel('gpt-5.2-codex');

      expect(cm.getProviderType()).toBe('openai-codex');
      expect(cm.getSystemPrompt()).toBe('');
      expect(cm.getToolClarificationMessage()).toContain('You are Tron');
    });
  });
});
