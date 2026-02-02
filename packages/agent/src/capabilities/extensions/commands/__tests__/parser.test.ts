/**
 * @fileoverview Command Parser Tests
 */
import { describe, it, expect } from 'vitest';
import {
  parseCommand,
  isSlashCommand,
  extractCommandName,
  normalizeCommand,
  formatCommand,
  tokenizeArgs,
  getCommandSuggestions,
} from '../parser.js';

describe('Command Parser', () => {
  describe('parseCommand', () => {
    it('should parse simple command', () => {
      const result = parseCommand('/commit');

      expect(result.isCommand).toBe(true);
      expect(result.command).toBe('commit');
      expect(result.rawArgs).toBe('');
    });

    it('should parse command with arguments', () => {
      const result = parseCommand('/export --format json');

      expect(result.isCommand).toBe(true);
      expect(result.command).toBe('export');
      expect(result.rawArgs).toBe('--format json');
    });

    it('should handle command with dashes', () => {
      const result = parseCommand('/my-command arg1 arg2');

      expect(result.isCommand).toBe(true);
      expect(result.command).toBe('my-command');
      expect(result.rawArgs).toBe('arg1 arg2');
    });

    it('should handle command with underscores', () => {
      const result = parseCommand('/my_command');

      expect(result.isCommand).toBe(true);
      expect(result.command).toBe('my_command');
    });

    it('should normalize to lowercase', () => {
      const result = parseCommand('/COMMIT');

      expect(result.command).toBe('commit');
    });

    it('should reject non-command input', () => {
      const result = parseCommand('hello world');

      expect(result.isCommand).toBe(false);
      expect(result.command).toBe('');
    });

    it('should reject slash only', () => {
      const result = parseCommand('/');

      expect(result.isCommand).toBe(false);
    });

    it('should reject slash with number', () => {
      const result = parseCommand('/123');

      expect(result.isCommand).toBe(false);
    });

    it('should preserve original input', () => {
      const input = '/Commit --message "test"';
      const result = parseCommand(input);

      expect(result.original).toBe(input);
    });

    it('should handle whitespace', () => {
      const result = parseCommand('  /commit  arg1  ');

      expect(result.isCommand).toBe(true);
      expect(result.command).toBe('commit');
      expect(result.rawArgs).toBe('arg1');
    });
  });

  describe('isSlashCommand', () => {
    it('should return true for commands', () => {
      expect(isSlashCommand('/commit')).toBe(true);
      expect(isSlashCommand('/help foo')).toBe(true);
    });

    it('should return false for non-commands', () => {
      expect(isSlashCommand('hello')).toBe(false);
      expect(isSlashCommand('hello /world')).toBe(false);
    });
  });

  describe('extractCommandName', () => {
    it('should extract command name', () => {
      expect(extractCommandName('/commit')).toBe('commit');
      expect(extractCommandName('/help foo')).toBe('help');
    });

    it('should return null for non-commands', () => {
      expect(extractCommandName('hello')).toBeNull();
    });
  });

  describe('normalizeCommand', () => {
    it('should lowercase', () => {
      expect(normalizeCommand('COMMIT')).toBe('commit');
    });

    it('should trim', () => {
      expect(normalizeCommand('  commit  ')).toBe('commit');
    });

    it('should remove leading slash', () => {
      expect(normalizeCommand('/commit')).toBe('commit');
    });
  });

  describe('formatCommand', () => {
    it('should add leading slash', () => {
      expect(formatCommand('commit')).toBe('/commit');
    });

    it('should handle existing slash', () => {
      expect(formatCommand('/commit')).toBe('/commit');
    });

    it('should normalize', () => {
      expect(formatCommand('  COMMIT  ')).toBe('/commit');
    });
  });

  describe('tokenizeArgs', () => {
    it('should split by spaces', () => {
      const tokens = tokenizeArgs('arg1 arg2 arg3');
      expect(tokens).toEqual(['arg1', 'arg2', 'arg3']);
    });

    it('should handle quoted strings', () => {
      const tokens = tokenizeArgs('--message "hello world" --flag');
      expect(tokens).toEqual(['--message', 'hello world', '--flag']);
    });

    it('should handle single quotes', () => {
      const tokens = tokenizeArgs("--message 'hello world'");
      expect(tokens).toEqual(['--message', 'hello world']);
    });

    it('should handle empty string', () => {
      const tokens = tokenizeArgs('');
      expect(tokens).toEqual([]);
    });

    it('should handle multiple spaces', () => {
      const tokens = tokenizeArgs('arg1   arg2');
      expect(tokens).toEqual(['arg1', 'arg2']);
    });
  });

  describe('getCommandSuggestions', () => {
    const commands = ['commit', 'context', 'clear', 'export', 'help'];

    it('should filter by prefix', () => {
      const suggestions = getCommandSuggestions('co', commands);
      expect(suggestions).toContain('commit');
      expect(suggestions).toContain('context');
      expect(suggestions).not.toContain('clear');
    });

    it('should be case-insensitive', () => {
      const suggestions = getCommandSuggestions('CO', commands);
      expect(suggestions).toContain('commit');
    });

    it('should return all commands for empty input', () => {
      const suggestions = getCommandSuggestions('', commands);
      expect(suggestions).toHaveLength(commands.length);
    });

    it('should prioritize prefix matches', () => {
      const suggestions = getCommandSuggestions('c', commands);
      expect(suggestions[0]).toBe('clear');
      expect(suggestions[1]).toBe('commit');
      expect(suggestions[2]).toBe('context');
    });

    it('should handle slash prefix', () => {
      const suggestions = getCommandSuggestions('/co', commands);
      expect(suggestions).toContain('commit');
    });
  });
});
