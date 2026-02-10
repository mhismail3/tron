/**
 * @fileoverview Skill Registry
 *
 * In-memory cache for loaded skills with precedence handling.
 * Project skills take precedence over global skills with the same name.
 */

import type {
  SkillMetadata,
  SkillInfo,
  SkillListOptions,
  SkillRegistryOptions,
} from './types.js';
import { scanAllSkills, getGlobalSkillsDir, getProjectSkillsDir } from './skill-loader.js';
import { createLogger } from '@infrastructure/logging/index.js';

const logger = createLogger('skill-registry');

// =============================================================================
// Skill Registry
// =============================================================================

export class SkillRegistry {
  private skills: Map<string, SkillMetadata> = new Map();
  private workingDirectory: string;
  private globalSkillsDir: string;
  private projectSkillsDir: string;
  private initialized = false;

  constructor(options: SkillRegistryOptions) {
    this.workingDirectory = options.workingDirectory;
    this.globalSkillsDir = options.globalSkillsDir ?? getGlobalSkillsDir();
    this.projectSkillsDir = getProjectSkillsDir(options.workingDirectory);
  }

  /**
   * Initialize the registry by scanning skill directories.
   * Must be called before using other methods.
   */
  async initialize(): Promise<void> {
    if (this.initialized) return;

    logger.debug('Initializing skill registry', {
      globalDir: this.globalSkillsDir,
      projectDir: this.projectSkillsDir,
    });

    const { globalResult, projectResult } = await scanAllSkills(
      this.workingDirectory,
      { globalSkillsDir: this.globalSkillsDir }
    );

    // Process project skills first (they take precedence)
    for (const skill of projectResult.skills) {
      this.skills.set(skill.name, skill);
    }

    // Log any project errors
    for (const error of projectResult.errors) {
      logger.warn('Error loading project skill', {
        path: error.path,
        message: error.message,
      });
    }

    // Process global skills (only add if not already present from project)
    for (const skill of globalResult.skills) {
      if (!this.skills.has(skill.name)) {
        this.skills.set(skill.name, skill);
      } else {
        logger.debug('Project skill shadows global', { name: skill.name });
      }
    }

    // Log any global errors
    for (const error of globalResult.errors) {
      logger.warn('Error loading global skill', {
        path: error.path,
        message: error.message,
      });
    }

    this.initialized = true;
    logger.info('Skill registry initialized', {
      totalSkills: this.skills.size,
      globalCount: globalResult.skills.length,
      projectCount: projectResult.skills.length,
    });
  }

  /**
   * Get a skill by name
   */
  get(name: string): SkillMetadata | undefined {
    return this.skills.get(name);
  }

  /**
   * Check if a skill exists
   */
  has(name: string): boolean {
    return this.skills.has(name);
  }

  /**
   * List all skills (or filtered by options)
   */
  list(options?: SkillListOptions): SkillInfo[] {
    const result: SkillInfo[] = [];

    for (const skill of this.skills.values()) {
      if (options?.source && skill.source !== options.source) {
        continue;
      }

      result.push({
        name: skill.name,
        displayName: skill.displayName,
        description: skill.description,
        source: skill.source,
        tags: skill.frontmatter.tags,
      });
    }

    return result.sort((a, b) => a.name.localeCompare(b.name));
  }

  /**
   * Get all skills with full metadata
   */
  listFull(options?: SkillListOptions): SkillMetadata[] {
    const result: SkillMetadata[] = [];

    for (const skill of this.skills.values()) {
      if (options?.source && skill.source !== options.source) {
        continue;
      }

      result.push(skill);
    }

    return result.sort((a, b) => a.name.localeCompare(b.name));
  }

  /**
   * Get skills filtered by source
   */
  getBySource(source: 'global' | 'project'): SkillMetadata[] {
    return this.listFull({ source });
  }

  /**
   * Get the total number of skills
   */
  get size(): number {
    return this.skills.size;
  }

  /**
   * Refresh the registry by rescanning directories.
   * Useful for file system changes.
   */
  async refresh(): Promise<void> {
    this.skills.clear();
    this.initialized = false;
    await this.initialize();
  }

  /**
   * Get multiple skills by name
   */
  getMany(names: string[]): {
    found: SkillMetadata[];
    notFound: string[];
  } {
    const found: SkillMetadata[] = [];
    const notFound: string[] = [];

    for (const name of names) {
      const skill = this.skills.get(name);
      if (skill) {
        found.push(skill);
      } else {
        notFound.push(name);
      }
    }

    return { found, notFound };
  }
}

/**
 * Create and initialize a skill registry
 */
export async function createSkillRegistry(
  options: SkillRegistryOptions
): Promise<SkillRegistry> {
  const registry = new SkillRegistry(options);
  await registry.initialize();
  return registry;
}
