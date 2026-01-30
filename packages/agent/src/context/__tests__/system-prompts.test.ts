/**
 * @fileoverview Tests for provider-aware system prompt building
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { mkdirSync, writeFileSync, rmSync, existsSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';
import {
  createContextManager,
  buildSystemPrompt,
  buildCodexToolClarification,
  TRON_CORE_PROMPT,
  loadSystemPromptFromFileSync,
} from '../index.js';

describe('System Prompts', () => {
  describe('TRON_CORE_PROMPT', () => {
    it('contains Tron identity', () => {
      expect(TRON_CORE_PROMPT).toContain('You are Tron');
      expect(TRON_CORE_PROMPT).toContain('general-purpose computer agent');
    });

    it('is the default prompt loaded from core.md', () => {
      // TRON_CORE_PROMPT is loaded from core.md at module initialization.
      // Users can override via project .tron/SYSTEM.md
      expect(TRON_CORE_PROMPT).toContain('provided tools');
      // Should have tool documentation
      expect(TRON_CORE_PROMPT).toContain('Read');
      expect(TRON_CORE_PROMPT).toContain('Write');
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

  describe('SYSTEM.md File Loading', () => {
    let testTmpDir: string;
    let testProjectDir: string;

    beforeEach(() => {
      // Create temporary directories for testing
      testTmpDir = join(tmpdir(), `tron-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
      testProjectDir = join(testTmpDir, 'project');

      mkdirSync(testProjectDir, { recursive: true });
      mkdirSync(join(testProjectDir, '.tron'), { recursive: true });
    });

    afterEach(() => {
      // Clean up test directories
      if (existsSync(testTmpDir)) {
        rmSync(testTmpDir, { recursive: true, force: true });
      }
    });

    describe('loadSystemPromptFromFileSync', () => {
      it('returns null when no SYSTEM.md file exists', () => {
        const result = loadSystemPromptFromFileSync({
          workingDirectory: testProjectDir,
        });

        expect(result).toBeNull();
      });

      it('loads project SYSTEM.md when it exists', () => {
        const projectPrompt = 'You are a project assistant.';
        writeFileSync(join(testProjectDir, '.tron', 'SYSTEM.md'), projectPrompt);

        const result = loadSystemPromptFromFileSync({
          workingDirectory: testProjectDir,
        });

        expect(result).not.toBeNull();
        expect(result?.content).toBe(projectPrompt);
        expect(result?.source).toBe('project');
      });

      it('handles empty SYSTEM.md files', () => {
        writeFileSync(join(testProjectDir, '.tron', 'SYSTEM.md'), '');

        const result = loadSystemPromptFromFileSync({
          workingDirectory: testProjectDir,
        });

        expect(result).not.toBeNull();
        expect(result?.content).toBe('');
        expect(result?.source).toBe('project');
      });

      it('rejects files larger than 100KB', () => {
        // Create a file larger than 100KB
        const largeContent = 'x'.repeat(101 * 1024);
        writeFileSync(join(testProjectDir, '.tron', 'SYSTEM.md'), largeContent);

        const result = loadSystemPromptFromFileSync({
          workingDirectory: testProjectDir,
        });

        // Should return null for oversized files
        expect(result).toBeNull();
      });

      it('handles files with whitespace correctly', () => {
        const promptWithWhitespace = '  You are an assistant.\n\n  With formatting.  ';
        writeFileSync(join(testProjectDir, '.tron', 'SYSTEM.md'), promptWithWhitespace);

        const result = loadSystemPromptFromFileSync({
          workingDirectory: testProjectDir,
        });

        expect(result).not.toBeNull();
        expect(result?.content).toBe(promptWithWhitespace);
      });

      it('returns null when working directory does not exist', () => {
        const result = loadSystemPromptFromFileSync({
          workingDirectory: '/definitely/does/not/exist',
        });

        expect(result).toBeNull();
      });

      it('handles multiline prompts correctly', () => {
        const multilinePrompt = `You are Tron, a specialized assistant.

You have access to:
- read
- write
- edit

Follow these guidelines:
1. Be concise
2. Be accurate`;

        writeFileSync(join(testProjectDir, '.tron', 'SYSTEM.md'), multilinePrompt);

        const result = loadSystemPromptFromFileSync({
          workingDirectory: testProjectDir,
        });

        expect(result).not.toBeNull();
        expect(result?.content).toBe(multilinePrompt);
        expect(result?.content).toContain('You are Tron');
        expect(result?.content).toContain('Follow these guidelines');
      });
    });

    describe('ContextManager with file-based prompts', () => {
      it('loads and uses project SYSTEM.md', () => {
        const projectPrompt = 'You are a custom project assistant.';
        writeFileSync(join(testProjectDir, '.tron', 'SYSTEM.md'), projectPrompt);

        const cm = createContextManager({
          model: 'claude-sonnet-4-20250514',
          workingDirectory: testProjectDir,
        });

        const prompt = cm.getSystemPrompt();
        expect(prompt).toContain('You are a custom project assistant.');
        expect(prompt).toContain(`Current working directory: ${testProjectDir}`);
      });

      it('falls back to core.md prompt when no project SYSTEM.md exists', () => {
        const cm = createContextManager({
          model: 'claude-sonnet-4-20250514',
          workingDirectory: testProjectDir,
        });

        const prompt = cm.getSystemPrompt();
        expect(prompt).toContain('You are Tron');
        expect(prompt).toContain('general-purpose computer agent');
      });

      it('prioritizes programmatic systemPrompt over file-based', () => {
        const projectPrompt = 'Project assistant.';
        const programmaticPrompt = 'Programmatic assistant.';

        writeFileSync(join(testProjectDir, '.tron', 'SYSTEM.md'), projectPrompt);

        const cm = createContextManager({
          model: 'claude-sonnet-4-20250514',
          workingDirectory: testProjectDir,
          systemPrompt: programmaticPrompt,
        });

        const prompt = cm.getSystemPrompt();
        expect(prompt).toContain('Programmatic assistant.');
        expect(prompt).not.toContain('Project assistant.');
      });

      it('works with OpenAI models', () => {
        const customPrompt = 'You are a custom OpenAI assistant.';
        writeFileSync(join(testProjectDir, '.tron', 'SYSTEM.md'), customPrompt);

        const cm = createContextManager({
          model: 'gpt-4',
          workingDirectory: testProjectDir,
        });

        const prompt = cm.getSystemPrompt();
        expect(prompt).toContain('You are a custom OpenAI assistant.');
      });

      it('works with Google models', () => {
        const customPrompt = 'You are a custom Google assistant.';
        writeFileSync(join(testProjectDir, '.tron', 'SYSTEM.md'), customPrompt);

        const cm = createContextManager({
          model: 'gemini-2.0-flash-exp',
          workingDirectory: testProjectDir,
        });

        const prompt = cm.getSystemPrompt();
        expect(prompt).toContain('You are a custom Google assistant.');
      });

      it('works with OpenAI Codex tool clarification', () => {
        const customPrompt = 'You are a custom Codex assistant.';
        writeFileSync(join(testProjectDir, '.tron', 'SYSTEM.md'), customPrompt);

        const cm = createContextManager({
          model: 'gpt-5.2-codex',
          workingDirectory: testProjectDir,
        });

        // Codex returns empty system prompt
        expect(cm.getSystemPrompt()).toBe('');

        // But custom prompt should be in tool clarification
        const clarification = cm.getToolClarificationMessage();
        expect(clarification).toContain('You are a custom Codex assistant.');
        expect(clarification).toContain('[TRON CONTEXT]');
      });

      it('handles file-based prompts with model switching', () => {
        const customPrompt = 'You are a custom assistant.';
        writeFileSync(join(testProjectDir, '.tron', 'SYSTEM.md'), customPrompt);

        const cm = createContextManager({
          model: 'claude-sonnet-4-20250514',
          workingDirectory: testProjectDir,
        });

        // Initially Anthropic
        expect(cm.getSystemPrompt()).toContain('You are a custom assistant.');

        // Switch to Codex
        cm.switchModel('gpt-5.2-codex');
        expect(cm.getSystemPrompt()).toBe('');
        expect(cm.getToolClarificationMessage()).toContain('You are a custom assistant.');

        // Switch back to Anthropic
        cm.switchModel('claude-sonnet-4-20250514');
        expect(cm.getSystemPrompt()).toContain('You are a custom assistant.');
      });

      it('getRawSystemPrompt returns file-based prompt', () => {
        const customPrompt = 'You are a custom assistant.';
        writeFileSync(join(testProjectDir, '.tron', 'SYSTEM.md'), customPrompt);

        const cm = createContextManager({
          model: 'claude-sonnet-4-20250514',
          workingDirectory: testProjectDir,
        });

        expect(cm.getRawSystemPrompt()).toBe('You are a custom assistant.');
      });

      it('getRawSystemPrompt returns core.md prompt when no files', () => {
        const cm = createContextManager({
          model: 'claude-sonnet-4-20250514',
          workingDirectory: testProjectDir,
        });

        expect(cm.getRawSystemPrompt()).toBe(TRON_CORE_PROMPT);
      });
    });
  });
});
