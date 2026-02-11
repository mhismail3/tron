import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { randomUUID } from 'crypto';
import { discoverRulesFiles } from '../rules-discovery.js';

describe('discoverRulesFiles', () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = path.join(os.tmpdir(), `rules-discovery-${randomUUID()}`);
    fs.mkdirSync(tmpDir, { recursive: true });
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  function writeFile(relativePath: string, content: string) {
    const fullPath = path.join(tmpDir, relativePath);
    fs.mkdirSync(path.dirname(fullPath), { recursive: true });
    fs.writeFileSync(fullPath, content, 'utf-8');
  }

  // =========================================================================
  // Agent dir discovery (.claude/, .tron/, .agent/)
  // =========================================================================

  it('discovers .claude/CLAUDE.md at project root', async () => {
    writeFile('.claude/CLAUDE.md', '# Root rules');

    const results = await discoverRulesFiles({ projectRoot: tmpDir, excludeRootLevel: false });
    expect(results).toHaveLength(1);
    expect(results[0].relativePath).toBe('.claude/CLAUDE.md');
    expect(results[0].isGlobal).toBe(true);
    expect(results[0].isStandalone).toBe(false);
    expect(results[0].scopeDir).toBe('');
  });

  it('discovers .claude/AGENTS.md at project root', async () => {
    writeFile('.claude/AGENTS.md', '# Agents config');

    const results = await discoverRulesFiles({ projectRoot: tmpDir, excludeRootLevel: false });
    expect(results).toHaveLength(1);
    expect(results[0].relativePath).toBe('.claude/AGENTS.md');
  });

  it('discovers .tron/CLAUDE.md at project root', async () => {
    writeFile('.tron/CLAUDE.md', '# Tron rules');

    const results = await discoverRulesFiles({ projectRoot: tmpDir, excludeRootLevel: false });
    expect(results).toHaveLength(1);
    expect(results[0].relativePath).toBe('.tron/CLAUDE.md');
  });

  it('discovers .agent/AGENTS.md at project root', async () => {
    writeFile('.agent/AGENTS.md', '# Agent config');

    const results = await discoverRulesFiles({ projectRoot: tmpDir, excludeRootLevel: false });
    expect(results).toHaveLength(1);
    expect(results[0].relativePath).toBe('.agent/AGENTS.md');
  });

  it('case-insensitive: discovers claude.md and agents.md', async () => {
    writeFile('.claude/claude.md', '# lowercase claude');
    writeFile('.tron/agents.md', '# lowercase agents');

    const results = await discoverRulesFiles({ projectRoot: tmpDir, excludeRootLevel: false });
    expect(results).toHaveLength(2);
    const paths = results.map(r => r.relativePath).sort();
    expect(paths).toEqual(['.claude/claude.md', '.tron/agents.md']);
  });

  it('discovers nested rules in subdirectories', async () => {
    writeFile('packages/agent/.claude/CLAUDE.md', '# Agent rules');

    const results = await discoverRulesFiles({ projectRoot: tmpDir });
    expect(results).toHaveLength(1);
    expect(results[0].relativePath).toBe('packages/agent/.claude/CLAUDE.md');
    expect(results[0].scopeDir).toBe('packages/agent');
    expect(results[0].isGlobal).toBe(false);
    expect(results[0].isStandalone).toBe(false);
  });

  it('discovers deeply nested agent dir rules', async () => {
    writeFile('packages/agent/.claude/CLAUDE.md', '# Deep rule');
    writeFile('src/lib/.tron/AGENTS.md', '# Nested rule');

    const results = await discoverRulesFiles({ projectRoot: tmpDir });
    expect(results).toHaveLength(2);
    const paths = results.map(r => r.relativePath).sort();
    expect(paths).toEqual([
      'packages/agent/.claude/CLAUDE.md',
      'src/lib/.tron/AGENTS.md',
    ]);
  });

  it('computes correct scopeDir for nested agent dir files', async () => {
    writeFile('packages/foo/.claude/CLAUDE.md', '# Foo rules');

    const results = await discoverRulesFiles({ projectRoot: tmpDir });
    expect(results[0].scopeDir).toBe('packages/foo');
  });

  // =========================================================================
  // Standalone file discovery
  // =========================================================================

  it('discovers standalone CLAUDE.md in subdirectory when enabled', async () => {
    writeFile('packages/foo/CLAUDE.md', '# Standalone claude');

    const results = await discoverRulesFiles({ projectRoot: tmpDir, discoverStandaloneFiles: true });
    expect(results).toHaveLength(1);
    expect(results[0].relativePath).toBe('packages/foo/CLAUDE.md');
    expect(results[0].isStandalone).toBe(true);
    expect(results[0].scopeDir).toBe('packages/foo');
  });

  it('discovers standalone AGENTS.md in subdirectory', async () => {
    writeFile('packages/bar/AGENTS.md', '# Standalone agents');

    const results = await discoverRulesFiles({ projectRoot: tmpDir, discoverStandaloneFiles: true });
    expect(results).toHaveLength(1);
    expect(results[0].relativePath).toBe('packages/bar/AGENTS.md');
    expect(results[0].isStandalone).toBe(true);
  });

  it('does NOT discover standalone files when discoverStandaloneFiles is false', async () => {
    writeFile('packages/foo/CLAUDE.md', '# Should not find');
    writeFile('packages/foo/.claude/CLAUDE.md', '# Should find');

    const results = await discoverRulesFiles({
      projectRoot: tmpDir,
      discoverStandaloneFiles: false,
    });
    expect(results).toHaveLength(1);
    expect(results[0].relativePath).toBe('packages/foo/.claude/CLAUDE.md');
  });

  it('discovers both agent dir and standalone files', async () => {
    writeFile('packages/foo/.claude/CLAUDE.md', '# Agent dir');
    writeFile('packages/bar/AGENTS.md', '# Standalone');

    const results = await discoverRulesFiles({ projectRoot: tmpDir });
    expect(results).toHaveLength(2);
  });

  // =========================================================================
  // excludeRootLevel
  // =========================================================================

  it('excludes root-level files by default', async () => {
    writeFile('.claude/CLAUDE.md', '# Root (should skip)');
    writeFile('packages/foo/.claude/CLAUDE.md', '# Nested (should find)');

    const results = await discoverRulesFiles({ projectRoot: tmpDir });
    expect(results).toHaveLength(1);
    expect(results[0].relativePath).toBe('packages/foo/.claude/CLAUDE.md');
  });

  it('includes root-level files when excludeRootLevel is false', async () => {
    writeFile('.claude/CLAUDE.md', '# Root');
    writeFile('packages/foo/.claude/CLAUDE.md', '# Nested');

    const results = await discoverRulesFiles({ projectRoot: tmpDir, excludeRootLevel: false });
    expect(results).toHaveLength(2);
  });

  it('excludes root standalone files when excludeRootLevel is true', async () => {
    writeFile('CLAUDE.md', '# Root standalone (should skip)');
    writeFile('packages/foo/CLAUDE.md', '# Nested standalone (should find)');

    const results = await discoverRulesFiles({ projectRoot: tmpDir, discoverStandaloneFiles: true });
    expect(results).toHaveLength(1);
    expect(results[0].relativePath).toBe('packages/foo/CLAUDE.md');
  });

  // =========================================================================
  // Exclusions and edge cases
  // =========================================================================

  it('skips node_modules directories', async () => {
    writeFile('node_modules/some-pkg/.claude/CLAUDE.md', '# Should not find');
    writeFile('packages/foo/.claude/CLAUDE.md', '# Should find');

    const results = await discoverRulesFiles({ projectRoot: tmpDir });
    expect(results).toHaveLength(1);
    expect(results[0].relativePath).toBe('packages/foo/.claude/CLAUDE.md');
  });

  it('skips .git directories', async () => {
    writeFile('.git/hooks/.claude/CLAUDE.md', '# Should not find');

    const results = await discoverRulesFiles({ projectRoot: tmpDir });
    expect(results).toHaveLength(0);
  });

  it('does NOT discover RULES.md (only CLAUDE.md and AGENTS.md)', async () => {
    writeFile('.claude/RULES.md', '# Should not find');
    writeFile('.claude/rules/context.md', '# Should not find');
    writeFile('packages/foo/.claude/RULES.md', '# Should not find');

    const results = await discoverRulesFiles({ projectRoot: tmpDir, excludeRootLevel: false });
    expect(results).toHaveLength(0);
  });

  it('does NOT discover general .md files', async () => {
    writeFile('.claude/README.md', '# Should not find');
    writeFile('.claude/SYSTEM.md', '# Should not find');

    const results = await discoverRulesFiles({ projectRoot: tmpDir, excludeRootLevel: false });
    expect(results).toHaveLength(0);
  });

  it('does NOT discover rules/ directory files', async () => {
    writeFile('.claude/rules/context.md', '# Old style rule');
    writeFile('.claude/rules/tools.md', '# Old style tool rule');

    const results = await discoverRulesFiles({ projectRoot: tmpDir, excludeRootLevel: false });
    expect(results).toHaveLength(0);
  });

  it('returns empty when no context files exist', async () => {
    writeFile('src/index.ts', 'export {};');

    const results = await discoverRulesFiles({ projectRoot: tmpDir });
    expect(results).toHaveLength(0);
  });

  it('respects maxDepth', async () => {
    writeFile('a/b/c/d/e/.claude/CLAUDE.md', '# Very deep');
    writeFile('a/.claude/CLAUDE.md', '# Shallow');

    const results = await discoverRulesFiles({ projectRoot: tmpDir, maxDepth: 2 });
    expect(results).toHaveLength(1);
    expect(results[0].relativePath).toBe('a/.claude/CLAUDE.md');
  });

  it('populates file metadata correctly', async () => {
    const content = '# Rule content\n\nSome body text.';
    writeFile('packages/foo/.claude/CLAUDE.md', content);

    const results = await discoverRulesFiles({ projectRoot: tmpDir });
    expect(results).toHaveLength(1);
    expect(results[0].content).toBe(content);
    expect(results[0].sizeBytes).toBe(Buffer.byteLength(content, 'utf-8'));
    expect(results[0].modifiedAt).toBeInstanceOf(Date);
    expect(results[0].path).toBe(path.join(tmpDir, 'packages/foo/.claude/CLAUDE.md'));
  });

  it('raw content is returned without any frontmatter stripping', async () => {
    const content = '---\nkey: value\n---\n\n# Rule title\n\nRule body';
    writeFile('packages/foo/.claude/CLAUDE.md', content);

    const results = await discoverRulesFiles({ projectRoot: tmpDir });
    expect(results[0].content).toBe(content);
    expect(results[0].content).toContain('---');
  });

  it('discovers multiple context files in same agent dir', async () => {
    writeFile('packages/foo/.claude/CLAUDE.md', '# Claude');
    writeFile('packages/foo/.claude/AGENTS.md', '# Agents');

    const results = await discoverRulesFiles({ projectRoot: tmpDir });
    expect(results).toHaveLength(2);
  });

  it('discovers files across multiple agent dirs in same directory', async () => {
    writeFile('packages/foo/.claude/CLAUDE.md', '# Claude');
    writeFile('packages/foo/.tron/AGENTS.md', '# Tron Agents');

    const results = await discoverRulesFiles({ projectRoot: tmpDir });
    expect(results).toHaveLength(2);
    expect(results.every(r => r.scopeDir === 'packages/foo')).toBe(true);
  });

  it('deduplicates on case-insensitive filesystem', async () => {
    // On macOS (case-insensitive), CLAUDE.md and claude.md are the same file
    writeFile('packages/foo/.claude/CLAUDE.md', '# Test');

    const results = await discoverRulesFiles({ projectRoot: tmpDir, excludeRootLevel: false });
    // Should not have duplicates even if filesystem is case-insensitive
    const uniquePaths = new Set(results.map(r => r.path));
    expect(uniquePaths.size).toBe(results.length);
  });
});
