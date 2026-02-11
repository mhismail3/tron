import { describe, it, expect } from 'vitest';
import { RulesIndex } from '../rules-index.js';
import type { DiscoveredRulesFile } from '../rules-discovery.js';

function makeRule(overrides: Partial<DiscoveredRulesFile> = {}): DiscoveredRulesFile {
  return {
    path: '/project/.claude/CLAUDE.md',
    relativePath: '.claude/CLAUDE.md',
    content: '# Test rule',
    scopeDir: '',
    isGlobal: true,
    isStandalone: false,
    sizeBytes: 100,
    modifiedAt: new Date(),
    ...overrides,
  };
}

function makeScopedRule(scopeDir: string, relativePath?: string): DiscoveredRulesFile {
  return makeRule({
    relativePath: relativePath ?? `${scopeDir}/.claude/CLAUDE.md`,
    scopeDir,
    isGlobal: false,
  });
}

function makeGlobalRule(relativePath?: string): DiscoveredRulesFile {
  return makeRule({
    relativePath: relativePath ?? '.claude/CLAUDE.md',
    scopeDir: '',
    isGlobal: true,
  });
}

describe('RulesIndex', () => {
  it('returns no matches and no globals from empty index', () => {
    const index = new RulesIndex([]);
    expect(index.matchPath('src/anything.ts')).toEqual([]);
    expect(index.getGlobalRules()).toEqual([]);
    expect(index.totalCount).toBe(0);
  });

  it('returns global rules from getGlobalRules() regardless of path', () => {
    const global = makeGlobalRule();
    const index = new RulesIndex([global]);

    expect(index.getGlobalRules()).toHaveLength(1);
    expect(index.getGlobalRules()[0].relativePath).toBe('.claude/CLAUDE.md');
    expect(index.globalCount).toBe(1);
    expect(index.scopedCount).toBe(0);
  });

  it('matches path under scopeDir', () => {
    const scoped = makeScopedRule('packages/agent');
    const index = new RulesIndex([scoped]);

    expect(index.matchPath('packages/agent/src/loader.ts')).toHaveLength(1);
    expect(index.matchPath('packages/agent/package.json')).toHaveLength(1);
  });

  it('does NOT match unrelated path', () => {
    const scoped = makeScopedRule('packages/agent');
    const index = new RulesIndex([scoped]);

    expect(index.matchPath('packages/ios-app/src/main.swift')).toHaveLength(0);
    expect(index.matchPath('src/tools/fs/read.ts')).toHaveLength(0);
  });

  it('does NOT match partial directory name prefix', () => {
    const scoped = makeScopedRule('packages/agent');
    const index = new RulesIndex([scoped]);

    // "packages/agent-tools" should NOT match "packages/agent"
    expect(index.matchPath('packages/agent-tools/index.ts')).toHaveLength(0);
  });

  it('matches files directly in scopeDir', () => {
    const scoped = makeScopedRule('packages/agent');
    const index = new RulesIndex([scoped]);

    expect(index.matchPath('packages/agent/index.ts')).toHaveLength(1);
  });

  it('multiple rules can match same path', () => {
    const rule1 = makeScopedRule('packages', 'packages/.claude/CLAUDE.md');
    const rule2 = makeScopedRule('packages/agent', 'packages/agent/.claude/CLAUDE.md');
    const index = new RulesIndex([rule1, rule2]);

    const matched = index.matchPath('packages/agent/src/loader.ts');
    expect(matched).toHaveLength(2);
  });

  it('returns most specific rule first', () => {
    const broad = makeScopedRule('packages', 'packages/.claude/CLAUDE.md');
    const specific = makeScopedRule('packages/agent', 'packages/agent/.claude/CLAUDE.md');
    const index = new RulesIndex([broad, specific]);

    const matched = index.matchPath('packages/agent/src/loader.ts');
    expect(matched).toHaveLength(2);
    // Most specific (longest scopeDir) first
    expect(matched[0].scopeDir).toBe('packages/agent');
    expect(matched[1].scopeDir).toBe('packages');
  });

  it('totalCount returns sum of global + scoped', () => {
    const index = new RulesIndex([
      makeGlobalRule('.claude/CLAUDE.md'),
      makeGlobalRule('.tron/AGENTS.md'),
      makeScopedRule('packages/agent'),
    ]);

    expect(index.totalCount).toBe(3);
    expect(index.globalCount).toBe(2);
    expect(index.scopedCount).toBe(1);
  });

  it('getScopedRules returns all scoped rules', () => {
    const s1 = makeScopedRule('packages/agent', 'packages/agent/.claude/CLAUDE.md');
    const s2 = makeScopedRule('packages/ios-app', 'packages/ios-app/.claude/AGENTS.md');
    const g1 = makeGlobalRule('.claude/CLAUDE.md');

    const index = new RulesIndex([s1, s2, g1]);
    const scoped = index.getScopedRules();
    expect(scoped).toHaveLength(2);
  });

  it('rules from different directories dont conflict', () => {
    const agentRule = makeScopedRule('packages/agent', 'packages/agent/.claude/CLAUDE.md');
    const iosRule = makeScopedRule('packages/ios-app', 'packages/ios-app/.claude/CLAUDE.md');
    const index = new RulesIndex([agentRule, iosRule]);

    expect(index.matchPath('packages/agent/src/loader.ts')).toHaveLength(1);
    expect(index.matchPath('packages/ios-app/Sources/main.swift')).toHaveLength(1);
    expect(index.matchPath('src/runtime/agent.ts')).toHaveLength(0);
  });

  it('handles deeply nested scope directories', () => {
    const deep = makeScopedRule('packages/agent/src/context', 'packages/agent/src/context/.claude/CLAUDE.md');
    const index = new RulesIndex([deep]);

    expect(index.matchPath('packages/agent/src/context/loader.ts')).toHaveLength(1);
    expect(index.matchPath('packages/agent/src/runtime/agent.ts')).toHaveLength(0);
  });
});
