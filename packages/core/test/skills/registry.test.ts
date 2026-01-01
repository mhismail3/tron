/**
 * @fileoverview Skill Registry Tests
 */
import { describe, it, expect, beforeEach } from 'vitest';
import { createSkillRegistry } from '../../src/skills/registry.js';
import type { Skill } from '../../src/skills/types.js';

describe('Skill Registry', () => {
  let registry: ReturnType<typeof createSkillRegistry>;

  const testSkill: Skill = {
    id: 'test',
    name: 'Test Skill',
    description: 'A test skill',
    command: 'test-cmd',
    tags: ['testing', 'example'],
    instructions: 'Do the test.',
  };

  const anotherSkill: Skill = {
    id: 'another',
    name: 'Another Skill',
    description: 'Another test',
    command: 'another-cmd',
    instructions: 'Do another thing.',
  };

  beforeEach(() => {
    registry = createSkillRegistry();
  });

  describe('register', () => {
    it('should register a skill', () => {
      registry.register(testSkill);

      expect(registry.size).toBe(1);
      expect(registry.get('test')).toEqual(testSkill);
    });

    it('should index by command', () => {
      registry.register(testSkill);

      const found = registry.getByCommand('test-cmd');
      expect(found).toEqual(testSkill);
    });
  });

  describe('registerAll', () => {
    it('should register multiple skills', () => {
      registry.registerAll([testSkill, anotherSkill]);

      expect(registry.size).toBe(2);
    });
  });

  describe('get', () => {
    beforeEach(() => {
      registry.register(testSkill);
    });

    it('should get skill by ID', () => {
      const skill = registry.get('test');
      expect(skill).toEqual(testSkill);
    });

    it('should return undefined for non-existent ID', () => {
      const skill = registry.get('non-existent');
      expect(skill).toBeUndefined();
    });
  });

  describe('getByCommand', () => {
    beforeEach(() => {
      registry.register(testSkill);
    });

    it('should get skill by command', () => {
      const skill = registry.getByCommand('test-cmd');
      expect(skill).toEqual(testSkill);
    });

    it('should return undefined for non-existent command', () => {
      const skill = registry.getByCommand('non-existent');
      expect(skill).toBeUndefined();
    });
  });

  describe('list', () => {
    it('should list all skills', () => {
      registry.registerAll([testSkill, anotherSkill]);

      const skills = registry.list();

      expect(skills).toHaveLength(2);
      expect(skills).toContainEqual(testSkill);
      expect(skills).toContainEqual(anotherSkill);
    });
  });

  describe('listByTag', () => {
    beforeEach(() => {
      registry.registerAll([testSkill, anotherSkill]);
    });

    it('should filter by tag', () => {
      const skills = registry.listByTag('testing');

      expect(skills).toHaveLength(1);
      expect(skills[0].id).toBe('test');
    });

    it('should return empty for non-existent tag', () => {
      const skills = registry.listByTag('non-existent');

      expect(skills).toHaveLength(0);
    });
  });

  describe('listBuiltIn and listUserDefined', () => {
    it('should separate built-in and user skills', () => {
      const builtIn: Skill = { ...testSkill, id: 'builtin', builtIn: true };
      const user: Skill = { ...anotherSkill, id: 'user', builtIn: false };

      registry.registerAll([builtIn, user]);

      expect(registry.listBuiltIn()).toHaveLength(1);
      expect(registry.listBuiltIn()[0].id).toBe('builtin');

      expect(registry.listUserDefined()).toHaveLength(1);
      expect(registry.listUserDefined()[0].id).toBe('user');
    });
  });

  describe('unregister', () => {
    it('should unregister a skill', () => {
      registry.register(testSkill);
      registry.unregister('test');

      expect(registry.size).toBe(0);
      expect(registry.get('test')).toBeUndefined();
    });

    it('should remove from command index', () => {
      registry.register(testSkill);
      registry.unregister('test');

      expect(registry.getByCommand('test-cmd')).toBeUndefined();
    });

    it('should handle non-existent skill', () => {
      registry.unregister('non-existent');
      expect(registry.size).toBe(0);
    });
  });

  describe('clear', () => {
    it('should clear all skills', () => {
      registry.registerAll([testSkill, anotherSkill]);
      registry.clear();

      expect(registry.size).toBe(0);
      expect(registry.list()).toHaveLength(0);
    });
  });

  describe('search', () => {
    beforeEach(() => {
      registry.registerAll([testSkill, anotherSkill]);
    });

    it('should search by name', () => {
      const results = registry.search('Test Skill');

      expect(results).toHaveLength(1);
      expect(results[0].id).toBe('test');
    });

    it('should search by description', () => {
      const results = registry.search('another');

      expect(results).toHaveLength(1);
      expect(results[0].id).toBe('another');
    });

    it('should search by tag', () => {
      const results = registry.search('testing');

      expect(results).toHaveLength(1);
      expect(results[0].id).toBe('test');
    });

    it('should be case-insensitive', () => {
      const results = registry.search('TEST SKILL');

      expect(results).toHaveLength(1);
      expect(results[0].id).toBe('test');
    });

    it('should search by command', () => {
      const results = registry.search('another-cmd');

      expect(results).toHaveLength(1);
      expect(results[0].id).toBe('another');
    });
  });

  describe('getCommands', () => {
    it('should return all commands sorted', () => {
      registry.registerAll([testSkill, anotherSkill]);

      const commands = registry.getCommands();

      expect(commands).toEqual(['another-cmd', 'test-cmd']);
    });
  });

  describe('hasCommand', () => {
    beforeEach(() => {
      registry.register(testSkill);
    });

    it('should return true for existing command', () => {
      expect(registry.hasCommand('test-cmd')).toBe(true);
    });

    it('should return false for non-existent command', () => {
      expect(registry.hasCommand('non-existent')).toBe(false);
    });
  });

  describe('override behavior', () => {
    it('should allow user skill to override built-in', () => {
      const builtIn: Skill = { ...testSkill, builtIn: true };
      const user: Skill = { ...testSkill, description: 'User version', builtIn: false };

      registry.register(builtIn);
      registry.register(user);

      const skill = registry.get('test');
      expect(skill?.description).toBe('User version');
    });

    it('should not allow built-in to override user skill', () => {
      const user: Skill = { ...testSkill, description: 'User version', builtIn: false };
      const builtIn: Skill = { ...testSkill, builtIn: true };

      registry.register(user);
      registry.register(builtIn);

      const skill = registry.get('test');
      expect(skill?.description).toBe('User version');
    });
  });
});
