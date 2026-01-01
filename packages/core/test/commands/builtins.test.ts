/**
 * @fileoverview Built-in Commands Tests
 */
import { describe, it, expect, vi } from 'vitest';
import {
  createHelpCommand,
  createCommandsCommand,
  createVersionCommand,
  createStatusCommand,
  createQuitCommand,
  getDefaultBuiltInCommands,
} from '../../src/commands/builtins.js';

describe('Built-in Commands', () => {
  describe('createHelpCommand', () => {
    const getCommandList = () => ['commit', 'help', 'status'];
    const getCommandHelp = (cmd: string) => {
      if (cmd === 'commit') return '# /commit\n\nCommit changes';
      return null;
    };

    it('should list commands when no args', () => {
      const cmd = createHelpCommand(getCommandList, getCommandHelp);
      const result = cmd.handler('', {});

      expect(result.success).toBe(true);
      expect(result.output).toContain('/commit');
      expect(result.output).toContain('/help');
      expect(result.requiresAgent).toBe(false);
    });

    it('should show help for specific command', () => {
      const cmd = createHelpCommand(getCommandList, getCommandHelp);
      const result = cmd.handler('commit', {});

      expect(result.success).toBe(true);
      expect(result.output).toContain('Commit changes');
    });

    it('should error for unknown command', () => {
      const cmd = createHelpCommand(getCommandList, getCommandHelp);
      const result = cmd.handler('unknown', {});

      expect(result.success).toBe(false);
      expect(result.error).toContain('Unknown command');
    });
  });

  describe('createCommandsCommand', () => {
    it('should list all commands', () => {
      const getCommandList = () => ['commit', 'export', 'help'];
      const cmd = createCommandsCommand(getCommandList);
      const result = cmd.handler('', {});

      expect(result.success).toBe(true);
      expect(result.output).toContain('/commit');
      expect(result.output).toContain('/export');
      expect(result.requiresAgent).toBe(false);
    });
  });

  describe('createVersionCommand', () => {
    it('should show version', () => {
      const cmd = createVersionCommand('1.2.3');
      const result = cmd.handler('', {});

      expect(result.success).toBe(true);
      expect(result.output).toContain('1.2.3');
    });
  });

  describe('createStatusCommand', () => {
    it('should show session status', () => {
      const cmd = createStatusCommand();
      const result = cmd.handler('', {
        sessionId: 'sess_123',
        workingDirectory: '/home/user/project',
        userId: 'user_456',
      });

      expect(result.success).toBe(true);
      expect(result.output).toContain('sess_123');
      expect(result.output).toContain('/home/user/project');
      expect(result.output).toContain('user_456');
    });

    it('should handle empty context', () => {
      const cmd = createStatusCommand();
      const result = cmd.handler('', {});

      expect(result.success).toBe(true);
      expect(result.output).toContain('Time:');
    });
  });

  describe('createQuitCommand', () => {
    it('should call onQuit handler', async () => {
      const onQuit = vi.fn();
      const cmd = createQuitCommand(onQuit);
      const result = await cmd.handler('', {});

      expect(onQuit).toHaveBeenCalled();
      expect(result.success).toBe(true);
      expect(result.output).toContain('Goodbye');
    });

    it('should handle async onQuit', async () => {
      const onQuit = vi.fn().mockResolvedValue(undefined);
      const cmd = createQuitCommand(onQuit);
      await cmd.handler('', {});

      expect(onQuit).toHaveBeenCalled();
    });
  });

  describe('getDefaultBuiltInCommands', () => {
    it('should return default commands', () => {
      const commands = getDefaultBuiltInCommands({
        version: '1.0.0',
        getCommandList: () => [],
        getCommandHelp: () => null,
      });

      const names = commands.map(c => c.name);
      expect(names).toContain('help');
      expect(names).toContain('commands');
      expect(names).toContain('version');
      expect(names).toContain('status');
    });

    it('should include quit when handler provided', () => {
      const commands = getDefaultBuiltInCommands({
        version: '1.0.0',
        getCommandList: () => [],
        getCommandHelp: () => null,
        onQuit: () => {},
      });

      const names = commands.map(c => c.name);
      expect(names).toContain('quit');
    });

    it('should not include quit when no handler', () => {
      const commands = getDefaultBuiltInCommands({
        version: '1.0.0',
        getCommandList: () => [],
        getCommandHelp: () => null,
      });

      const names = commands.map(c => c.name);
      expect(names).not.toContain('quit');
    });
  });
});
