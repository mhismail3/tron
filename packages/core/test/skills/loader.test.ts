/**
 * @fileoverview Skill Loader Tests
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';
import { SkillLoader, BUILT_IN_SKILLS, createSkillLoader } from '../../src/skills/loader.js';

describe('Skill Loader', () => {
  let testDir: string;

  beforeEach(async () => {
    testDir = await fs.mkdtemp(path.join(os.tmpdir(), 'tron-skills-'));
  });

  afterEach(async () => {
    await fs.rm(testDir, { recursive: true, force: true });
  });

  describe('discover', () => {
    it('should include built-in skills', async () => {
      const loader = createSkillLoader([testDir]);
      const skills = await loader.discover();

      expect(skills.some(s => s.id === 'commit')).toBe(true);
      expect(skills.some(s => s.id === 'handoff')).toBe(true);
      expect(skills.some(s => s.id === 'ledger')).toBe(true);
    });

    it('should load skills from directory', async () => {
      // Create a skill file
      const skillContent = `---
name: Custom Skill
description: A custom skill
command: custom
---
Do custom things.`;

      await fs.writeFile(path.join(testDir, 'SKILL.md'), skillContent);

      const loader = createSkillLoader([testDir]);
      const skills = await loader.discover();

      expect(skills.some(s => s.id === 'custom')).toBe(true);
    });

    it('should load skills from subdirectories', async () => {
      // Create skill in subdirectory
      const skillDir = path.join(testDir, 'my-skill');
      await fs.mkdir(skillDir);

      const skillContent = `---
name: Nested Skill
description: A nested skill
command: nested
---
Nested instructions.`;

      await fs.writeFile(path.join(skillDir, 'SKILL.md'), skillContent);

      const loader = createSkillLoader([testDir]);
      const skills = await loader.discover();

      expect(skills.some(s => s.id === 'nested')).toBe(true);
    });

    it('should load .skill.md files', async () => {
      const skillContent = `---
name: Alt Skill
description: Alternative format
command: alt
---
Alt instructions.`;

      await fs.writeFile(path.join(testDir, 'alt.skill.md'), skillContent);

      const loader = createSkillLoader([testDir]);
      const skills = await loader.discover();

      expect(skills.some(s => s.id === 'alt')).toBe(true);
    });

    it('should skip built-in skills when configured', async () => {
      const loader = new SkillLoader({
        skillDirs: [testDir],
        includeBuiltIn: false,
      });

      const skills = await loader.discover();

      expect(skills.some(s => s.id === 'commit')).toBe(false);
    });
  });

  describe('load', () => {
    it('should load built-in skill by ID', async () => {
      const loader = createSkillLoader([testDir]);
      const skill = await loader.load('commit');

      expect(skill).not.toBeNull();
      expect(skill!.name).toBe('Commit');
    });

    it('should load built-in skill by command', async () => {
      const loader = createSkillLoader([testDir]);
      const skill = await loader.load('handoff');

      expect(skill).not.toBeNull();
      expect(skill!.id).toBe('handoff');
    });

    it('should load user skill from directory', async () => {
      const skillDir = path.join(testDir, 'my-skill');
      await fs.mkdir(skillDir);

      await fs.writeFile(
        path.join(skillDir, 'SKILL.md'),
        `---
name: My Skill
description: A skill
command: my-skill
---
Instructions.`
      );

      const loader = createSkillLoader([testDir]);
      const skill = await loader.load('my-skill');

      expect(skill).not.toBeNull();
      expect(skill!.name).toBe('My Skill');
    });

    it('should return null for non-existent skill', async () => {
      const loader = createSkillLoader([testDir]);
      const skill = await loader.load('non-existent');

      expect(skill).toBeNull();
    });
  });

  describe('BUILT_IN_SKILLS', () => {
    it('should have commit skill', () => {
      const commit = BUILT_IN_SKILLS.find(s => s.id === 'commit');
      expect(commit).toBeDefined();
      expect(commit!.command).toBe('commit');
    });

    it('should have handoff skill', () => {
      const handoff = BUILT_IN_SKILLS.find(s => s.id === 'handoff');
      expect(handoff).toBeDefined();
    });

    it('should have ledger skill', () => {
      const ledger = BUILT_IN_SKILLS.find(s => s.id === 'ledger');
      expect(ledger).toBeDefined();
    });

    it('should have context skill', () => {
      const context = BUILT_IN_SKILLS.find(s => s.id === 'context');
      expect(context).toBeDefined();
    });

    it('should have export skill', () => {
      const exportSkill = BUILT_IN_SKILLS.find(s => s.id === 'export');
      expect(exportSkill).toBeDefined();
      expect(exportSkill!.arguments).toBeDefined();
    });
  });
});
