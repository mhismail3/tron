/**
 * @fileoverview Thinking Command Tests
 *
 * Tests for model thinking/reasoning level commands.
 */
import { describe, it, expect, beforeEach } from 'vitest';
import {
  ThinkingConfig,
  parseThinkingLevel,
  getThinkingBudget,
  createThinkingCommand,
} from '../../src/commands/thinking.js';

describe('Thinking Command', () => {
  describe('parseThinkingLevel', () => {
    it('parses "off" level', () => {
      expect(parseThinkingLevel('off')).toBe('off');
    });

    it('parses "low" level', () => {
      expect(parseThinkingLevel('low')).toBe('low');
    });

    it('parses "medium" level', () => {
      expect(parseThinkingLevel('medium')).toBe('medium');
    });

    it('parses "high" level', () => {
      expect(parseThinkingLevel('high')).toBe('high');
    });

    it('is case insensitive', () => {
      expect(parseThinkingLevel('OFF')).toBe('off');
      expect(parseThinkingLevel('Low')).toBe('low');
      expect(parseThinkingLevel('MEDIUM')).toBe('medium');
      expect(parseThinkingLevel('HIGH')).toBe('high');
    });

    it('returns null for invalid levels', () => {
      expect(parseThinkingLevel('invalid')).toBeNull();
      expect(parseThinkingLevel('')).toBeNull();
      expect(parseThinkingLevel('ultra')).toBeNull();
    });
  });

  describe('getThinkingBudget', () => {
    it('returns 0 for off', () => {
      expect(getThinkingBudget('off')).toBe(0);
    });

    it('returns 1024 for low', () => {
      expect(getThinkingBudget('low')).toBe(1024);
    });

    it('returns 8192 for medium', () => {
      expect(getThinkingBudget('medium')).toBe(8192);
    });

    it('returns 32768 for high', () => {
      expect(getThinkingBudget('high')).toBe(32768);
    });
  });

  describe('ThinkingConfig', () => {
    let config: ThinkingConfig;

    beforeEach(() => {
      config = new ThinkingConfig();
    });

    it('defaults to medium level', () => {
      expect(config.level).toBe('medium');
    });

    it('updates level', () => {
      config.setLevel('high');
      expect(config.level).toBe('high');
    });

    it('returns current budget', () => {
      expect(config.budget).toBe(8192); // medium default

      config.setLevel('high');
      expect(config.budget).toBe(32768);
    });

    it('indicates if thinking is enabled', () => {
      expect(config.isEnabled).toBe(true);

      config.setLevel('off');
      expect(config.isEnabled).toBe(false);
    });
  });

  describe('createThinkingCommand', () => {
    it('creates a valid command definition', () => {
      const config = new ThinkingConfig();
      const cmd = createThinkingCommand(config);

      expect(cmd.name).toBe('thinking');
      expect(cmd.description).toBeDefined();
      expect(typeof cmd.handler).toBe('function');
    });

    it('shows current level when called without args', async () => {
      const config = new ThinkingConfig();
      const cmd = createThinkingCommand(config);

      const result = await cmd.handler('', {});

      expect(result.success).toBe(true);
      expect(result.output).toContain('medium');
    });

    it('updates level when called with valid arg', async () => {
      const config = new ThinkingConfig();
      const cmd = createThinkingCommand(config);

      const result = await cmd.handler('high', {});

      expect(result.success).toBe(true);
      expect(config.level).toBe('high');
    });

    it('returns error for invalid level', async () => {
      const config = new ThinkingConfig();
      const cmd = createThinkingCommand(config);

      const result = await cmd.handler('invalid', {});

      expect(result.success).toBe(false);
      expect(result.error).toBeDefined();
    });
  });
});
