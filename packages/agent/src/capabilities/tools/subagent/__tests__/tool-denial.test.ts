/**
 * @fileoverview Tests for Tool Denial System
 *
 * Comprehensive tests for the denial-based tool access control:
 * 1. Full tool denial by name
 * 2. denyAll for text-generation-only agents
 * 3. Granular parameter pattern matching
 * 4. Tool filtering
 * 5. Denial config merging (inheritance)
 */
import { describe, it, expect } from 'vitest';
import {
  checkToolDenial,
  filterToolsByDenial,
  mergeToolDenials,
  type ToolDenialConfig,
  type ToolDenialRule,
} from '../tool-denial.js';

// =============================================================================
// Tests: checkToolDenial
// =============================================================================

describe('checkToolDenial', () => {
  describe('no denial config', () => {
    it('allows all tool calls when config is undefined', () => {
      const result = checkToolDenial('Bash', { command: 'ls -la' }, undefined);
      expect(result.denied).toBe(false);
    });
  });

  describe('denyAll', () => {
    it('denies all tools when denyAll is true', () => {
      const config: ToolDenialConfig = { denyAll: true };

      const bashResult = checkToolDenial('Bash', { command: 'ls' }, config);
      const readResult = checkToolDenial('Read', { file_path: '/tmp/test' }, config);
      const writeResult = checkToolDenial('Write', { file_path: '/tmp/out', content: 'hi' }, config);

      expect(bashResult.denied).toBe(true);
      expect(bashResult.reason).toContain('All tools are denied');
      expect(readResult.denied).toBe(true);
      expect(writeResult.denied).toBe(true);
    });

    it('denyAll takes precedence over other settings', () => {
      const config: ToolDenialConfig = {
        denyAll: true,
        tools: [], // Empty tools list shouldn't matter
      };

      const result = checkToolDenial('Read', { file_path: '/tmp/test' }, config);
      expect(result.denied).toBe(true);
    });
  });

  describe('tool denial by name', () => {
    it('denies tools listed in tools array', () => {
      const config: ToolDenialConfig = {
        tools: ['Bash', 'Write', 'SpawnSubagent'],
      };

      expect(checkToolDenial('Bash', { command: 'ls' }, config).denied).toBe(true);
      expect(checkToolDenial('Write', { file_path: '/tmp/x' }, config).denied).toBe(true);
      expect(checkToolDenial('SpawnSubagent', { task: 'test' }, config).denied).toBe(true);
    });

    it('allows tools not in the denied list', () => {
      const config: ToolDenialConfig = {
        tools: ['Bash', 'Write'],
      };

      expect(checkToolDenial('Read', { file_path: '/tmp/test' }, config).denied).toBe(false);
      expect(checkToolDenial('Search', { pattern: 'foo' }, config).denied).toBe(false);
      expect(checkToolDenial('Edit', { file_path: '/tmp/x' }, config).denied).toBe(false);
    });

    it('includes tool name in denial reason', () => {
      const config: ToolDenialConfig = { tools: ['Bash'] };

      const result = checkToolDenial('Bash', { command: 'ls' }, config);
      expect(result.reason).toContain('Bash');
      expect(result.reason).toContain('not available');
    });
  });

  describe('granular pattern matching', () => {
    it('denies tool calls matching parameter patterns', () => {
      const config: ToolDenialConfig = {
        rules: [
          {
            tool: 'Bash',
            denyPatterns: [
              { parameter: 'command', patterns: ['rm\\s+-rf', 'sudo\\s+'] },
            ],
          },
        ],
      };

      expect(checkToolDenial('Bash', { command: 'rm -rf /' }, config).denied).toBe(true);
      expect(checkToolDenial('Bash', { command: 'sudo apt install' }, config).denied).toBe(true);
      expect(checkToolDenial('Bash', { command: 'ls -la' }, config).denied).toBe(false);
    });

    it('denies file path patterns for Read tool', () => {
      const config: ToolDenialConfig = {
        rules: [
          {
            tool: 'Read',
            denyPatterns: [
              { parameter: 'file_path', patterns: ['\\.env$', '\\.ssh/', '/etc/shadow'] },
            ],
          },
        ],
      };

      expect(checkToolDenial('Read', { file_path: '/app/.env' }, config).denied).toBe(true);
      expect(checkToolDenial('Read', { file_path: '/home/user/.ssh/id_rsa' }, config).denied).toBe(true);
      expect(checkToolDenial('Read', { file_path: '/etc/shadow' }, config).denied).toBe(true);
      expect(checkToolDenial('Read', { file_path: '/tmp/test.txt' }, config).denied).toBe(false);
    });

    it('is case-insensitive by default', () => {
      const config: ToolDenialConfig = {
        rules: [
          {
            tool: 'Bash',
            denyPatterns: [
              { parameter: 'command', patterns: ['sudo'] },
            ],
          },
        ],
      };

      expect(checkToolDenial('Bash', { command: 'SUDO apt' }, config).denied).toBe(true);
      expect(checkToolDenial('Bash', { command: 'Sudo apt' }, config).denied).toBe(true);
    });

    it('uses custom denial message when provided', () => {
      const config: ToolDenialConfig = {
        rules: [
          {
            tool: 'Bash',
            denyPatterns: [
              { parameter: 'command', patterns: ['rm\\s+-rf'] },
            ],
            message: 'Recursive file deletion is not allowed for safety',
          },
        ],
      };

      const result = checkToolDenial('Bash', { command: 'rm -rf /' }, config);
      expect(result.denied).toBe(true);
      expect(result.reason).toBe('Recursive file deletion is not allowed for safety');
    });

    it('only applies rules to matching tool names', () => {
      const config: ToolDenialConfig = {
        rules: [
          {
            tool: 'Bash',
            denyPatterns: [
              { parameter: 'command', patterns: ['dangerous'] },
            ],
          },
        ],
      };

      // Rule is for Bash, should not affect Write
      const result = checkToolDenial('Write', { content: 'dangerous stuff' }, config);
      expect(result.denied).toBe(false);
    });

    it('handles missing parameters gracefully', () => {
      const config: ToolDenialConfig = {
        rules: [
          {
            tool: 'Bash',
            denyPatterns: [
              { parameter: 'command', patterns: ['rm'] },
            ],
          },
        ],
      };

      // No 'command' parameter provided
      const result = checkToolDenial('Bash', { timeout: 5000 }, config);
      expect(result.denied).toBe(false);
    });

    it('handles invalid regex patterns gracefully', () => {
      const config: ToolDenialConfig = {
        rules: [
          {
            tool: 'Bash',
            denyPatterns: [
              { parameter: 'command', patterns: ['[invalid(regex', 'valid'] },
            ],
          },
        ],
      };

      // Should skip invalid pattern and check valid one
      const result = checkToolDenial('Bash', { command: 'valid command' }, config);
      expect(result.denied).toBe(true);
    });
  });

  describe('combined tool denial and rules', () => {
    it('checks both tool denial and rules', () => {
      const config: ToolDenialConfig = {
        tools: ['SpawnSubagent'], // Deny entirely
        rules: [
          {
            tool: 'Bash',
            denyPatterns: [
              { parameter: 'command', patterns: ['sudo'] },
            ],
          },
        ],
      };

      // Tool denial
      expect(checkToolDenial('SpawnSubagent', { task: 'test' }, config).denied).toBe(true);

      // Rule denial
      expect(checkToolDenial('Bash', { command: 'sudo ls' }, config).denied).toBe(true);

      // Neither
      expect(checkToolDenial('Bash', { command: 'ls' }, config).denied).toBe(false);
      expect(checkToolDenial('Read', { file_path: '/tmp/x' }, config).denied).toBe(false);
    });
  });
});

// =============================================================================
// Tests: filterToolsByDenial
// =============================================================================

describe('filterToolsByDenial', () => {
  const mockTools = [
    { name: 'Read' },
    { name: 'Write' },
    { name: 'Edit' },
    { name: 'Bash' },
    { name: 'Search' },
    { name: 'SpawnSubagent' },
  ];

  it('returns all tools when config is undefined', () => {
    const result = filterToolsByDenial(mockTools, undefined);
    expect(result).toHaveLength(6);
    expect(result.map(t => t.name)).toEqual(['Read', 'Write', 'Edit', 'Bash', 'Search', 'SpawnSubagent']);
  });

  it('returns empty array when denyAll is true', () => {
    const result = filterToolsByDenial(mockTools, { denyAll: true });
    expect(result).toEqual([]);
  });

  it('filters out denied tools', () => {
    const config: ToolDenialConfig = {
      tools: ['Bash', 'SpawnSubagent'],
    };

    const result = filterToolsByDenial(mockTools, config);
    expect(result.map(t => t.name)).toEqual(['Read', 'Write', 'Edit', 'Search']);
  });

  it('returns all tools when only rules are specified (no tool denial)', () => {
    const config: ToolDenialConfig = {
      rules: [
        {
          tool: 'Bash',
          denyPatterns: [{ parameter: 'command', patterns: ['sudo'] }],
        },
      ],
    };

    // Rules are checked at execution time, not filtering time
    const result = filterToolsByDenial(mockTools, config);
    expect(result).toHaveLength(6);
  });

  it('preserves tool objects (not just names)', () => {
    const toolsWithConfig = [
      { name: 'Read', config: { maxLines: 1000 } },
      { name: 'Write', config: { encoding: 'utf-8' } },
    ];

    const result = filterToolsByDenial(toolsWithConfig, { tools: ['Write'] });
    expect(result).toHaveLength(1);
    expect(result[0]).toEqual({ name: 'Read', config: { maxLines: 1000 } });
  });
});

// =============================================================================
// Tests: mergeToolDenials (inheritance)
// =============================================================================

describe('mergeToolDenials', () => {
  it('returns undefined when both configs are undefined', () => {
    const result = mergeToolDenials(undefined, undefined);
    expect(result).toBeUndefined();
  });

  it('returns parent config when child is undefined', () => {
    const parent: ToolDenialConfig = { tools: ['Bash'] };
    const result = mergeToolDenials(parent, undefined);
    expect(result).toEqual(parent);
  });

  it('returns child config when parent is undefined', () => {
    const child: ToolDenialConfig = { tools: ['Write'] };
    const result = mergeToolDenials(undefined, child);
    expect(result).toEqual(child);
  });

  it('returns denyAll if parent has denyAll', () => {
    const parent: ToolDenialConfig = { denyAll: true };
    const child: ToolDenialConfig = { tools: ['Read'] };

    const result = mergeToolDenials(parent, child);
    expect(result).toEqual({ denyAll: true });
  });

  it('returns denyAll if child has denyAll', () => {
    const parent: ToolDenialConfig = { tools: ['Bash'] };
    const child: ToolDenialConfig = { denyAll: true };

    const result = mergeToolDenials(parent, child);
    expect(result).toEqual({ denyAll: true });
  });

  it('merges tools arrays (union)', () => {
    const parent: ToolDenialConfig = { tools: ['Bash', 'Write'] };
    const child: ToolDenialConfig = { tools: ['Write', 'SpawnSubagent'] };

    const result = mergeToolDenials(parent, child);
    expect(result?.tools).toHaveLength(3);
    expect(result?.tools).toContain('Bash');
    expect(result?.tools).toContain('Write');
    expect(result?.tools).toContain('SpawnSubagent');
  });

  it('merges rules arrays (concatenate)', () => {
    const parentRule: ToolDenialRule = {
      tool: 'Bash',
      denyPatterns: [{ parameter: 'command', patterns: ['sudo'] }],
    };
    const childRule: ToolDenialRule = {
      tool: 'Read',
      denyPatterns: [{ parameter: 'file_path', patterns: ['\\.env'] }],
    };

    const parent: ToolDenialConfig = { rules: [parentRule] };
    const child: ToolDenialConfig = { rules: [childRule] };

    const result = mergeToolDenials(parent, child);
    expect(result?.rules).toHaveLength(2);
    expect(result?.rules).toContainEqual(parentRule);
    expect(result?.rules).toContainEqual(childRule);
  });

  it('merges both tools and rules', () => {
    const parent: ToolDenialConfig = {
      tools: ['SpawnSubagent'],
      rules: [{ tool: 'Bash', denyPatterns: [{ parameter: 'command', patterns: ['sudo'] }] }],
    };
    const child: ToolDenialConfig = {
      tools: ['Write'],
      rules: [{ tool: 'Read', denyPatterns: [{ parameter: 'file_path', patterns: ['\\.env'] }] }],
    };

    const result = mergeToolDenials(parent, child);
    expect(result?.tools).toHaveLength(2);
    expect(result?.rules).toHaveLength(2);
  });
});

// =============================================================================
// Tests: Real-world scenarios
// =============================================================================

describe('Real-world scenarios', () => {
  describe('WebFetch summarizer (text generation only)', () => {
    it('denies all tools for summarization subagent', () => {
      const config: ToolDenialConfig = { denyAll: true };

      expect(checkToolDenial('Read', {}, config).denied).toBe(true);
      expect(checkToolDenial('Write', {}, config).denied).toBe(true);
      expect(checkToolDenial('Bash', {}, config).denied).toBe(true);
      expect(checkToolDenial('Search', {}, config).denied).toBe(true);
      expect(filterToolsByDenial([{ name: 'Read' }, { name: 'Bash' }], config)).toEqual([]);
    });
  });

  describe('Restricted code review agent', () => {
    it('allows read-only operations, denies writes and dangerous commands', () => {
      const config: ToolDenialConfig = {
        tools: ['Write', 'Edit', 'SpawnSubagent'],
        rules: [
          {
            tool: 'Bash',
            denyPatterns: [
              { parameter: 'command', patterns: ['rm\\s+', 'mv\\s+', 'cp\\s+', '>\\s*', 'sudo'] },
            ],
            message: 'Only read-only shell commands allowed',
          },
        ],
      };

      // Denied tools
      expect(checkToolDenial('Write', { file_path: '/x' }, config).denied).toBe(true);
      expect(checkToolDenial('Edit', { file_path: '/x' }, config).denied).toBe(true);

      // Allowed tools
      expect(checkToolDenial('Read', { file_path: '/x' }, config).denied).toBe(false);
      expect(checkToolDenial('Search', { pattern: 'foo' }, config).denied).toBe(false);

      // Bash - depends on command
      expect(checkToolDenial('Bash', { command: 'ls -la' }, config).denied).toBe(false);
      expect(checkToolDenial('Bash', { command: 'cat file.txt' }, config).denied).toBe(false);
      expect(checkToolDenial('Bash', { command: 'rm file.txt' }, config).denied).toBe(true);
      expect(checkToolDenial('Bash', { command: 'sudo apt' }, config).denied).toBe(true);
    });
  });

  describe('Sandboxed file editor', () => {
    it('allows editing only in specific directory', () => {
      const config: ToolDenialConfig = {
        rules: [
          {
            tool: 'Write',
            denyPatterns: [
              { parameter: 'file_path', patterns: ['^(?!/workspace/)'] }, // Must start with /workspace/
            ],
            message: 'Can only write to /workspace/ directory',
          },
          {
            tool: 'Read',
            denyPatterns: [
              { parameter: 'file_path', patterns: ['\\.env', '\\.ssh', '/etc/'] },
            ],
            message: 'Sensitive files cannot be accessed',
          },
        ],
      };

      // Write restrictions
      expect(checkToolDenial('Write', { file_path: '/workspace/test.txt' }, config).denied).toBe(false);
      expect(checkToolDenial('Write', { file_path: '/etc/passwd' }, config).denied).toBe(true);

      // Read restrictions
      expect(checkToolDenial('Read', { file_path: '/workspace/code.ts' }, config).denied).toBe(false);
      expect(checkToolDenial('Read', { file_path: '/home/user/.env' }, config).denied).toBe(true);
    });
  });
});
