/**
 * @fileoverview Slash Command Parser Tests
 */
import { describe, it, expect } from 'vitest';
import {
  SlashCommand,
  BUILT_IN_COMMANDS,
  parseSlashCommand,
  filterCommands,
  isSlashCommandInput,
} from '../../src/commands/slash-commands.js';

describe('Slash Commands', () => {
  describe('BUILT_IN_COMMANDS', () => {
    it('should have required built-in commands', () => {
      const commandNames = BUILT_IN_COMMANDS.map(c => c.name);
      expect(commandNames).toContain('model');
      expect(commandNames).toContain('help');
      expect(commandNames).toContain('clear');
    });

    it('should have valid command structure', () => {
      for (const cmd of BUILT_IN_COMMANDS) {
        expect(cmd.name).toBeTruthy();
        expect(cmd.description).toBeTruthy();
        expect(typeof cmd.name).toBe('string');
        expect(typeof cmd.description).toBe('string');
        expect(cmd.name.startsWith('/')).toBe(false); // Names shouldn't include /
      }
    });
  });

  describe('isSlashCommandInput', () => {
    it('should return true for input starting with /', () => {
      expect(isSlashCommandInput('/')).toBe(true);
      expect(isSlashCommandInput('/m')).toBe(true);
      expect(isSlashCommandInput('/model')).toBe(true);
      expect(isSlashCommandInput('/help')).toBe(true);
    });

    it('should return false for non-slash input', () => {
      expect(isSlashCommandInput('')).toBe(false);
      expect(isSlashCommandInput('hello')).toBe(false);
      expect(isSlashCommandInput('hello /model')).toBe(false);
      expect(isSlashCommandInput(' /model')).toBe(false); // Leading space
    });

    it('should handle edge cases', () => {
      expect(isSlashCommandInput('  ')).toBe(false);
      expect(isSlashCommandInput('\n/model')).toBe(false);
    });
  });

  describe('parseSlashCommand', () => {
    it('should parse command name from input', () => {
      const result = parseSlashCommand('/model');
      expect(result.commandName).toBe('model');
      expect(result.args).toEqual([]);
    });

    it('should parse command with arguments', () => {
      const result = parseSlashCommand('/model claude-3');
      expect(result.commandName).toBe('model');
      expect(result.args).toEqual(['claude-3']);
    });

    it('should parse command with multiple arguments', () => {
      const result = parseSlashCommand('/command arg1 arg2 arg3');
      expect(result.commandName).toBe('command');
      expect(result.args).toEqual(['arg1', 'arg2', 'arg3']);
    });

    it('should handle partial command input', () => {
      const result = parseSlashCommand('/mo');
      expect(result.commandName).toBe('mo');
      expect(result.args).toEqual([]);
    });

    it('should handle just /', () => {
      const result = parseSlashCommand('/');
      expect(result.commandName).toBe('');
      expect(result.args).toEqual([]);
    });

    it('should trim whitespace', () => {
      const result = parseSlashCommand('/model   claude-3  ');
      expect(result.commandName).toBe('model');
      expect(result.args).toEqual(['claude-3']);
    });
  });

  describe('filterCommands', () => {
    const testCommands: SlashCommand[] = [
      { name: 'model', description: 'Change model' },
      { name: 'help', description: 'Show help' },
      { name: 'clear', description: 'Clear screen' },
      { name: 'context', description: 'View context' },
    ];

    it('should return all commands for empty filter', () => {
      const filtered = filterCommands(testCommands, '');
      expect(filtered).toHaveLength(4);
    });

    it('should filter by prefix', () => {
      const filtered = filterCommands(testCommands, 'mo');
      expect(filtered).toHaveLength(1);
      expect(filtered[0]!.name).toBe('model');
    });

    it('should filter by partial match', () => {
      const filtered = filterCommands(testCommands, 'cl');
      expect(filtered).toHaveLength(1); // clear
      expect(filtered[0]!.name).toBe('clear');
    });

    it('should be case insensitive', () => {
      const filtered = filterCommands(testCommands, 'MODEL');
      expect(filtered).toHaveLength(1);
      expect(filtered[0]!.name).toBe('model');
    });

    it('should return empty array for no matches', () => {
      const filtered = filterCommands(testCommands, 'xyz');
      expect(filtered).toHaveLength(0);
    });

    it('should match description as well', () => {
      const filtered = filterCommands(testCommands, 'screen');
      expect(filtered).toHaveLength(1);
      expect(filtered[0]!.name).toBe('clear');
    });
  });
});
