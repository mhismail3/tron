/**
 * @fileoverview Skill Loader
 *
 * Handles filesystem scanning for skill directories. Scans both global
 * (~/.tron/skills/) and project (.tron/skills/) directories for folders
 * containing SKILL.md files.
 */

import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';
import type { SkillScanResult, SkillScanError, SkillSource } from './types.js';
import { parseSkillMd } from './skill-parser.js';

// =============================================================================
// Constants
// =============================================================================

const SKILL_MD_FILENAME = 'SKILL.md';
const DEFAULT_GLOBAL_SKILLS_DIR = '.tron/skills';
const DEFAULT_PROJECT_SKILLS_DIR = '.tron/skills';
const MAX_SKILL_FILE_SIZE = 100 * 1024; // 100KB limit

// =============================================================================
// Loader Functions
// =============================================================================

/**
 * Get the default global skills directory path
 */
export function getGlobalSkillsDir(): string {
  return path.join(os.homedir(), DEFAULT_GLOBAL_SKILLS_DIR);
}

/**
 * Get the project skills directory path for a working directory
 */
export function getProjectSkillsDir(workingDirectory: string): string {
  return path.join(workingDirectory, DEFAULT_PROJECT_SKILLS_DIR);
}

/**
 * Scan a directory for skill folders (folders containing SKILL.md)
 */
export async function scanSkillsDirectory(
  dirPath: string,
  source: SkillSource
): Promise<SkillScanResult> {
  const skills: SkillScanResult['skills'] = [];
  const errors: SkillScanError[] = [];

  // Check if directory exists
  try {
    await fs.access(dirPath);
  } catch {
    // Directory doesn't exist - return empty result (not an error)
    return { skills, errors };
  }

  // Read directory contents
  let entries;
  try {
    entries = await fs.readdir(dirPath, { withFileTypes: true });
  } catch (error) {
    errors.push({
      path: dirPath,
      message: `Failed to read directory: ${error instanceof Error ? error.message : String(error)}`,
      recoverable: false,
    });
    return { skills, errors };
  }

  // Process each subdirectory
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;

    const entryName = String(entry.name);
    const skillPath = path.join(dirPath, entryName);
    const skillMdPath = path.join(skillPath, SKILL_MD_FILENAME);

    // Check if SKILL.md exists
    try {
      await fs.access(skillMdPath);
    } catch {
      // No SKILL.md - skip this folder (not an error)
      continue;
    }

    // Load and parse the skill
    try {
      const skill = await loadSkill(skillPath, skillMdPath, entryName, source);
      skills.push(skill);
    } catch (error) {
      errors.push({
        path: skillPath,
        message: `Failed to load skill: ${error instanceof Error ? error.message : String(error)}`,
        recoverable: true,
      });
    }
  }

  return { skills, errors };
}

/**
 * Load a single skill from its directory
 */
async function loadSkill(
  skillPath: string,
  skillMdPath: string,
  name: string,
  source: SkillSource
): Promise<SkillScanResult['skills'][0]> {
  // Get file stats for size check and lastModified
  const stats = await fs.stat(skillMdPath);

  if (stats.size > MAX_SKILL_FILE_SIZE) {
    throw new Error(`SKILL.md exceeds maximum size of ${MAX_SKILL_FILE_SIZE} bytes`);
  }

  // Read SKILL.md content
  const rawContent = await fs.readFile(skillMdPath, 'utf-8');

  // Parse frontmatter and content
  const { frontmatter, content, description: extractedDescription } = parseSkillMd(rawContent);

  // List additional files in the skill folder
  const allEntries = await fs.readdir(skillPath, { withFileTypes: true });
  const additionalFiles = allEntries
    .filter(e => e.isFile() && e.name !== SKILL_MD_FILENAME)
    .map(e => e.name);

  // Prefer frontmatter name/description over derived values
  // The folder name is always used as the reference name (@skill-name)
  // But the display name can be overridden in frontmatter
  const displayName = frontmatter.name ?? name;
  const description = frontmatter.description ?? extractedDescription;

  return {
    name,  // Always use folder name for @reference
    displayName,  // Human-readable name for UI display
    description,
    content,
    frontmatter,
    source,
    path: skillPath,
    skillMdPath,
    additionalFiles,
    lastModified: stats.mtimeMs,
  };
}

/**
 * Scan both global and project skill directories
 */
export async function scanAllSkills(
  workingDirectory: string,
  options?: {
    globalSkillsDir?: string;
  }
): Promise<{
  globalResult: SkillScanResult;
  projectResult: SkillScanResult;
}> {
  const globalDir = options?.globalSkillsDir ?? getGlobalSkillsDir();
  const projectDir = getProjectSkillsDir(workingDirectory);

  // Scan both directories in parallel
  const [globalResult, projectResult] = await Promise.all([
    scanSkillsDirectory(globalDir, 'global'),
    scanSkillsDirectory(projectDir, 'project'),
  ]);

  return { globalResult, projectResult };
}
