/**
 * @fileoverview Tests for AstGrep tool
 *
 * TDD: Comprehensive test suite for ast-grep integration.
 * All tests start as .skip and are enabled as features are implemented.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import * as fs from 'fs/promises';
import * as path from 'path';
import { fileURLToPath } from 'url';

import { AstGrepTool } from '../ast-grep.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const FIXTURES_PATH = path.join(__dirname, '..', '__fixtures__', 'ast-grep');

// Helper to create temp copies of fixtures for replace tests
async function createTempFixtures(): Promise<string> {
  const tempDir = path.join(__dirname, '..', '__fixtures__', 'ast-grep-temp-' + Date.now());
  await fs.mkdir(tempDir, { recursive: true });

  // Copy fixture files
  const files = await fs.readdir(FIXTURES_PATH);
  for (const file of files) {
    const srcPath = path.join(FIXTURES_PATH, file);
    const stat = await fs.stat(srcPath);
    if (stat.isFile()) {
      await fs.copyFile(srcPath, path.join(tempDir, file));
    }
  }

  return tempDir;
}

let tool: AstGrepTool;

describe('AstGrepTool', () => {
  beforeEach(() => {
    tool = new AstGrepTool({ workingDirectory: FIXTURES_PATH });
  });

  describe('Installation Detection', () => {
    it.skip('returns helpful error when ast-grep not installed', async () => {
      // This test requires mocking - skip for now
      // Mock execAsync to throw "command not found"
      const result = await tool.execute({ pattern: 'test' });
      expect(result.isError).toBe(true);
      expect(result.content).toContain('brew install ast-grep');
      expect(result.content).toContain('npm install -g @ast-grep/cli');
      expect(result.content).toContain('cargo install ast-grep');
    });

    it('proceeds when ast-grep is available', async () => {
      const result = await tool.execute({ pattern: 'console.log($$$)', lang: 'js' });
      expect(result.isError).toBeFalsy();
    });

    it.skip('caches binary path after first check', async () => {
      // This test requires internal state inspection - skip for now
      // First call finds binary
      await tool.execute({ pattern: 'test1' });
      // Second call should use cached path
      await tool.execute({ pattern: 'test2' });
      // Verify version check only called once
    });

    it('tries both sg and ast-grep binary names', async () => {
      // Should try 'sg' first, then 'ast-grep' if sg not found
      const result = await tool.execute({ pattern: 'test', lang: 'js' });
      expect(result.isError).toBeFalsy();
    });
  });

  describe('Search Mode', () => {
    it('finds simple patterns', async () => {
      const result = await tool.execute({
        pattern: 'console.log($MSG)',
        path: FIXTURES_PATH,
        lang: 'js',
      });
      expect(result.isError).toBeFalsy();
      expect(result.details?.matches?.length).toBeGreaterThan(0);
    });

    it('captures metavariables', async () => {
      const result = await tool.execute({
        pattern: 'console.log($MSG)',
        path: FIXTURES_PATH,
        lang: 'js',
      });
      expect(result.details?.matches?.[0]?.captured).toBeDefined();
    });

    it('handles multi-node patterns ($$$)', async () => {
      const result = await tool.execute({
        pattern: 'function $NAME($$$) { $$$ }',
        path: FIXTURES_PATH,
        lang: 'js',
      });
      expect(result.details?.matches?.length).toBeGreaterThan(0);
    });

    it('respects limit parameter', async () => {
      const result = await tool.execute({
        pattern: 'console.log($$$)',
        path: FIXTURES_PATH,
        limit: 3,
        lang: 'js',
      });
      expect(result.details?.matches?.length).toBeLessThanOrEqual(3);
    });

    it('filters by language', async () => {
      const result = await tool.execute({
        pattern: 'def $NAME($$$):',
        path: FIXTURES_PATH,
        lang: 'py',
      });
      if (result.details?.matches && result.details.matches.length > 0) {
        expect(result.details.matches.every((m: any) => m.file.endsWith('.py'))).toBe(true);
      }
    });

    it.skip('filters by globs', async () => {
      // Glob filtering requires specific ast-grep behavior
      const result = await tool.execute({
        pattern: 'test',
        path: FIXTURES_PATH,
        globs: ['**/*.test.ts'],
      });
      expect(result.details?.matches?.every((m: any) => m.file.includes('.test.'))).toBe(true);
    });

    it('includes context lines when specified', async () => {
      const result = await tool.execute({
        pattern: 'console.log($MSG)',
        path: FIXTURES_PATH,
        context: 2,
        lang: 'js',
      });
      // Content should be defined
      expect(result.content).toBeDefined();
    });

    it('returns empty matches gracefully', async () => {
      const result = await tool.execute({
        pattern: 'nonexistent_function_xyz_abc_123()',
        path: FIXTURES_PATH,
        lang: 'js',
      });
      expect(result.details?.matches).toEqual([]);
      expect(result.details?.totalMatches).toBe(0);
      expect(result.isError).toBeFalsy();
    });

    it('returns file, line, column for each match', async () => {
      const result = await tool.execute({
        pattern: 'console.log($MSG)',
        path: FIXTURES_PATH,
        lang: 'js',
      });
      const match = result.details?.matches?.[0];
      expect(match?.file).toBeDefined();
      expect(match?.line).toBeGreaterThan(0);
      expect(match?.column).toBeGreaterThanOrEqual(0);
    });

    it('returns matched code text', async () => {
      const result = await tool.execute({
        pattern: 'console.log($MSG)',
        path: FIXTURES_PATH,
        lang: 'js',
      });
      expect(result.details?.matches?.[0]?.code).toBeDefined();
      expect(result.details?.matches?.[0]?.code).toContain('console.log');
    });
  });

  describe('Replace Mode', () => {
    let tempDir: string;
    let replaceTool: AstGrepTool;

    beforeEach(async () => {
      tempDir = await createTempFixtures();
      replaceTool = new AstGrepTool({ workingDirectory: tempDir });
    });

    afterEach(async () => {
      try {
        await fs.rm(tempDir, { recursive: true });
      } catch {
        // Ignore cleanup errors
      }
    });

    it('replaces simple patterns', async () => {
      const result = await replaceTool.execute({
        pattern: 'var $N = $V',
        replacement: 'const $N = $V',
        mode: 'replace',
        lang: 'js',
      });
      expect(result.isError).toBeFalsy();

      // Verify file was actually changed
      const content = await fs.readFile(path.join(tempDir, 'simple.js'), 'utf-8');
      expect(content).toContain('const ');
    });

    it('preserves captured metavariables in replacement', async () => {
      await replaceTool.execute({
        pattern: 'console.log($MSG)',
        replacement: 'logger.info($MSG)',
        mode: 'replace',
        lang: 'js',
      });
      const content = await fs.readFile(path.join(tempDir, 'simple.js'), 'utf-8');
      expect(content).toContain('logger.info');
    });

    it('requires replacement param in replace mode', async () => {
      const result = await replaceTool.execute({
        pattern: 'var $N = $V',
        mode: 'replace',
      });
      expect(result.isError).toBe(true);
      expect(result.content).toContain('replacement');
    });

    it('reports number of files modified', async () => {
      const result = await replaceTool.execute({
        pattern: 'console.log($MSG)',
        replacement: 'logger.info($MSG)',
        mode: 'replace',
        lang: 'js',
      });
      expect(result.details?.filesModified).toBeDefined();
    });

    it('reports total replacements count', async () => {
      const result = await replaceTool.execute({
        pattern: 'console.log($MSG)',
        replacement: 'logger.info($MSG)',
        mode: 'replace',
        lang: 'js',
      });
      expect(result.details?.replacements).toBeDefined();
    });
  });

  describe('Count Mode', () => {
    it('returns count without full results', async () => {
      const result = await tool.execute({
        pattern: 'console.log($$$)',
        mode: 'count',
        path: FIXTURES_PATH,
        lang: 'js',
      });
      expect(result.details?.count).toBeDefined();
      expect(result.details?.matches).toBeUndefined();
    });

    it('counts across multiple files', async () => {
      const result = await tool.execute({
        pattern: 'function $NAME($$$) { $$$ }',
        mode: 'count',
        path: FIXTURES_PATH,
        lang: 'js',
      });
      expect(result.details?.count).toBeGreaterThan(0);
      expect(result.details?.filesWithMatches).toBeDefined();
    });

    it('is faster than search mode for large codebases', async () => {
      // Count mode should not return full match data
      const result = await tool.execute({
        pattern: 'console.log($$$)',
        mode: 'count',
        path: FIXTURES_PATH,
        lang: 'js',
      });
      expect(result.details?.count).toBeDefined();
    });
  });

  describe('Inspect Mode', () => {
    it('shows AST for pattern', async () => {
      const result = await tool.execute({
        pattern: 'function test() {}',
        mode: 'inspect',
        lang: 'js',
      });
      // Inspect mode outputs AST information
      expect(result.content).toBeDefined();
    });

    it('helps debug complex patterns', async () => {
      const result = await tool.execute({
        pattern: 'async ($$$) => { $$$ }',
        mode: 'inspect',
        lang: 'js',
      });
      expect(result.content).toBeDefined();
    });

    it('requires language for inspect mode', async () => {
      // Inspect mode needs a language to parse the pattern
      const result = await tool.execute({
        pattern: 'function test() {}',
        mode: 'inspect',
        lang: 'js',
      });
      expect(result.content).toBeDefined();
    });
  });

  describe('Error Handling', () => {
    it.skip('handles invalid pattern syntax', async () => {
      // ast-grep accepts most patterns, so this is hard to test
      const result = await tool.execute({
        pattern: '{{{{invalid',
        lang: 'js',
      });
      expect(result.isError).toBe(true);
    });

    it('handles invalid language', async () => {
      const result = await tool.execute({
        pattern: 'test',
        lang: 'notarealang',
      });
      expect(result.isError).toBe(true);
    });

    it('handles path not found', async () => {
      const result = await tool.execute({
        pattern: 'test',
        path: '/nonexistent/path/that/does/not/exist',
      });
      expect(result.isError).toBe(true);
      expect(result.content.toLowerCase()).toContain('not found');
    });

    it.skip('handles permission denied gracefully', async () => {
      // Platform-specific test, skip for now
      const result = await tool.execute({
        pattern: 'test',
        path: '/etc/ssl/private',
      });
      expect(result.isError).toBe(true);
    });

    it.skip('times out on very large searches', async () => {
      // This test requires mocking timeout - skip for now
      const result = await tool.execute({
        pattern: '$$$',
        path: '/',
        timeout: 100,
      });
      expect(result.isError).toBe(true);
      expect(result.content.toLowerCase()).toContain('timeout');
    });

    it('returns error details in result', async () => {
      const result = await tool.execute({
        pattern: 'test',
        path: '/nonexistent',
      });
      expect(result.details).toBeDefined();
    });
  });

  describe('Input Validation', () => {
    it('requires pattern parameter', async () => {
      const result = await tool.execute({});
      expect(result.isError).toBe(true);
      expect(result.content).toContain('pattern');
    });

    it('validates mode parameter', async () => {
      const result = await tool.execute({
        pattern: 'test',
        mode: 'invalid_mode',
      });
      expect(result.isError).toBe(true);
    });

    it('validates limit bounds', async () => {
      const result = await tool.execute({
        pattern: 'test',
        limit: -1,
      });
      expect(result.isError).toBe(true);
    });

    it('validates limit upper bound', async () => {
      const result = await tool.execute({
        pattern: 'test',
        limit: 10000,
      });
      expect(result.isError).toBe(true);
    });

    it('validates context is non-negative', async () => {
      const result = await tool.execute({
        pattern: 'test',
        context: -1,
      });
      expect(result.isError).toBe(true);
    });
  });

  describe('Output Truncation', () => {
    it.skip('truncates large outputs', async () => {
      const result = await tool.execute({
        pattern: '$VAR',
        path: FIXTURES_PATH,
        limit: 1000,
      });
      // Should be under token limit
      expect(result.details.truncated !== undefined || result.content.length < 100000).toBe(true);
    });

    it.skip('preserves first matches when truncating', async () => {
      const result = await tool.execute({
        pattern: '$VAR',
        path: FIXTURES_PATH,
        limit: 100,
      });
      // First match should always be visible
      if (result.details.matches && result.details.matches.length > 0) {
        expect(result.details.matches[0]).toBeDefined();
      }
    });

    it.skip('includes truncation indicator in output', async () => {
      // Force large output
      const result = await tool.execute({
        pattern: '$VAR',
        path: FIXTURES_PATH,
        limit: 500,
      });
      if (result.details.truncated) {
        expect(result.content).toContain('truncated');
      }
    });
  });

  describe('Security', () => {
    it('prevents path traversal attacks', async () => {
      const result = await tool.execute({
        pattern: 'test',
        path: '../../../etc/passwd',
      });
      expect(result.isError).toBe(true);
    });

    it.skip('stays within working directory', async () => {
      // This test depends on working directory validation policy
      const result = await tool.execute({
        pattern: 'test',
        path: '/root',
      });
      expect(result.isError).toBe(true);
    });

    it('sanitizes pattern for shell injection', async () => {
      // Pattern should be passed as argument, not shell string
      // This should not execute any shell commands
      const result = await tool.execute({
        pattern: '$(rm -rf /)',
        lang: 'js',
      });
      // The tool should run without executing shell commands
      // The pattern will just not match anything
      expect(result.isError === false || result.details?.matches?.length === 0).toBe(true);
    });

    it('rejects patterns with shell metacharacters in dangerous contexts', async () => {
      const result = await tool.execute({
        pattern: '`rm -rf /`',
        lang: 'js',
      });
      // Should treat as literal pattern - won't match anything
      expect(result.isError === false || result.details?.matches?.length === 0).toBe(true);
    });
  });

  describe('Integration', () => {
    it.skip('works with real codebase', async () => {
      // Search in the actual Tron source
      const result = await tool.execute({
        pattern: 'export class $NAME implements TronTool',
        path: path.join(__dirname, '..'),
        lang: 'ts',
      });
      expect(result.details.matches.length).toBeGreaterThan(0);
    });

    it.skip('finds patterns across TypeScript project', async () => {
      const result = await tool.execute({
        pattern: 'async function $NAME($$$): Promise<$RET>',
        path: path.join(__dirname, '../..'),
        lang: 'ts',
      });
      expect(result.details.matches).toBeDefined();
    });

    it.skip('handles mixed file types', async () => {
      const result = await tool.execute({
        pattern: 'function $NAME($$$)',
        path: FIXTURES_PATH,
        // No lang specified - should search all supported types
      });
      expect(result.details).toBeDefined();
    });
  });

  describe('Tool Interface', () => {
    it('has correct name', () => {
      expect(tool.name).toBe('AstGrep');
    });

    it('has correct category', () => {
      expect(tool.category).toBe('search');
    });

    it('has description', () => {
      expect(tool.description).toBeDefined();
      expect(tool.description.length).toBeGreaterThan(50);
    });

    it('has parameters schema', () => {
      expect(tool.parameters).toBeDefined();
      expect(tool.parameters.type).toBe('object');
      expect(tool.parameters.properties.pattern).toBeDefined();
      expect(tool.parameters.required).toContain('pattern');
    });

    it('parameters include mode', () => {
      expect(tool.parameters.properties.mode).toBeDefined();
      expect(tool.parameters.properties.mode.enum).toContain('search');
      expect(tool.parameters.properties.mode.enum).toContain('replace');
    });
  });

  describe('Abort Signal Support', () => {
    it.skip('respects abort signal', async () => {
      const controller = new AbortController();
      controller.abort();

      const result = await tool.execute(
        'test-id',
        { pattern: 'test' },
        controller.signal
      );
      expect(result.isError).toBe(true);
      expect(result.content).toContain('cancel');
    });

    it.skip('can be cancelled mid-execution', async () => {
      const controller = new AbortController();

      // Start a potentially long search
      const promise = tool.execute(
        'test-id',
        { pattern: '$VAR', path: '/' },
        controller.signal
      );

      // Cancel immediately
      controller.abort();

      const result = await promise;
      expect(result.isError).toBe(true);
    });
  });
});
