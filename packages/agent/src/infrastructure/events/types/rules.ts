/**
 * @fileoverview Rules Events
 *
 * Events for rules file loading.
 */

import type { BaseEvent } from './base.js';

// =============================================================================
// Rules Events
// =============================================================================

/** Level of a rules file in the hierarchy */
export type RulesLevel = 'global' | 'project' | 'directory';

/** Information about a single rules file */
export interface RulesFileInfo {
  /** Absolute path to the file */
  path: string;
  /** Path relative to working directory (or absolute if outside) */
  relativePath: string;
  /** Level in the hierarchy */
  level: RulesLevel;
  /** Depth from project root (0 = root, -1 = global) */
  depth: number;
  /** File size in bytes */
  sizeBytes: number;
}

/**
 * Payload for rules.loaded event
 * Emitted once per session when rules files are loaded
 */
export interface RulesLoadedPayload {
  /** List of loaded rules files */
  files: RulesFileInfo[];
  /** Total number of rules files loaded */
  totalFiles: number;
  /** Estimated token count for merged rules content */
  mergedTokens: number;
}

/**
 * Rules loaded event - emitted at session start when rules files are detected
 */
export interface RulesLoadedEvent extends BaseEvent {
  type: 'rules.loaded';
  payload: RulesLoadedPayload;
}
