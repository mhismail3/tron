/**
 * @fileoverview Skill Loader Tests
 *
 * Tests for:
 * - Frontmatter passthrough from skillLoader callback to buildSkillContext
 * - Tool preference/restriction rendering via frontmatter
 * - Subagent mode routing (no/ask/yes)
 * - SkillLoadResult return type
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { SkillLoader, createSkillLoader } from '../skill-loader.js';
import type { SkillLoadContext } from '../skill-loader.js';
import type { AgentRunOptions, LoadedSkillContent } from '../../types.js';
import type { SkillFrontmatter } from '@capabilities/extensions/skills/types.js';

// =============================================================================
// Mocks
// =============================================================================

vi.mock('@infrastructure/logging/index.js', () => ({
  createLogger: vi.fn().mockReturnValue({
    info: vi.fn(),
    debug: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
  }),
}));

vi.mock('@infrastructure/settings/index.js', () => ({
  getSettings: vi.fn(),
}));

import { getSettings } from '@infrastructure/settings/index.js';

// =============================================================================
// Fixtures
// =============================================================================

function createMockContext(): SkillLoadContext {
  return {
    sessionId: 'sess_test',
    skillTracker: {
      hasSkill: vi.fn().mockReturnValue(false),
      addSkill: vi.fn(),
      getAddedSkills: vi.fn().mockReturnValue([]),
      getRemovedSkillNames: vi.fn().mockReturnValue([]),
      getUsedSpellNames: vi.fn().mockReturnValue([]),
      addUsedSpell: vi.fn(),
      setContentLength: vi.fn(),
    } as any,
    sessionContext: {
      appendEvent: vi.fn().mockResolvedValue({ id: 'evt_test' }),
    } as any,
  };
}

function makeSkillLoader(skills: LoadedSkillContent[]): (names: string[]) => Promise<LoadedSkillContent[]> {
  return vi.fn().mockResolvedValue(skills);
}

function makeOptions(overrides: Partial<AgentRunOptions> = {}): AgentRunOptions {
  return {
    sessionId: 'sess_test',
    prompt: 'do something',
    ...overrides,
  };
}

// =============================================================================
// Phase 1: Frontmatter passthrough
// =============================================================================

describe('SkillLoader — frontmatter passthrough', () => {
  let loader: SkillLoader;

  beforeEach(() => {
    loader = createSkillLoader();
    (getSettings as any).mockReturnValue({
      models: { subagent: 'claude-haiku-4-5-20251001' },
    });
  });

  it('passes frontmatter through to buildSkillContext', async () => {
    const ctx = createMockContext();
    ctx.skillTracker.getAddedSkills = vi.fn().mockReturnValue([
      { name: 'test-skill' },
    ]);

    const frontmatter: SkillFrontmatter = {
      allowedTools: ['Read', 'Write'],
    };
    const skillLoader = makeSkillLoader([
      { name: 'test-skill', content: 'do stuff', frontmatter },
    ]);

    const result = await loader.loadSkillContextForPrompt(ctx, makeOptions({ skillLoader }));

    // Should include tool preferences from frontmatter
    expect(result.skillContext).toContain('skill-tool-preferences');
    expect(result.skillContext).toContain('Read, Write');
  });

  it('renders deniedTools as skill-tool-restrictions', async () => {
    const ctx = createMockContext();
    ctx.skillTracker.getAddedSkills = vi.fn().mockReturnValue([
      { name: 'restricted-skill' },
    ]);

    const frontmatter: SkillFrontmatter = {
      deniedTools: ['Bash', 'SpawnSubagent'],
    };
    const skillLoader = makeSkillLoader([
      { name: 'restricted-skill', content: 'read only', frontmatter },
    ]);

    const result = await loader.loadSkillContextForPrompt(ctx, makeOptions({ skillLoader }));

    expect(result.skillContext).toContain('skill-tool-restrictions');
    expect(result.skillContext).toContain('Bash, SpawnSubagent');
  });

  it('renders no tool blocks when frontmatter is empty', async () => {
    const ctx = createMockContext();
    ctx.skillTracker.getAddedSkills = vi.fn().mockReturnValue([
      { name: 'plain-skill' },
    ]);

    const skillLoader = makeSkillLoader([
      { name: 'plain-skill', content: 'just content', frontmatter: {} },
    ]);

    const result = await loader.loadSkillContextForPrompt(ctx, makeOptions({ skillLoader }));

    expect(result.skillContext).not.toContain('skill-tool-preferences');
    expect(result.skillContext).not.toContain('skill-tool-restrictions');
    expect(result.skillContext).toContain('just content');
  });

  it('renders no tool blocks when frontmatter is undefined', async () => {
    const ctx = createMockContext();
    ctx.skillTracker.getAddedSkills = vi.fn().mockReturnValue([
      { name: 'no-fm-skill' },
    ]);

    const skillLoader = makeSkillLoader([
      { name: 'no-fm-skill', content: 'content only' },
    ]);

    const result = await loader.loadSkillContextForPrompt(ctx, makeOptions({ skillLoader }));

    expect(result.skillContext).not.toContain('skill-tool-preferences');
    expect(result.skillContext).not.toContain('skill-tool-restrictions');
    expect(result.skillContext).toContain('content only');
  });
});

// =============================================================================
// Phase 3: Subagent mode routing
// =============================================================================

describe('SkillLoader — subagent mode routing', () => {
  let loader: SkillLoader;

  beforeEach(() => {
    loader = createSkillLoader();
    (getSettings as any).mockReturnValue({
      models: { subagent: 'claude-haiku-4-5-20251001' },
    });
  });

  it('subagent: "no" — skill appears in skillContext, not in subagentSkills', async () => {
    const ctx = createMockContext();
    ctx.skillTracker.getAddedSkills = vi.fn().mockReturnValue([
      { name: 'inline-skill' },
    ]);

    const skillLoader = makeSkillLoader([
      {
        name: 'inline-skill',
        content: 'inline content',
        frontmatter: { subagent: 'no' },
      },
    ]);

    const result = await loader.loadSkillContextForPrompt(ctx, makeOptions({ skillLoader }));

    expect(result.skillContext).toContain('inline content');
    expect(result.subagentSkills).toHaveLength(0);
  });

  it('default (no subagent field) — treated as "no"', async () => {
    const ctx = createMockContext();
    ctx.skillTracker.getAddedSkills = vi.fn().mockReturnValue([
      { name: 'default-skill' },
    ]);

    const skillLoader = makeSkillLoader([
      {
        name: 'default-skill',
        content: 'default content',
        frontmatter: {},
      },
    ]);

    const result = await loader.loadSkillContextForPrompt(ctx, makeOptions({ skillLoader }));

    expect(result.skillContext).toContain('default content');
    expect(result.subagentSkills).toHaveLength(0);
  });

  it('subagent: "yes" — skill in subagentSkills with toolDenials and model', async () => {
    const ctx = createMockContext();
    ctx.skillTracker.getAddedSkills = vi.fn().mockReturnValue([
      { name: 'sub-skill' },
    ]);

    const skillLoader = makeSkillLoader([
      {
        name: 'sub-skill',
        content: 'subagent content',
        frontmatter: {
          subagent: 'yes',
          deniedTools: ['Bash'],
        },
      },
    ]);

    const result = await loader.loadSkillContextForPrompt(ctx, makeOptions({ skillLoader }));

    // Should NOT be in skillContext
    expect(result.skillContext).not.toContain('subagent content');

    // Should be in subagentSkills
    expect(result.subagentSkills).toHaveLength(1);
    expect(result.subagentSkills[0].name).toBe('sub-skill');
    expect(result.subagentSkills[0].content).toBe('subagent content');
    expect(result.subagentSkills[0].toolDenials).toEqual({ tools: ['Bash'] });
    expect(result.subagentSkills[0].model).toBe('claude-haiku-4-5-20251001');
  });

  it('subagent: "yes" + subagentModel — uses frontmatter model', async () => {
    const ctx = createMockContext();
    ctx.skillTracker.getAddedSkills = vi.fn().mockReturnValue([
      { name: 'custom-model-skill' },
    ]);

    const skillLoader = makeSkillLoader([
      {
        name: 'custom-model-skill',
        content: 'model content',
        frontmatter: {
          subagent: 'yes',
          subagentModel: 'claude-opus-4-6',
        },
      },
    ]);

    const result = await loader.loadSkillContextForPrompt(ctx, makeOptions({ skillLoader }));

    expect(result.subagentSkills).toHaveLength(1);
    expect(result.subagentSkills[0].model).toBe('claude-opus-4-6');
  });

  it('subagent: "yes" without subagentModel — uses settings.models.subagent', async () => {
    const ctx = createMockContext();
    ctx.skillTracker.getAddedSkills = vi.fn().mockReturnValue([
      { name: 'default-model-skill' },
    ]);

    const skillLoader = makeSkillLoader([
      {
        name: 'default-model-skill',
        content: 'some content',
        frontmatter: { subagent: 'yes' },
      },
    ]);

    const result = await loader.loadSkillContextForPrompt(ctx, makeOptions({ skillLoader }));

    expect(result.subagentSkills).toHaveLength(1);
    expect(result.subagentSkills[0].model).toBe('claude-haiku-4-5-20251001');
  });

  it('subagent: "ask" — skill in skillContext with confirmation wrapper', async () => {
    const ctx = createMockContext();
    ctx.skillTracker.getAddedSkills = vi.fn().mockReturnValue([
      { name: 'ask-skill' },
    ]);

    const skillLoader = makeSkillLoader([
      {
        name: 'ask-skill',
        content: 'ask content',
        frontmatter: { subagent: 'ask' },
      },
    ]);

    const result = await loader.loadSkillContextForPrompt(ctx, makeOptions({ skillLoader }));

    // Should be in skillContext with confirmation wrapper
    expect(result.skillContext).toContain('skill-requires-confirmation');
    expect(result.skillContext).toContain('AskUserQuestion');
    expect(result.skillContext).toContain('ask content');
    // Should NOT be in subagentSkills
    expect(result.subagentSkills).toHaveLength(0);
  });

  it('mixed modes — correct partitioning', async () => {
    const ctx = createMockContext();
    ctx.skillTracker.getAddedSkills = vi.fn().mockReturnValue([
      { name: 'inline' },
      { name: 'spawned' },
      { name: 'confirmed' },
    ]);

    const skillLoader = makeSkillLoader([
      { name: 'inline', content: 'inline body', frontmatter: { subagent: 'no' } },
      { name: 'spawned', content: 'spawned body', frontmatter: { subagent: 'yes' } },
      { name: 'confirmed', content: 'confirmed body', frontmatter: { subagent: 'ask' } },
    ]);

    const result = await loader.loadSkillContextForPrompt(ctx, makeOptions({ skillLoader }));

    // inline and confirmed in skillContext
    expect(result.skillContext).toContain('inline body');
    expect(result.skillContext).toContain('confirmed body');
    expect(result.skillContext).toContain('skill-requires-confirmation');

    // spawned NOT in skillContext
    expect(result.skillContext).not.toContain('spawned body');

    // spawned in subagentSkills
    expect(result.subagentSkills).toHaveLength(1);
    expect(result.subagentSkills[0].name).toBe('spawned');
  });

  it('returns empty results when no skills', async () => {
    const ctx = createMockContext();
    ctx.skillTracker.getAddedSkills = vi.fn().mockReturnValue([]);

    const result = await loader.loadSkillContextForPrompt(ctx, makeOptions());

    expect(result.skillContext).toBe('');
    expect(result.subagentSkills).toHaveLength(0);
  });

  it('returns empty results when no skillLoader provided', async () => {
    const ctx = createMockContext();
    ctx.skillTracker.getAddedSkills = vi.fn().mockReturnValue([
      { name: 'some-skill' },
    ]);

    const result = await loader.loadSkillContextForPrompt(ctx, makeOptions());

    expect(result.skillContext).toBe('');
    expect(result.subagentSkills).toHaveLength(0);
  });

  it('subagent: "yes" with allowedTools — computes toolDenials via inversion', async () => {
    const ctx = createMockContext();
    ctx.skillTracker.getAddedSkills = vi.fn().mockReturnValue([
      { name: 'allow-skill' },
    ]);

    const skillLoader = makeSkillLoader([
      {
        name: 'allow-skill',
        content: 'restricted',
        frontmatter: {
          subagent: 'yes',
          allowedTools: ['Read', 'Write'],
        },
      },
    ]);

    const result = await loader.loadSkillContextForPrompt(ctx, makeOptions({ skillLoader }));

    expect(result.subagentSkills).toHaveLength(1);
    const denials = result.subagentSkills[0].toolDenials;
    // Should have tools denied (everything except Read, Write)
    expect(denials).toBeDefined();
    expect(denials!.tools).toBeDefined();
    expect(denials!.tools).not.toContain('Read');
    expect(denials!.tools).not.toContain('Write');
    expect(denials!.tools).toContain('Bash');
  });

  it('calls setContentLength on skillTracker after loading', async () => {
    const ctx = createMockContext();
    ctx.skillTracker.getAddedSkills = vi.fn().mockReturnValue([
      { name: 'skill-a' },
      { name: 'skill-b' },
    ]);

    const skillLoader = makeSkillLoader([
      { name: 'skill-a', content: 'short content', frontmatter: {} },
      { name: 'skill-b', content: 'a'.repeat(1000), frontmatter: {} },
    ]);

    await loader.loadSkillContextForPrompt(ctx, makeOptions({ skillLoader }));

    expect(ctx.skillTracker.setContentLength).toHaveBeenCalledWith('skill-a', 'short content'.length);
    expect(ctx.skillTracker.setContentLength).toHaveBeenCalledWith('skill-b', 1000);
  });

  it('includes removed-skills instruction in skillContext when present', async () => {
    const ctx = createMockContext();
    ctx.skillTracker.getAddedSkills = vi.fn().mockReturnValue([
      { name: 'active-skill' },
    ]);
    ctx.skillTracker.getRemovedSkillNames = vi.fn().mockReturnValue(['old-skill']);

    const skillLoader = makeSkillLoader([
      { name: 'active-skill', content: 'active content', frontmatter: {} },
    ]);

    const result = await loader.loadSkillContextForPrompt(ctx, makeOptions({ skillLoader }));

    expect(result.skillContext).toContain('removed-skills');
    expect(result.skillContext).toContain('@old-skill');
    expect(result.skillContext).toContain('active content');
  });
});
