/**
 * @fileoverview Tests for HookRegistry
 *
 * TDD: Tests for hook registration and lookup
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { HookRegistry } from '../registry.js';
import type { HookDefinition, RegisteredHook } from '../types.js';

describe('HookRegistry', () => {
  let registry: HookRegistry;

  const createHookDef = (overrides: Partial<HookDefinition> = {}): HookDefinition => ({
    name: 'test-hook',
    type: 'PreToolUse',
    handler: async () => ({ action: 'continue' }),
    ...overrides,
  });

  beforeEach(() => {
    registry = new HookRegistry();
  });

  describe('register', () => {
    it('registers a hook definition', () => {
      const hook = createHookDef({ name: 'test-hook' });
      registry.register(hook);

      expect(registry.get('test-hook')).toBeDefined();
      expect(registry.get('test-hook')?.type).toBe('PreToolUse');
    });

    it('replaces existing hook with same name', () => {
      const hook1 = createHookDef({ name: 'dupe', priority: 1 });
      const hook2 = createHookDef({ name: 'dupe', priority: 2 });

      registry.register(hook1);
      registry.register(hook2);

      expect(registry.get('dupe')?.priority).toBe(2);
      expect(registry.size()).toBe(1);
    });

    it('sets default priority to 0', () => {
      const hook = createHookDef({ name: 'no-priority', priority: undefined });
      registry.register(hook);

      expect(registry.get('no-priority')?.priority).toBe(0);
    });

    it('sets registeredAt timestamp', () => {
      const hook = createHookDef({ name: 'timestamped' });
      const before = new Date().toISOString();
      registry.register(hook);
      const after = new Date().toISOString();

      const registered = registry.get('timestamped');
      expect(registered?.registeredAt).toBeDefined();
      expect(registered!.registeredAt >= before).toBe(true);
      expect(registered!.registeredAt <= after).toBe(true);
    });

    it('forces blocking mode for PreToolUse hooks', () => {
      const hook = createHookDef({ name: 'bg-pre', type: 'PreToolUse', mode: 'background' });
      registry.register(hook);

      expect(registry.get('bg-pre')?.mode).toBe('blocking');
    });

    it('forces blocking mode for UserPromptSubmit hooks', () => {
      const hook = createHookDef({ name: 'bg-prompt', type: 'UserPromptSubmit', mode: 'background' });
      registry.register(hook);

      expect(registry.get('bg-prompt')?.mode).toBe('blocking');
    });

    it('forces blocking mode for PreCompact hooks', () => {
      const hook = createHookDef({ name: 'bg-compact', type: 'PreCompact', mode: 'background' });
      registry.register(hook);

      expect(registry.get('bg-compact')?.mode).toBe('blocking');
    });

    it('allows background mode for PostToolUse hooks', () => {
      const hook = createHookDef({ name: 'bg-post', type: 'PostToolUse', mode: 'background' });
      registry.register(hook);

      expect(registry.get('bg-post')?.mode).toBe('background');
    });
  });

  describe('unregister', () => {
    it('removes a hook by name', () => {
      registry.register(createHookDef({ name: 'temp' }));
      expect(registry.get('temp')).toBeDefined();

      registry.unregister('temp');
      expect(registry.get('temp')).toBeUndefined();
    });

    it('returns true when hook existed', () => {
      registry.register(createHookDef({ name: 'exists' }));
      expect(registry.unregister('exists')).toBe(true);
    });

    it('returns false when hook did not exist', () => {
      expect(registry.unregister('nonexistent')).toBe(false);
    });
  });

  describe('get', () => {
    it('returns undefined for non-existent hook', () => {
      expect(registry.get('missing')).toBeUndefined();
    });

    it('returns the registered hook', () => {
      const hook = createHookDef({ name: 'findme', priority: 10 });
      registry.register(hook);

      const found = registry.get('findme');
      expect(found?.name).toBe('findme');
      expect(found?.priority).toBe(10);
    });
  });

  describe('getByType', () => {
    beforeEach(() => {
      registry.register(createHookDef({ name: 'pre1', type: 'PreToolUse', priority: 1 }));
      registry.register(createHookDef({ name: 'pre2', type: 'PreToolUse', priority: 10 }));
      registry.register(createHookDef({ name: 'post1', type: 'PostToolUse', priority: 5 }));
    });

    it('returns hooks filtered by type', () => {
      const preHooks = registry.getByType('PreToolUse');
      expect(preHooks).toHaveLength(2);
      expect(preHooks.every(h => h.type === 'PreToolUse')).toBe(true);
    });

    it('returns hooks sorted by priority (descending)', () => {
      const preHooks = registry.getByType('PreToolUse');
      expect(preHooks[0].name).toBe('pre2'); // priority 10
      expect(preHooks[1].name).toBe('pre1'); // priority 1
    });

    it('returns empty array for type with no hooks', () => {
      const hooks = registry.getByType('SessionStart');
      expect(hooks).toEqual([]);
    });
  });

  describe('getAll', () => {
    it('returns empty array when no hooks registered', () => {
      expect(registry.getAll()).toEqual([]);
    });

    it('returns all registered hooks', () => {
      registry.register(createHookDef({ name: 'hook1' }));
      registry.register(createHookDef({ name: 'hook2' }));
      registry.register(createHookDef({ name: 'hook3' }));

      expect(registry.getAll()).toHaveLength(3);
    });
  });

  describe('clear', () => {
    it('removes all hooks', () => {
      registry.register(createHookDef({ name: 'hook1' }));
      registry.register(createHookDef({ name: 'hook2' }));

      registry.clear();

      expect(registry.size()).toBe(0);
      expect(registry.getAll()).toEqual([]);
    });
  });

  describe('size', () => {
    it('returns 0 for empty registry', () => {
      expect(registry.size()).toBe(0);
    });

    it('returns correct count after registrations', () => {
      registry.register(createHookDef({ name: 'hook1' }));
      expect(registry.size()).toBe(1);

      registry.register(createHookDef({ name: 'hook2' }));
      expect(registry.size()).toBe(2);
    });
  });
});
