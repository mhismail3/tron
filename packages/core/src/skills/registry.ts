/**
 * @fileoverview Skill Registry
 *
 * Central registry for managing loaded skills.
 */
import { createLogger } from '../logging/index.js';
import type { Skill, SkillRegistry as ISkillRegistry } from './types.js';

const logger = createLogger('skills:registry');

// =============================================================================
// Implementation
// =============================================================================

export class SkillRegistryImpl implements ISkillRegistry {
  private skills: Map<string, Skill> = new Map();
  private commandIndex: Map<string, string> = new Map();

  /**
   * Get skill by ID
   */
  get(id: string): Skill | undefined {
    return this.skills.get(id);
  }

  /**
   * Get skill by command
   */
  getByCommand(command: string): Skill | undefined {
    const id = this.commandIndex.get(command);
    return id ? this.skills.get(id) : undefined;
  }

  /**
   * List all skills
   */
  list(): Skill[] {
    return Array.from(this.skills.values());
  }

  /**
   * List skills by category/tag
   */
  listByTag(tag: string): Skill[] {
    return this.list().filter(s => s.tags?.includes(tag));
  }

  /**
   * List built-in skills
   */
  listBuiltIn(): Skill[] {
    return this.list().filter(s => s.builtIn);
  }

  /**
   * List user-defined skills
   */
  listUserDefined(): Skill[] {
    return this.list().filter(s => !s.builtIn);
  }

  /**
   * Register a skill
   */
  register(skill: Skill): void {
    // Check for ID conflict
    if (this.skills.has(skill.id)) {
      const existing = this.skills.get(skill.id)!;
      // User skills override built-in
      if (existing.builtIn && !skill.builtIn) {
        logger.info('User skill overriding built-in', { id: skill.id });
      } else if (!existing.builtIn && skill.builtIn) {
        logger.debug('Built-in skill not overriding user skill', { id: skill.id });
        return;
      }
    }

    this.skills.set(skill.id, skill);

    // Index by command
    if (skill.command) {
      this.commandIndex.set(skill.command, skill.id);
    }

    logger.debug('Skill registered', { id: skill.id, command: skill.command });
  }

  /**
   * Register multiple skills
   */
  registerAll(skills: Skill[]): void {
    for (const skill of skills) {
      this.register(skill);
    }
  }

  /**
   * Unregister a skill
   */
  unregister(id: string): void {
    const skill = this.skills.get(id);
    if (skill) {
      this.skills.delete(id);
      if (skill.command) {
        this.commandIndex.delete(skill.command);
      }
      logger.debug('Skill unregistered', { id });
    }
  }

  /**
   * Clear all skills
   */
  clear(): void {
    this.skills.clear();
    this.commandIndex.clear();
    logger.debug('Registry cleared');
  }

  /**
   * Search skills by query
   */
  search(query: string): Skill[] {
    const lowerQuery = query.toLowerCase();
    return this.list().filter(skill => {
      return (
        skill.name.toLowerCase().includes(lowerQuery) ||
        skill.description.toLowerCase().includes(lowerQuery) ||
        skill.id.toLowerCase().includes(lowerQuery) ||
        skill.command?.toLowerCase().includes(lowerQuery) ||
        skill.tags?.some(t => t.toLowerCase().includes(lowerQuery))
      );
    });
  }

  /**
   * Get all available commands
   */
  getCommands(): string[] {
    return Array.from(this.commandIndex.keys()).sort();
  }

  /**
   * Check if command exists
   */
  hasCommand(command: string): boolean {
    return this.commandIndex.has(command);
  }

  /**
   * Get skill count
   */
  get size(): number {
    return this.skills.size;
  }
}

// =============================================================================
// Factory
// =============================================================================

export function createSkillRegistry(): SkillRegistryImpl {
  return new SkillRegistryImpl();
}

// =============================================================================
// Singleton Instance
// =============================================================================

let defaultRegistry: SkillRegistryImpl | null = null;

export function getDefaultRegistry(): SkillRegistryImpl {
  if (!defaultRegistry) {
    defaultRegistry = createSkillRegistry();
  }
  return defaultRegistry;
}
