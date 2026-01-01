/**
 * @fileoverview Command Router Tests
 */
import { describe, it, expect, beforeEach } from 'vitest';
import { CommandRouter, createCommandRouter } from '../../src/commands/router.js';

describe('Command Router', () => {
  let router: CommandRouter;

  beforeEach(async () => {
    router = createCommandRouter({
      skillDirs: [],
      includeBuiltInSkills: true,
    });
    await router.initialize();
  });

  describe('parse', () => {
    it('should parse valid command', () => {
      const parsed = router.parse('/help');

      expect(parsed.isCommand).toBe(true);
      expect(parsed.command).toBe('help');
    });

    it('should parse command with args', () => {
      const parsed = router.parse('/commit --message "test"');

      expect(parsed.isCommand).toBe(true);
      expect(parsed.command).toBe('commit');
      expect(parsed.rawArgs).toBe('--message "test"');
    });

    it('should reject non-commands', () => {
      const parsed = router.parse('hello world');

      expect(parsed.isCommand).toBe(false);
    });
  });

  describe('execute', () => {
    it('should execute built-in help command', async () => {
      const parsed = router.parse('/help');
      const result = await router.execute(parsed);

      expect(result.success).toBe(true);
      expect(result.output).toBeDefined();
      expect(result.requiresAgent).toBe(false);
    });

    it('should execute built-in version command', async () => {
      const parsed = router.parse('/version');
      const result = await router.execute(parsed);

      expect(result.success).toBe(true);
      expect(result.output).toContain('Tron');
    });

    it('should execute built-in status command', async () => {
      const parsed = router.parse('/status');
      const result = await router.execute(parsed, {
        sessionId: 'test_session',
      });

      expect(result.success).toBe(true);
      expect(result.output).toContain('test_session');
    });

    it('should execute skill command', async () => {
      const parsed = router.parse('/commit');
      const result = await router.execute(parsed);

      expect(result.success).toBe(true);
      expect(result.skill).toBeDefined();
      expect(result.skill!.id).toBe('commit');
      expect(result.requiresAgent).toBe(true);
    });

    it('should fail for unknown command', async () => {
      const parsed = router.parse('/nonexistent');
      const result = await router.execute(parsed);

      expect(result.success).toBe(false);
      expect(result.error).toContain('Unknown command');
    });

    it('should fail for non-command input', async () => {
      const parsed = router.parse('hello');
      const result = await router.execute(parsed);

      expect(result.success).toBe(false);
      expect(result.error).toContain('Not a valid command');
    });
  });

  describe('executeRaw', () => {
    it('should parse and execute', async () => {
      const result = await router.executeRaw('/help');

      expect(result.success).toBe(true);
    });

    it('should handle context', async () => {
      const result = await router.executeRaw('/status', {
        workingDirectory: '/test/dir',
      });

      expect(result.success).toBe(true);
      expect(result.output).toContain('/test/dir');
    });
  });

  describe('getHelp', () => {
    it('should return help for built-in command', () => {
      const help = router.getHelp('help');

      expect(help).toBeDefined();
      expect(help).toContain('/help');
    });

    it('should return help for skill command', () => {
      const help = router.getHelp('commit');

      expect(help).toBeDefined();
      expect(help).toContain('commit');
    });

    it('should handle slash prefix', () => {
      const help = router.getHelp('/commit');

      expect(help).toBeDefined();
    });

    it('should return null for unknown command', () => {
      const help = router.getHelp('nonexistent');

      expect(help).toBeNull();
    });
  });

  describe('listCommands', () => {
    it('should list all commands', () => {
      const commands = router.listCommands();

      expect(commands).toContain('help');
      expect(commands).toContain('version');
      expect(commands).toContain('commit');
    });

    it('should return sorted list', () => {
      const commands = router.listCommands();

      const sorted = [...commands].sort();
      expect(commands).toEqual(sorted);
    });
  });

  describe('hasCommand', () => {
    it('should return true for existing command', () => {
      expect(router.hasCommand('help')).toBe(true);
      expect(router.hasCommand('commit')).toBe(true);
    });

    it('should return false for non-existing command', () => {
      expect(router.hasCommand('nonexistent')).toBe(false);
    });

    it('should handle slash prefix', () => {
      expect(router.hasCommand('/help')).toBe(true);
    });
  });

  describe('getCompletions', () => {
    it('should return matching commands', () => {
      const completions = router.getCompletions('co');

      expect(completions).toContain('commit');
      expect(completions).toContain('commands');
    });

    it('should return all for empty input', () => {
      const completions = router.getCompletions('');

      expect(completions.length).toBeGreaterThan(0);
    });
  });

  describe('custom built-in commands', () => {
    it('should register custom commands', async () => {
      const customRouter = createCommandRouter({
        skillDirs: [],
        customCommands: [
          {
            name: 'custom',
            description: 'Custom command',
            isSystem: true,
            handler: () => ({
              success: true,
              output: 'Custom output',
              requiresAgent: false,
            }),
          },
        ],
      });

      await customRouter.initialize();

      const result = await customRouter.executeRaw('/custom');

      expect(result.success).toBe(true);
      expect(result.output).toBe('Custom output');
    });
  });

  describe('getRegistry', () => {
    it('should return skill registry', () => {
      const registry = router.getRegistry();

      expect(registry).toBeDefined();
      expect(registry.get('commit')).toBeDefined();
    });
  });
});
