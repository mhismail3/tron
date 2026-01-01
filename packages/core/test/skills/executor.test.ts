/**
 * @fileoverview Skill Executor Tests
 */
import { describe, it, expect } from 'vitest';
import { SkillExecutor, createSkillExecutor } from '../../src/skills/executor.js';
import type { Skill } from '../../src/skills/types.js';

describe('Skill Executor', () => {
  const executor = createSkillExecutor();

  const testSkill: Skill = {
    id: 'test-skill',
    name: 'Test Skill',
    description: 'A test skill for testing',
    command: 'test',
    arguments: [
      { name: 'message', description: 'The message', type: 'string', required: true },
      { name: 'verbose', description: 'Verbose output', type: 'boolean', required: false, default: false },
    ],
    instructions: 'Use the message: {{message}}',
  };

  describe('execute', () => {
    it('should execute skill successfully', async () => {
      const result = await executor.execute(testSkill, 'hello');

      expect(result.success).toBe(true);
      expect(result.prompt).toBeDefined();
      expect(result.prompt).toContain('Test Skill');
    });

    it('should parse and include arguments', async () => {
      const result = await executor.execute(testSkill, '--message "Hello world"');

      expect(result.success).toBe(true);
      expect(result.context?.args).toEqual({
        message: 'Hello world',
        verbose: false,
      });
    });

    it('should replace argument placeholders', async () => {
      const result = await executor.execute(testSkill, '--message test-value');

      expect(result.success).toBe(true);
      expect(result.prompt).toContain('test-value');
    });

    it('should fail for missing required argument', async () => {
      const result = await executor.execute(testSkill, '--verbose');

      expect(result.success).toBe(false);
      expect(result.error).toContain('Missing required argument');
    });

    it('should include context in prompt', async () => {
      const result = await executor.execute(testSkill, 'test', {
        workingDirectory: '/test/dir',
        sessionId: 'sess_123',
      });

      expect(result.success).toBe(true);
      expect(result.prompt).toContain('/test/dir');
      expect(result.prompt).toContain('sess_123');
    });

    it('should handle skill with no arguments', async () => {
      const noArgSkill: Skill = {
        id: 'no-args',
        name: 'No Args',
        description: 'No arguments',
        instructions: 'Just do it.',
      };

      const result = await executor.execute(noArgSkill);

      expect(result.success).toBe(true);
    });
  });

  describe('execute with choices', () => {
    const choiceSkill: Skill = {
      id: 'choice-skill',
      name: 'Choice Skill',
      description: 'Has choices',
      arguments: [
        {
          name: 'format',
          description: 'Output format',
          type: 'string',
          required: true,
          choices: ['json', 'xml', 'yaml'],
        },
      ],
      instructions: 'Format: {{format}}',
    };

    it('should accept valid choice', async () => {
      const result = await executor.execute(choiceSkill, '--format json');

      expect(result.success).toBe(true);
    });

    it('should reject invalid choice', async () => {
      const result = await executor.execute(choiceSkill, '--format csv');

      expect(result.success).toBe(false);
      expect(result.error).toContain('Invalid value');
    });
  });

  describe('getHelp', () => {
    it('should generate help text', () => {
      const help = executor.getHelp(testSkill);

      expect(help).toContain('Test Skill');
      expect(help).toContain('A test skill');
      expect(help).toContain('/test');
      expect(help).toContain('message');
      expect(help).toContain('verbose');
    });

    it('should include examples', () => {
      const skillWithExamples: Skill = {
        ...testSkill,
        examples: [
          { command: '/test hello', description: 'Simple test' },
          { command: '/test --verbose hello' },
        ],
      };

      const help = executor.getHelp(skillWithExamples);

      expect(help).toContain('Examples');
      expect(help).toContain('/test hello');
      expect(help).toContain('Simple test');
    });

    it('should include tags', () => {
      const taggedSkill: Skill = {
        ...testSkill,
        tags: ['workflow', 'utility'],
      };

      const help = executor.getHelp(taggedSkill);

      expect(help).toContain('Tags');
      expect(help).toContain('workflow');
    });
  });
});
