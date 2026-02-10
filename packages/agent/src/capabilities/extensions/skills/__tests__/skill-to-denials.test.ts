/**
 * @fileoverview Skill Frontmatter to Denials Converter Tests
 *
 * Tests for converting skill frontmatter tool restrictions to ToolDenialConfig.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';

vi.mock('@infrastructure/logging/index.js', () => ({
  createLogger: vi.fn().mockReturnValue({
    debug: vi.fn(),
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
  }),
}));

import { skillFrontmatterToDenials, getSkillSubagentMode } from '../skill-to-denials.js';
import type { SkillFrontmatter } from '../types.js';

const ALL_TOOLS = ['Read', 'Write', 'Edit', 'Glob', 'Grep', 'Bash', 'SpawnSubagent'];

describe('skillFrontmatterToDenials', () => {
  describe('deny-list mode', () => {
    it('returns denied tools directly from deniedTools', () => {
      const frontmatter: SkillFrontmatter = { deniedTools: ['Bash'] };

      const result = skillFrontmatterToDenials(frontmatter, ALL_TOOLS);

      expect(result).toEqual({ tools: ['Bash'] });
    });

    it('handles multiple denied tools', () => {
      const frontmatter: SkillFrontmatter = { deniedTools: ['Bash', 'SpawnSubagent', 'Write'] };

      const result = skillFrontmatterToDenials(frontmatter, ALL_TOOLS);

      expect(result).toEqual({ tools: ['Bash', 'SpawnSubagent', 'Write'] });
    });

    it('passes through deniedPatterns as rules', () => {
      const frontmatter: SkillFrontmatter = {
        deniedTools: ['Bash'],
        deniedPatterns: [
          {
            tool: 'Read',
            denyPatterns: [{ parameter: 'file_path', patterns: ['/etc/.*'] }],
            message: 'Cannot read system files',
          },
        ],
      };

      const result = skillFrontmatterToDenials(frontmatter, ALL_TOOLS);

      expect(result).toEqual({
        tools: ['Bash'],
        rules: [
          {
            tool: 'Read',
            denyPatterns: [{ parameter: 'file_path', patterns: ['/etc/.*'] }],
            message: 'Cannot read system files',
          },
        ],
      });
    });
  });

  describe('allow-list mode', () => {
    it('computes denied tools as inverse of allowed tools', () => {
      const frontmatter: SkillFrontmatter = { allowedTools: ['Read', 'Grep'] };

      const result = skillFrontmatterToDenials(frontmatter, ALL_TOOLS);

      expect(result).toEqual({ tools: ['Write', 'Edit', 'Glob', 'Bash', 'SpawnSubagent'] });
    });

    it('returns undefined when all tools are allowed', () => {
      const frontmatter: SkillFrontmatter = { allowedTools: ALL_TOOLS };

      const result = skillFrontmatterToDenials(frontmatter, ALL_TOOLS);

      expect(result).toBeUndefined();
    });
  });

  describe('mutual exclusivity', () => {
    it('prefers deniedTools when both are specified', () => {
      const frontmatter: SkillFrontmatter = {
        deniedTools: ['Bash'],
        allowedTools: ['Read', 'Grep'],
      };

      const result = skillFrontmatterToDenials(frontmatter, ALL_TOOLS);

      expect(result).toEqual({ tools: ['Bash'] });
    });
  });

  describe('no restrictions', () => {
    it('returns undefined when neither is specified', () => {
      const frontmatter: SkillFrontmatter = {};

      const result = skillFrontmatterToDenials(frontmatter, ALL_TOOLS);

      expect(result).toBeUndefined();
    });

    it('returns undefined for empty arrays', () => {
      const frontmatter: SkillFrontmatter = { deniedTools: [], allowedTools: [] };

      const result = skillFrontmatterToDenials(frontmatter, ALL_TOOLS);

      expect(result).toBeUndefined();
    });
  });
});

describe('getSkillSubagentMode', () => {
  it('defaults to no when not specified', () => {
    expect(getSkillSubagentMode({})).toBe('no');
  });

  it('returns specified mode', () => {
    expect(getSkillSubagentMode({ subagent: 'yes' })).toBe('yes');
    expect(getSkillSubagentMode({ subagent: 'ask' })).toBe('ask');
    expect(getSkillSubagentMode({ subagent: 'no' })).toBe('no');
  });
});
