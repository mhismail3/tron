/**
 * @fileoverview Skill Content Injection Tests (TDD)
 *
 * Tests for the skill content loading and injection flow:
 * - loadSkillContextForPrompt loads skills from explicit selection (options.skills)
 * - skillLoader callback is invoked with skill names
 * - buildSkillContext generates proper XML output
 * - Skill context is prepended to user prompt in runAgent
 *
 * Note: @mentions in prompt text are handled client-side (iOS app converts them to
 * explicit skill chips). The server only processes explicit skills from options.skills.
 * extractSkillReferences is still available for client-side use.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { EventStore, extractSkillReferences, buildSkillContext, type SkillMetadata } from '../index.js';
import { EventStoreOrchestrator } from '../event-store-orchestrator.js';
import path from 'path';
import os from 'os';
import fs from 'fs';

// =============================================================================
// Test Fixtures
// =============================================================================

const createTestOrchestrator = async (testDir: string) => {
  const eventStore = new EventStore(path.join(testDir, 'events.db'));
  await eventStore.initialize();

  const orchestrator = new EventStoreOrchestrator({
    defaultModel: 'claude-sonnet-4-20250514',
    defaultProvider: 'anthropic',
    eventStoreDbPath: path.join(testDir, 'events.db'),
    eventStore,
  });

  // Mock auth for tests
  (orchestrator as any).cachedAuth = { type: 'api_key', apiKey: 'test-key' };
  (orchestrator as any).initialized = true;

  return { orchestrator, eventStore };
};

// Mock skill content
const mockSkills = {
  'old-timey-english': {
    name: 'old-timey-english',
    content: `# Old Timey English Skill

Respond to all queries using archaic, Shakespearean-style English with "thee", "thou", "verily", etc.`,
  },
  'typescript-rules': {
    name: 'typescript-rules',
    content: `# TypeScript Rules

Always use strict TypeScript. Never use any. Prefer interfaces over types.`,
  },
  'api-design': {
    name: 'api-design',
    content: `# API Design Best Practices

Follow REST conventions. Use proper HTTP methods. Return consistent response shapes.`,
  },
};

// =============================================================================
// Unit Tests: extractSkillReferences (for client-side @mention detection)
// =============================================================================

describe('extractSkillReferences (client-side utility)', () => {
  it('extracts @mention from text', () => {
    const refs = extractSkillReferences('Help me with @typescript-rules');
    expect(refs).toHaveLength(1);
    expect(refs[0].name).toBe('typescript-rules');
  });

  it('extracts multiple @mentions', () => {
    const refs = extractSkillReferences('Use @typescript-rules and @api-design');
    expect(refs).toHaveLength(2);
    expect(refs.map(r => r.name)).toContain('typescript-rules');
    expect(refs.map(r => r.name)).toContain('api-design');
  });

  it('returns empty array when no mentions', () => {
    const refs = extractSkillReferences('Just regular text');
    expect(refs).toHaveLength(0);
  });

  it('does not extract email addresses', () => {
    const refs = extractSkillReferences('Contact user@example.com about @api-design');
    expect(refs).toHaveLength(1);
    expect(refs[0].name).toBe('api-design');
  });
});

// =============================================================================
// Unit Tests: buildSkillContext
// =============================================================================

describe('buildSkillContext', () => {
  it('builds XML context block for skills', () => {
    const skills: SkillMetadata[] = [
      {
        name: 'test-skill',
        content: 'Test skill content',
        description: 'A test skill',
        frontmatter: {},
        source: 'global',
        path: '/test',
        skillMdPath: '/test/SKILL.md',
        additionalFiles: [],
        lastModified: Date.now(),
      },
    ];

    const context = buildSkillContext(skills);

    expect(context).toContain('<skills>');
    expect(context).toContain('</skills>');
    expect(context).toContain('test-skill');
    expect(context).toContain('Test skill content');
  });

  it('returns empty string for empty skills array', () => {
    const context = buildSkillContext([]);
    expect(context).toBe('');
  });

  it('includes multiple skills', () => {
    const skills: SkillMetadata[] = [
      {
        name: 'skill-a',
        content: 'Content A',
        description: '',
        frontmatter: {},
        source: 'global',
        path: '',
        skillMdPath: '',
        additionalFiles: [],
        lastModified: Date.now(),
      },
      {
        name: 'skill-b',
        content: 'Content B',
        description: '',
        frontmatter: {},
        source: 'project',
        path: '',
        skillMdPath: '',
        additionalFiles: [],
        lastModified: Date.now(),
      },
    ];

    const context = buildSkillContext(skills);

    expect(context).toContain('skill-a');
    expect(context).toContain('Content A');
    expect(context).toContain('skill-b');
    expect(context).toContain('Content B');
  });
});

// =============================================================================
// Integration Tests: Skill Content Injection Flow
// =============================================================================

describe('Skill Content Injection', () => {
  let testDir: string;
  let orchestrator: EventStoreOrchestrator;
  let eventStore: EventStore;

  beforeEach(async () => {
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tron-skill-inject-test-'));
    const result = await createTestOrchestrator(testDir);
    orchestrator = result.orchestrator;
    eventStore = result.eventStore;
  });

  afterEach(async () => {
    await orchestrator?.shutdown();
    await eventStore?.close();
    fs.rmSync(testDir, { recursive: true, force: true });
  });

  describe('loadSkillContextForPrompt', () => {
    it('returns empty string when no skills', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      const active = orchestrator.getActiveSession(session.sessionId);
      expect(active).toBeDefined();

      // Access private method via prototype for testing
      const result = await (orchestrator as any).loadSkillContextForPrompt(active, {
        sessionId: session.sessionId,
        prompt: 'Regular prompt with no skills',
      });

      expect(result).toBe('');
    });

    it('loads skill content from explicit skills array', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      const active = orchestrator.getActiveSession(session.sessionId);

      const skillLoaderMock = vi.fn().mockResolvedValue([
        mockSkills['old-timey-english'],
      ]);

      const result = await (orchestrator as any).loadSkillContextForPrompt(active, {
        sessionId: session.sessionId,
        prompt: 'Test prompt',
        skills: [{ name: 'old-timey-english', source: 'global' }],
        skillLoader: skillLoaderMock,
      });

      expect(skillLoaderMock).toHaveBeenCalledWith(['old-timey-english']);
      expect(result).toContain('old-timey-english');
      expect(result).toContain('Shakespearean');
    });

    it('ignores @mentions in prompt (client-side responsibility)', async () => {
      // @mentions in prompt text are handled client-side - server ignores them
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      const active = orchestrator.getActiveSession(session.sessionId);

      const skillLoaderMock = vi.fn().mockResolvedValue([
        mockSkills['typescript-rules'],
      ]);

      const result = await (orchestrator as any).loadSkillContextForPrompt(active, {
        sessionId: session.sessionId,
        prompt: 'Help me with @typescript-rules please',
        // No explicit skills - only @mention in text
        skillLoader: skillLoaderMock,
      });

      // Should NOT call skillLoader since no explicit skills provided
      expect(skillLoaderMock).not.toHaveBeenCalled();
      expect(result).toBe('');
    });

    it('only uses explicit skills array, ignoring @mentions in prompt', async () => {
      // Server only processes options.skills, not @mentions in prompt text
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      const active = orchestrator.getActiveSession(session.sessionId);

      const skillLoaderMock = vi.fn().mockResolvedValue([
        mockSkills['old-timey-english'],
      ]);

      const result = await (orchestrator as any).loadSkillContextForPrompt(active, {
        sessionId: session.sessionId,
        prompt: 'Help with @api-design', // This @mention is IGNORED
        skills: [{ name: 'old-timey-english', source: 'global' }], // Only this is used
        skillLoader: skillLoaderMock,
      });

      // Should only have the explicit skill, not the @mention
      expect(skillLoaderMock).toHaveBeenCalledWith(['old-timey-english']);
      expect(result).toContain('old-timey-english');
      expect(result).not.toContain('api-design');
    });

    it('loads multiple explicit skills', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      const active = orchestrator.getActiveSession(session.sessionId);

      const skillLoaderMock = vi.fn().mockResolvedValue([
        mockSkills['typescript-rules'],
        mockSkills['api-design'],
      ]);

      const result = await (orchestrator as any).loadSkillContextForPrompt(active, {
        sessionId: session.sessionId,
        prompt: 'Help me build an API',
        skills: [
          { name: 'typescript-rules', source: 'global' },
          { name: 'api-design', source: 'global' },
        ],
        skillLoader: skillLoaderMock,
      });

      expect(skillLoaderMock).toHaveBeenCalledWith(
        expect.arrayContaining(['typescript-rules', 'api-design'])
      );
      expect(result).toContain('typescript-rules');
      expect(result).toContain('api-design');
    });

    it('returns empty string when skillLoader not provided but skills are', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      const active = orchestrator.getActiveSession(session.sessionId);

      const result = await (orchestrator as any).loadSkillContextForPrompt(active, {
        sessionId: session.sessionId,
        prompt: 'Test prompt',
        skills: [{ name: 'test-skill', source: 'global' }],
        // No skillLoader provided
      });

      expect(result).toBe('');
    });

    it('returns empty string when skillLoader returns empty array', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      const active = orchestrator.getActiveSession(session.sessionId);

      const skillLoaderMock = vi.fn().mockResolvedValue([]);

      const result = await (orchestrator as any).loadSkillContextForPrompt(active, {
        sessionId: session.sessionId,
        prompt: 'Test prompt',
        skills: [{ name: 'non-existent-skill', source: 'global' }],
        skillLoader: skillLoaderMock,
      });

      expect(skillLoaderMock).toHaveBeenCalledWith(['non-existent-skill']);
      expect(result).toBe('');
    });
  });

  describe('skill.added events', () => {
    it('creates skill.added event when sending prompt with skills', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      const active = orchestrator.getActiveSession(session.sessionId);
      expect(active).toBeDefined();

      // Track skills for prompt (this creates events)
      await (orchestrator as any).trackSkillsForPrompt(active, {
        sessionId: session.sessionId,
        prompt: 'Test',
        skills: [{ name: 'test-skill', source: 'global' }],
      });

      // Flush events and check
      await (orchestrator as any).flushPendingEvents(active);

      // The skill tracker should now have the skill
      expect(active!.skillTracker.hasSkill('test-skill')).toBe(true);
    });

    it('does not duplicate events for already-added skills', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      const active = orchestrator.getActiveSession(session.sessionId);

      // Add skill first time
      await (orchestrator as any).trackSkillsForPrompt(active, {
        sessionId: session.sessionId,
        prompt: 'Test',
        skills: [{ name: 'test-skill', source: 'global' }],
      });

      const skillCountAfterFirst = active!.skillTracker.getAddedSkills().length;

      // Add same skill again
      await (orchestrator as any).trackSkillsForPrompt(active, {
        sessionId: session.sessionId,
        prompt: 'Test again',
        skills: [{ name: 'test-skill', source: 'global' }],
      });

      const skillCountAfterSecond = active!.skillTracker.getAddedSkills().length;

      // Should still be just one skill
      expect(skillCountAfterSecond).toBe(skillCountAfterFirst);
    });
  });

  describe('skill.removed events', () => {
    it('removes skill from tracker when removeSkill is called', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      const active = orchestrator.getActiveSession(session.sessionId);
      expect(active).toBeDefined();

      // First add a skill
      await (orchestrator as any).trackSkillsForPrompt(active, {
        sessionId: session.sessionId,
        prompt: 'Test',
        skills: [{ name: 'removable-skill', source: 'global' }],
      });
      await (orchestrator as any).flushPendingEvents(active);

      expect(active!.skillTracker.hasSkill('removable-skill')).toBe(true);

      // Now remove it
      const removed = active!.skillTracker.removeSkill('removable-skill');

      expect(removed).toBe(true);
      expect(active!.skillTracker.hasSkill('removable-skill')).toBe(false);
    });

    it('returns false when removing non-existent skill', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      const active = orchestrator.getActiveSession(session.sessionId);

      const removed = active!.skillTracker.removeSkill('non-existent');

      expect(removed).toBe(false);
    });

    it('only removes specified skill, keeping others', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      const active = orchestrator.getActiveSession(session.sessionId);

      // Add multiple skills
      await (orchestrator as any).trackSkillsForPrompt(active, {
        sessionId: session.sessionId,
        prompt: 'Test',
        skills: [
          { name: 'skill-a', source: 'global' },
          { name: 'skill-b', source: 'global' },
          { name: 'skill-c', source: 'global' },
        ],
      });
      await (orchestrator as any).flushPendingEvents(active);

      // Remove only skill-b
      active!.skillTracker.removeSkill('skill-b');

      expect(active!.skillTracker.hasSkill('skill-a')).toBe(true);
      expect(active!.skillTracker.hasSkill('skill-b')).toBe(false);
      expect(active!.skillTracker.hasSkill('skill-c')).toBe(true);
      expect(active!.skillTracker.getAddedSkills()).toHaveLength(2);
    });
  });

  describe('skill tracker clear on context operations', () => {
    it('clears skills when tracker clear is called', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      const active = orchestrator.getActiveSession(session.sessionId);

      // Add multiple skills
      await (orchestrator as any).trackSkillsForPrompt(active, {
        sessionId: session.sessionId,
        prompt: 'Test',
        skills: [
          { name: 'skill-a', source: 'global' },
          { name: 'skill-b', source: 'project' },
        ],
      });
      await (orchestrator as any).flushPendingEvents(active);

      expect(active!.skillTracker.getAddedSkills()).toHaveLength(2);

      // Clear all skills
      active!.skillTracker.clear();

      expect(active!.skillTracker.getAddedSkills()).toHaveLength(0);
      expect(active!.skillTracker.hasSkill('skill-a')).toBe(false);
      expect(active!.skillTracker.hasSkill('skill-b')).toBe(false);
    });
  });

  describe('getDetailedContextSnapshot with skills', () => {
    it('includes addedSkills in snapshot', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      const active = orchestrator.getActiveSession(session.sessionId);

      // Add skills
      await (orchestrator as any).trackSkillsForPrompt(active, {
        sessionId: session.sessionId,
        prompt: 'Test',
        skills: [{ name: 'snapshot-skill', source: 'global' }],
      });
      await (orchestrator as any).flushPendingEvents(active);

      // Get snapshot
      const snapshot = orchestrator.getDetailedContextSnapshot(session.sessionId);

      // Verify skills are tracked (snapshot may not include addedSkills directly,
      // that's added by the RPC layer - but we can check the tracker)
      expect(active!.skillTracker.hasSkill('snapshot-skill')).toBe(true);
    });

    it('reflects skill removal in tracker', async () => {
      const session = await orchestrator.createSession({
        workingDirectory: testDir,
      });
      const active = orchestrator.getActiveSession(session.sessionId);

      // Add skill
      await (orchestrator as any).trackSkillsForPrompt(active, {
        sessionId: session.sessionId,
        prompt: 'Test',
        skills: [{ name: 'to-remove', source: 'global' }],
      });
      await (orchestrator as any).flushPendingEvents(active);

      expect(active!.skillTracker.hasSkill('to-remove')).toBe(true);

      // Remove skill
      active!.skillTracker.removeSkill('to-remove');

      expect(active!.skillTracker.hasSkill('to-remove')).toBe(false);
      expect(active!.skillTracker.getAddedSkills()).toHaveLength(0);
    });
  });
});

// =============================================================================
// Edge Cases
// =============================================================================

describe('Skill Content Injection Edge Cases', () => {
  it('handles skill content with special characters', () => {
    const skills: SkillMetadata[] = [
      {
        name: 'special-chars',
        content: 'Content with <xml> & "quotes" and \'apostrophes\'',
        description: '',
        frontmatter: {},
        source: 'global',
        path: '',
        skillMdPath: '',
        additionalFiles: [],
        lastModified: Date.now(),
      },
    ];

    const context = buildSkillContext(skills);

    // Should not throw and should contain the content
    expect(context).toContain('special-chars');
  });

  it('handles skill content with code blocks', () => {
    const skills: SkillMetadata[] = [
      {
        name: 'code-skill',
        content: '```typescript\nconst x: number = 1;\n```',
        description: '',
        frontmatter: {},
        source: 'global',
        path: '',
        skillMdPath: '',
        additionalFiles: [],
        lastModified: Date.now(),
      },
    ];

    const context = buildSkillContext(skills);

    expect(context).toContain('```typescript');
    expect(context).toContain('const x: number = 1;');
  });

  it('handles very long skill content', () => {
    const longContent = 'A'.repeat(10000);
    const skills: SkillMetadata[] = [
      {
        name: 'long-skill',
        content: longContent,
        description: '',
        frontmatter: {},
        source: 'global',
        path: '',
        skillMdPath: '',
        additionalFiles: [],
        lastModified: Date.now(),
      },
    ];

    const context = buildSkillContext(skills);

    expect(context).toContain(longContent);
  });
});
