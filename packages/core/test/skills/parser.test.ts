/**
 * @fileoverview Skill Parser Tests
 */
import { describe, it, expect } from 'vitest';
import {
  parseSkillFile,
  buildSkillFromParsed,
  parseSkillArgs,
} from '../../src/skills/parser.js';
import type { Skill } from '../../src/skills/types.js';

describe('Skill Parser', () => {
  describe('parseSkillFile', () => {
    it('should parse file with frontmatter', () => {
      const content = `---
name: Test Skill
description: A test skill
command: test
---
These are the instructions.`;

      const result = parseSkillFile(content);

      expect(result.frontmatter.name).toBe('Test Skill');
      expect(result.frontmatter.description).toBe('A test skill');
      expect(result.frontmatter.command).toBe('test');
      expect(result.body).toBe('These are the instructions.');
    });

    it('should handle file without frontmatter', () => {
      const content = 'Just instructions';

      const result = parseSkillFile(content);

      expect(result.frontmatter.name).toBe('Unnamed Skill');
      expect(result.body).toBe('Just instructions');
    });

    it('should parse tags array', () => {
      const content = `---
name: Tagged Skill
description: Has tags
tags:
  - git
  - workflow
---
Instructions`;

      const result = parseSkillFile(content);

      expect(result.frontmatter.tags).toContain('git');
      expect(result.frontmatter.tags).toContain('workflow');
    });

    it('should parse arguments', () => {
      const content = `---
name: With Args
description: Has arguments
arguments:
  - name: message
    description: The message to use
    type: string
    required: true
---
Instructions`;

      const result = parseSkillFile(content);

      expect(result.frontmatter.arguments).toHaveLength(1);
      expect(result.frontmatter.arguments![0].name).toBe('message');
      expect(result.frontmatter.arguments![0].required).toBe(true);
    });

    it('should parse examples', () => {
      const content = `---
name: With Examples
description: Has examples
examples:
  - command: /skill arg1 arg2
    description: Example usage
---
Instructions`;

      const result = parseSkillFile(content);

      expect(result.frontmatter.examples).toHaveLength(1);
      expect(result.frontmatter.examples![0].command).toBe('/skill arg1 arg2');
    });
  });

  describe('buildSkillFromParsed', () => {
    it('should build skill from parsed content', () => {
      const parsed = {
        frontmatter: {
          name: 'Build Test',
          description: 'Test building',
          command: 'build-test',
          version: '1.0.0',
        },
        body: 'Do the thing.',
      };

      const skill = buildSkillFromParsed(parsed, '/path/to/skill.md');

      expect(skill.id).toBe('build-test');
      expect(skill.name).toBe('Build Test');
      expect(skill.command).toBe('build-test');
      expect(skill.instructions).toBe('Do the thing.');
      expect(skill.filePath).toBe('/path/to/skill.md');
    });

    it('should generate ID from name if no command', () => {
      const parsed = {
        frontmatter: {
          name: 'My Cool Skill',
          description: 'A skill',
        },
        body: 'Instructions',
      };

      const skill = buildSkillFromParsed(parsed);

      expect(skill.id).toBe('my-cool-skill');
    });
  });

  describe('parseSkillArgs', () => {
    const skill: Skill = {
      id: 'test',
      name: 'Test',
      description: 'Test skill',
      instructions: '',
      arguments: [
        { name: 'message', description: 'Message', type: 'string', required: true },
        { name: 'verbose', description: 'Verbose mode', type: 'boolean', required: false, default: false },
        { name: 'count', description: 'Count', type: 'number', required: false, default: 1 },
      ],
    };

    it('should parse positional arguments', () => {
      const args = parseSkillArgs(skill, 'Hello world');

      expect(args.message).toBe('Hello');
    });

    it('should parse named arguments', () => {
      const args = parseSkillArgs(skill, '--message "Hello world"');

      expect(args.message).toBe('Hello world');
    });

    it('should parse --name=value format', () => {
      const args = parseSkillArgs(skill, '--message=test');

      expect(args.message).toBe('test');
    });

    it('should apply default values', () => {
      const args = parseSkillArgs(skill, 'test');

      expect(args.verbose).toBe(false);
      expect(args.count).toBe(1);
    });

    it('should parse boolean flags', () => {
      const args = parseSkillArgs(skill, 'test --verbose');

      expect(args.verbose).toBe(true);
    });

    it('should parse number arguments', () => {
      const args = parseSkillArgs(skill, 'test --count 5');

      expect(args.count).toBe(5);
    });

    it('should handle quoted strings', () => {
      const args = parseSkillArgs(skill, '"Hello world" --verbose');

      expect(args.message).toBe('Hello world');
    });

    it('should handle empty args', () => {
      const emptySkill: Skill = {
        id: 'empty',
        name: 'Empty',
        description: 'No args',
        instructions: '',
      };

      const args = parseSkillArgs(emptySkill, '');

      expect(Object.keys(args)).toHaveLength(0);
    });
  });
});
