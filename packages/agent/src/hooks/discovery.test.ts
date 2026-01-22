/**
 * @fileoverview Tests for hook discovery module
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import * as fs from 'fs/promises';
import * as path from 'path';
import { discoverHooks, loadDiscoveredHooks } from '../../src/hooks/discovery.js';

// Mock fs module
vi.mock('fs/promises');

describe('Hook Discovery', () => {
  const mockReaddir = vi.mocked(fs.readdir);

  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe('discoverHooks', () => {
    it('should discover hooks from project directory', async () => {
      mockReaddir.mockImplementation(async (dir: any) => {
        if (dir.includes('.agent/hooks')) {
          return ['pre-tool-use.ts', 'session-start.js'] as any;
        }
        throw new Error('ENOENT');
      });

      const discovered = await discoverHooks({
        projectPath: '/test/project',
        includeUserHooks: false,
      });

      expect(discovered).toHaveLength(2);
      expect(discovered[0].name).toBe('project:pre-tool-use');
      expect(discovered[0].type).toBe('PreToolUse');
      expect(discovered[1].name).toBe('project:session-start');
      expect(discovered[1].type).toBe('SessionStart');
    });

    it('should handle priority prefixes in filenames', async () => {
      mockReaddir.mockImplementation(async (dir: any) => {
        if (dir.includes('.agent/hooks')) {
          return ['100-pre-tool-use.ts', '50-post-tool-use.ts'] as any;
        }
        throw new Error('ENOENT');
      });

      const discovered = await discoverHooks({
        projectPath: '/test/project',
        includeUserHooks: false,
      });

      expect(discovered[0].priority).toBe(100);
      expect(discovered[1].priority).toBe(50);
    });

    it('should identify shell scripts', async () => {
      mockReaddir.mockImplementation(async (dir: any) => {
        if (dir.includes('.agent/hooks')) {
          return ['pre-tool-use.sh'] as any;
        }
        throw new Error('ENOENT');
      });

      const discovered = await discoverHooks({
        projectPath: '/test/project',
        includeUserHooks: false,
      });

      expect(discovered[0].isShellScript).toBe(true);
    });

    it('should discover hooks from user directory', async () => {
      mockReaddir.mockImplementation(async (dir: any) => {
        if (dir.includes('.config/tron/hooks')) {
          return ['session-end.ts'] as any;
        }
        throw new Error('ENOENT');
      });

      const discovered = await discoverHooks({
        projectPath: '/test/project',
        userHome: '/home/user',
        includeUserHooks: true,
      });

      expect(discovered).toHaveLength(1);
      expect(discovered[0].source).toBe('user');
      expect(discovered[0].type).toBe('SessionEnd');
    });

    it('should discover hooks from additional paths', async () => {
      mockReaddir.mockImplementation(async (dir: any) => {
        if (dir === '/custom/hooks') {
          return ['pre-compact.ts'] as any;
        }
        throw new Error('ENOENT');
      });

      const discovered = await discoverHooks({
        projectPath: '/test/project',
        includeUserHooks: false,
        additionalPaths: ['/custom/hooks'],
      });

      expect(discovered).toHaveLength(1);
      expect(discovered[0].source).toBe('custom');
      expect(discovered[0].type).toBe('PreCompact');
    });

    it('should ignore non-hook files', async () => {
      mockReaddir.mockImplementation(async (dir: any) => {
        if (dir.includes('.agent/hooks')) {
          return [
            'pre-tool-use.ts',
            'README.md',
            'utils.ts',
            'unknown-hook.ts',
          ] as any;
        }
        throw new Error('ENOENT');
      });

      const discovered = await discoverHooks({
        projectPath: '/test/project',
        includeUserHooks: false,
      });

      // Only pre-tool-use.ts should be recognized
      expect(discovered).toHaveLength(1);
      expect(discovered[0].type).toBe('PreToolUse');
    });

    it('should filter by extensions', async () => {
      mockReaddir.mockImplementation(async (dir: any) => {
        if (dir.includes('.agent/hooks')) {
          return ['pre-tool-use.ts', 'session-start.py'] as any;
        }
        throw new Error('ENOENT');
      });

      const discovered = await discoverHooks({
        projectPath: '/test/project',
        includeUserHooks: false,
        extensions: ['.ts', '.js'],
      });

      expect(discovered).toHaveLength(1);
      expect(discovered[0].path).toContain('.ts');
    });

    it('should handle missing directories gracefully', async () => {
      mockReaddir.mockRejectedValue({ code: 'ENOENT' });

      const discovered = await discoverHooks({
        projectPath: '/test/project',
        includeUserHooks: false,
      });

      expect(discovered).toEqual([]);
    });

    it('should recognize all hook types', async () => {
      mockReaddir.mockImplementation(async (dir: any) => {
        if (dir.includes('.agent/hooks')) {
          return [
            'pre-tool-use.ts',
            'post-tool-use.ts',
            'session-start.ts',
            'session-end.ts',
            'stop.ts',
            'subagent-stop.ts',
            'user-prompt-submit.ts',
            'pre-compact.ts',
            'notification.ts',
          ] as any;
        }
        throw new Error('ENOENT');
      });

      const discovered = await discoverHooks({
        projectPath: '/test/project',
        includeUserHooks: false,
      });

      expect(discovered).toHaveLength(9);

      const types = discovered.map(h => h.type);
      expect(types).toContain('PreToolUse');
      expect(types).toContain('PostToolUse');
      expect(types).toContain('SessionStart');
      expect(types).toContain('SessionEnd');
      expect(types).toContain('Stop');
      expect(types).toContain('SubagentStop');
      expect(types).toContain('UserPromptSubmit');
      expect(types).toContain('PreCompact');
      expect(types).toContain('Notification');
    });

    it('should recognize alternative naming conventions', async () => {
      mockReaddir.mockImplementation(async (dir: any) => {
        if (dir.includes('.agent/hooks')) {
          return [
            'pre-tool.ts',    // Short form
            'post-tool.ts',
            'user-prompt.ts',
          ] as any;
        }
        throw new Error('ENOENT');
      });

      const discovered = await discoverHooks({
        projectPath: '/test/project',
        includeUserHooks: false,
      });

      expect(discovered).toHaveLength(3);
      expect(discovered.find(h => h.type === 'PreToolUse')).toBeDefined();
      expect(discovered.find(h => h.type === 'PostToolUse')).toBeDefined();
      expect(discovered.find(h => h.type === 'UserPromptSubmit')).toBeDefined();
    });
  });

  describe('loadDiscoveredHooks', () => {
    it('should create shell hook wrapper', async () => {
      const discovered = [
        {
          name: 'project:pre-tool-use',
          path: '/test/.agent/hooks/pre-tool-use.sh',
          type: 'PreToolUse' as const,
          isShellScript: true,
          source: 'project' as const,
        },
      ];

      const hooks = await loadDiscoveredHooks(discovered);

      expect(hooks).toHaveLength(1);
      expect(hooks[0].name).toBe('project:pre-tool-use');
      expect(hooks[0].type).toBe('PreToolUse');
      expect(typeof hooks[0].handler).toBe('function');
    });

    it('should set priority from discovered hook', async () => {
      const discovered = [
        {
          name: 'project:pre-tool-use',
          path: '/test/.agent/hooks/100-pre-tool-use.sh',
          type: 'PreToolUse' as const,
          isShellScript: true,
          source: 'project' as const,
          priority: 100,
        },
      ];

      const hooks = await loadDiscoveredHooks(discovered);

      expect(hooks[0].priority).toBe(100);
    });
  });
});
