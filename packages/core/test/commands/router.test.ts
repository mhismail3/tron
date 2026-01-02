/**
 * @fileoverview Command Router Tests
 */
import { describe, it, expect, beforeEach } from 'vitest';
import { CommandRouter, createCommandRouter } from '../../src/commands/router.js';

describe('Command Router', () => {
  let router: CommandRouter;

  beforeEach(async () => {
    router = createCommandRouter({});
    await router.initialize();
  });

  describe('parse', () => {
    it('should parse valid command', () => {
      const parsed = router.parse('/help');

      expect(parsed.isCommand).toBe(true);
      expect(parsed.command).toBe('help');
    });

    it('should parse command with args', () => {
      const parsed = router.parse('/status --verbose');

      expect(parsed.isCommand).toBe(true);
      expect(parsed.command).toBe('status');
      expect(parsed.rawArgs).toBe('--verbose');
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

    it('should handle slash prefix', () => {
      const help = router.getHelp('/help');

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
      const completions = router.getCompletions('he');

      expect(completions).toContain('help');
    });

    it('should return all for empty input', () => {
      const completions = router.getCompletions('');

      expect(completions.length).toBeGreaterThan(0);
    });
  });

  describe('custom built-in commands', () => {
    it('should register custom commands', async () => {
      const customRouter = createCommandRouter({
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
});
