import { describe, it, expect } from 'vitest';
import { RulesTracker } from '../rules-tracker.js';
import { RulesIndex } from '../rules-index.js';
import type { DiscoveredRulesFile } from '../rules-discovery.js';

function makeRule(overrides: Partial<DiscoveredRulesFile> = {}): DiscoveredRulesFile {
  return {
    path: '/project/.claude/CLAUDE.md',
    relativePath: '.claude/CLAUDE.md',
    content: '# Test rule content',
    scopeDir: '',
    isGlobal: true,
    isStandalone: false,
    sizeBytes: 100,
    modifiedAt: new Date(),
    ...overrides,
  };
}

function makeScopedRule(scopeDir: string, relativePath: string, content?: string): DiscoveredRulesFile {
  return makeRule({
    relativePath,
    content: content ?? `# Rule for ${relativePath}`,
    scopeDir,
    isGlobal: false,
  });
}

function makeGlobalRule(relativePath: string, content?: string): DiscoveredRulesFile {
  return makeRule({
    relativePath,
    content: content ?? `# Global ${relativePath}`,
    scopeDir: '',
    isGlobal: true,
  });
}

describe('RulesTracker dynamic activation', () => {
  it('buildDynamicRulesContent returns undefined with no index', () => {
    const tracker = new RulesTracker();
    expect(tracker.buildDynamicRulesContent()).toBeUndefined();
  });

  it('buildDynamicRulesContent with only global rules returns global content', () => {
    const global = makeGlobalRule('.claude/CLAUDE.md', '# Global rules');
    const index = new RulesIndex([global]);
    const tracker = new RulesTracker();
    tracker.setRulesIndex(index);

    const content = tracker.buildDynamicRulesContent();
    expect(content).toContain('# Global rules');
    expect(content).toContain('<!-- Rule: .claude/CLAUDE.md -->');
  });

  it('with global + scoped, no paths touched → only global content', () => {
    const global = makeGlobalRule('.claude/CLAUDE.md', '# Global');
    const scoped = makeScopedRule('packages/context', 'packages/context/.claude/CLAUDE.md', '# Context rules');
    const index = new RulesIndex([global, scoped]);
    const tracker = new RulesTracker();
    tracker.setRulesIndex(index);

    const content = tracker.buildDynamicRulesContent()!;
    expect(content).toContain('# Global');
    expect(content).not.toContain('# Context rules');
  });

  it('touchPath activates matching scoped rule', () => {
    const scoped = makeScopedRule('src/context', 'src/context/.claude/CLAUDE.md', '# Context rules');
    const index = new RulesIndex([scoped]);
    const tracker = new RulesTracker();
    tracker.setRulesIndex(index);

    expect(tracker.getActivatedScopedRulesCount()).toBe(0);

    const activated = tracker.touchPath('src/context/loader.ts');
    expect(activated).toBe(true);
    expect(tracker.getActivatedScopedRulesCount()).toBe(1);

    const content = tracker.buildDynamicRulesContent()!;
    expect(content).toContain('# Context rules');
    expect(content).toContain('(activated)');
  });

  it('touchPath same path twice is idempotent', () => {
    const scoped = makeScopedRule('src/context', 'src/context/.claude/CLAUDE.md');
    const index = new RulesIndex([scoped]);
    const tracker = new RulesTracker();
    tracker.setRulesIndex(index);

    tracker.touchPath('src/context/loader.ts');
    const activated = tracker.touchPath('src/context/loader.ts');
    expect(activated).toBe(false);
    expect(tracker.getActivatedScopedRulesCount()).toBe(1);
  });

  it('touchPath with unrelated path causes no activation', () => {
    const scoped = makeScopedRule('src/context', 'src/context/.claude/CLAUDE.md');
    const index = new RulesIndex([scoped]);
    const tracker = new RulesTracker();
    tracker.setRulesIndex(index);

    const activated = tracker.touchPath('src/runtime/agent.ts');
    expect(activated).toBe(false);
    expect(tracker.getActivatedScopedRulesCount()).toBe(0);
  });

  it('touchPath activates multiple rules with overlapping scopes', () => {
    const rule1 = makeScopedRule('packages', 'packages/.claude/CLAUDE.md');
    const rule2 = makeScopedRule('packages/agent', 'packages/agent/.claude/CLAUDE.md');
    const index = new RulesIndex([rule1, rule2]);
    const tracker = new RulesTracker();
    tracker.setRulesIndex(index);

    tracker.touchPath('packages/agent/src/loader.ts');
    expect(tracker.getActivatedScopedRulesCount()).toBe(2);
  });

  it('content is cached until new activation', () => {
    const scoped = makeScopedRule('src/context', 'src/context/.claude/CLAUDE.md', '# Context');
    const index = new RulesIndex([scoped]);
    const tracker = new RulesTracker();
    tracker.setRulesIndex(index);

    tracker.touchPath('src/context/loader.ts');
    const content1 = tracker.buildDynamicRulesContent();
    const content2 = tracker.buildDynamicRulesContent();
    expect(content1).toBe(content2); // Same reference (cached)
  });

  it('getActivatedRules returns activated scoped rules', () => {
    const scoped = makeScopedRule('src/context', 'src/context/.claude/CLAUDE.md');
    const index = new RulesIndex([scoped]);
    const tracker = new RulesTracker();
    tracker.setRulesIndex(index);

    expect(tracker.getActivatedRules()).toHaveLength(0);
    tracker.touchPath('src/context/loader.ts');
    expect(tracker.getActivatedRules()).toHaveLength(1);
    expect(tracker.getActivatedRules()[0].relativePath).toBe('src/context/.claude/CLAUDE.md');
  });

  it('getGlobalRulesFromIndex returns global rules', () => {
    const global = makeGlobalRule('.claude/CLAUDE.md');
    const index = new RulesIndex([global]);
    const tracker = new RulesTracker();
    tracker.setRulesIndex(index);

    expect(tracker.getGlobalRulesFromIndex()).toHaveLength(1);
  });

  it('getTouchedPaths returns all touched paths', () => {
    const scoped = makeScopedRule('src/context', 'src/context/.claude/CLAUDE.md');
    const index = new RulesIndex([scoped]);
    const tracker = new RulesTracker();
    tracker.setRulesIndex(index);

    tracker.touchPath('src/context/loader.ts');
    tracker.touchPath('src/runtime/agent.ts');

    const touched = tracker.getTouchedPaths();
    expect(touched.size).toBe(2);
    expect(touched.has('src/context/loader.ts')).toBe(true);
    expect(touched.has('src/runtime/agent.ts')).toBe(true);
  });

  it('content format: global first, then scoped in activation order', () => {
    const global1 = makeGlobalRule('.claude/b-global.md', '# Global B');
    const global2 = makeGlobalRule('.claude/a-global.md', '# Global A');
    const scoped1 = makeScopedRule('src/tools', 'src/tools/.claude/CLAUDE.md', '# Tools');
    const scoped2 = makeScopedRule('src/context', 'src/context/.claude/CLAUDE.md', '# Context');
    const index = new RulesIndex([global1, global2, scoped1, scoped2]);
    const tracker = new RulesTracker();
    tracker.setRulesIndex(index);

    // Activate tools first, then context
    tracker.touchPath('src/tools/read.ts');
    tracker.touchPath('src/context/loader.ts');

    const content = tracker.buildDynamicRulesContent()!;
    const globalAPos = content.indexOf('# Global A');
    const globalBPos = content.indexOf('# Global B');
    const toolsPos = content.indexOf('# Tools');
    const contextPos = content.indexOf('# Context');

    // Globals sorted by relativePath (a < b)
    expect(globalAPos).toBeLessThan(globalBPos);
    // Globals before scoped
    expect(globalBPos).toBeLessThan(toolsPos);
    // Scoped in activation order (tools first, then context)
    expect(toolsPos).toBeLessThan(contextPos);
  });

  it('each rule section includes Rule comment header', () => {
    const global = makeGlobalRule('.claude/CLAUDE.md', '# G');
    const scoped = makeScopedRule('src/context', 'src/context/.claude/CLAUDE.md', '# C');
    const index = new RulesIndex([global, scoped]);
    const tracker = new RulesTracker();
    tracker.setRulesIndex(index);
    tracker.touchPath('src/context/x.ts');

    const content = tracker.buildDynamicRulesContent()!;
    expect(content).toContain('<!-- Rule: .claude/CLAUDE.md -->');
    expect(content).toContain('<!-- Rule: src/context/.claude/CLAUDE.md (activated) -->');
  });

  it('clearDynamicState resets all activation state', () => {
    const scoped = makeScopedRule('src/context', 'src/context/.claude/CLAUDE.md', '# Context');
    const index = new RulesIndex([scoped]);
    const tracker = new RulesTracker();
    tracker.setRulesIndex(index);

    tracker.touchPath('src/context/loader.ts');
    expect(tracker.getActivatedScopedRulesCount()).toBe(1);
    expect(tracker.getTouchedPaths().size).toBe(1);

    tracker.clearDynamicState();
    expect(tracker.getActivatedScopedRulesCount()).toBe(0);
    expect(tracker.getTouchedPaths().size).toBe(0);
    // Index is preserved
    expect(tracker.getRulesIndex()).toBe(index);
  });

  it('returns undefined when index exists but no global or activated rules', () => {
    const scoped = makeScopedRule('src/context', 'src/context/.claude/CLAUDE.md');
    const index = new RulesIndex([scoped]);
    const tracker = new RulesTracker();
    tracker.setRulesIndex(index);

    // No paths touched → no activated rules, no globals
    expect(tracker.buildDynamicRulesContent()).toBeUndefined();
  });

  it('touchPath with no index returns false', () => {
    const tracker = new RulesTracker();
    expect(tracker.touchPath('anything.ts')).toBe(false);
  });

  it('hasRules returns true when index has rules but no static files loaded', () => {
    const scoped = makeScopedRule('src/context', 'src/context/.claude/CLAUDE.md');
    const index = new RulesIndex([scoped]);
    const tracker = new RulesTracker();
    tracker.setRulesIndex(index);

    expect(tracker.hasRules()).toBe(true);
  });

  it('existing static methods still work', () => {
    const tracker = RulesTracker.fromEvents([
      {
        id: 'evt-1',
        type: 'rules.loaded',
        payload: {
          files: [
            {
              path: '/p/.claude/AGENTS.md',
              relativePath: '.claude/AGENTS.md',
              level: 'project',
              depth: 0,
              sizeBytes: 50,
            },
          ],
          totalFiles: 1,
          mergedTokens: 25,
        },
      },
    ]);

    expect(tracker.hasRules()).toBe(true);
    expect(tracker.getTotalFiles()).toBe(1);
    expect(tracker.getMergedTokens()).toBe(25);
  });
});
