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
  // Skill tracking types
  SkillAddMethod,
  SkillRemoveReason,
  SkillAddedPayload,
  SkillRemovedPayload,
  AddedSkillInfo,
  // Subagent mode types
  SkillSubagentMode,
  SkillDeniedPatternRule,
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

// Tracker
export { SkillTracker, createSkillTracker } from './skill-tracker.js';
export type { SkillTrackingEvent } from './skill-tracker.js';

// Skill to Denials Converter
export {
  skillFrontmatterToDenials,
  getSkillSubagentMode,
} from './skill-to-denials.js';
