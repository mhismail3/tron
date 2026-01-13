/**
 * @fileoverview Skills Module
 *
 * Exports all skill-related types, classes, and functions.
 */

// Types
export type {
  SkillFrontmatter,
  SkillSource,
  SkillMetadata,
  SkillInfo,
  SkillReference,
  SkillInjectionResult,
  SkillScanResult,
  SkillScanError,
  SkillListOptions,
  SkillRegistryOptions,
} from './types.js';

// Loader
export {
  getGlobalSkillsDir,
  getProjectSkillsDir,
  scanSkillsDirectory,
  scanAllSkills,
} from './skill-loader.js';

// Parser
export { parseSkillMd } from './skill-parser.js';
export type { ParsedSkillMd } from './skill-parser.js';

// Registry
export { SkillRegistry, createSkillRegistry } from './skill-registry.js';

// Injector
export {
  extractSkillReferences,
  removeSkillReferences,
  buildSkillContext,
  processPromptForSkills,
  buildMessageWithSkillContext,
} from './skill-injector.js';
