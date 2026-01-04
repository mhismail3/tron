/**
 * @fileoverview Command Parser Tests
 */

import { describe, it, expect } from 'vitest';
import {
  isCommand,
  parseCommand,
  getPartialCommand,
  filterCommands,
  getTopMatches,
} from '../../src/commands/parser.js';

describe('Command Parser', () => {
  describe('isCommand', () => {
    it('should return true for slash commands', () => {
      expect(isCommand('/help')).toBe(true);
      expect(isCommand('/model')).toBe(true);
      expect(isCommand('/')).toBe(true);
    });

    it('should return false for non-commands', () => {
      expect(isCommand('hello')).toBe(false);
      expect(isCommand('hello /world')).toBe(false);
      expect(isCommand('')).toBe(false);
    });
  });

  describe('parseCommand', () => {
    it('should parse simple command', () => {
      const result = parseCommand('/help');

      expect(result).toEqual({
        name: 'help',
        args: [],
        raw: '/help',
      });
    });

    it('should parse command with arguments', () => {
      const result = parseCommand('/model claude-opus');

      expect(result).toEqual({
        name: 'model',
        args: ['claude-opus'],
        raw: '/model claude-opus',
      });
    });

    it('should parse command with multiple arguments', () => {
      const result = parseCommand('/search file pattern');

      expect(result).toEqual({
        name: 'search',
        args: ['file', 'pattern'],
        raw: '/search file pattern',
      });
    });

    it('should return null for non-commands', () => {
      expect(parseCommand('hello')).toBeNull();
      expect(parseCommand('')).toBeNull();
    });

    it('should return null for just slash', () => {
      expect(parseCommand('/')).toBeNull();
      expect(parseCommand('/   ')).toBeNull();
    });

    it('should normalize command name to lowercase', () => {
      const result = parseCommand('/HELP');
      expect(result?.name).toBe('help');
    });
  });

  describe('getPartialCommand', () => {
    it('should extract partial command name', () => {
      expect(getPartialCommand('/he')).toBe('he');
      expect(getPartialCommand('/model')).toBe('model');
    });

    it('should stop at space', () => {
      expect(getPartialCommand('/model claude')).toBe('model');
    });

    it('should return empty for just slash', () => {
      expect(getPartialCommand('/')).toBe('');
    });

    it('should return empty for non-commands', () => {
      expect(getPartialCommand('hello')).toBe('');
    });
  });

  describe('filterCommands', () => {
    it('should return all commands for empty query', () => {
      const matches = filterCommands('');
      expect(matches.length).toBeGreaterThan(0);
    });

    it('should filter by name prefix', () => {
      const matches = filterCommands('he');

      expect(matches.some((m) => m.command.name === 'help')).toBe(true);
    });

    it('should match by alias', () => {
      const matches = filterCommands('m');

      expect(matches.some((m) => m.command.name === 'model')).toBe(true);
    });

    it('should sort by score', () => {
      const matches = filterCommands('m');

      // First match should be 'model' with alias 'm'
      expect(matches[0]?.command.name).toBe('model');
    });

    it('should fuzzy match', () => {
      const matches = filterCommands('md');

      expect(matches.some((m) => m.command.name === 'model')).toBe(true);
    });
  });

  describe('getTopMatches', () => {
    it('should limit results', () => {
      const matches = getTopMatches('', 3);
      expect(matches.length).toBeLessThanOrEqual(3);
    });

    it('should return best matches first', () => {
      const matches = getTopMatches('help');

      expect(matches[0]?.command.name).toBe('help');
    });
  });
});
