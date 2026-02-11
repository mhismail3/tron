/**
 * @fileoverview Rules Tracker
 *
 * Manages tracking of rules files loaded for a session's context.
 * Rules are loaded once at session start and are not removable.
 * Supports event-sourced reconstruction for session resume/fork.
 *
 * Extended with dynamic rules activation for scoped CLAUDE.md/AGENTS.md files.
 * Global rules are always injected; scoped rules activate when the agent
 * touches files under the rule's scopeDir (via PostToolUse hook).
 */

import type {
  RulesLoadedPayload,
  RulesFileInfo,
  RulesLevel,
} from '@infrastructure/events/types.js';
import type { RulesIndex } from './rules-index.js';
import type { DiscoveredRulesFile } from './rules-discovery.js';

/**
 * Information about a tracked rules file
 */
export interface TrackedRulesFile {
  /** Absolute path to the file */
  path: string;
  /** Path relative to working directory */
  relativePath: string;
  /** Level in the hierarchy (global, project, directory) */
  level: RulesLevel;
  /** Depth from project root (-1 for global, 0 for project root) */
  depth: number;
  /** File size in bytes */
  sizeBytes: number;
}

/**
 * Generic event structure for reconstruction
 */
export interface RulesTrackingEvent {
  id: string;
  type: string;
  payload: Record<string, unknown>;
}

/**
 * RulesTracker manages tracking of rules files loaded for a session.
 *
 * Key features:
 * - Tracks which rules files were loaded at session start
 * - Supports event-sourced reconstruction from event history
 * - Rules are immutable for the session (no remove operation)
 * - Provides file list for context snapshot responses
 * - Dynamic path-scoped rules activation via RulesIndex
 */
export class RulesTracker {
  private files: TrackedRulesFile[] = [];
  private _mergedTokens: number = 0;
  private _loadedEventId: string | null = null;
  /** Cached merged content (optional - may not always be stored) */
  private _mergedContent: string | null = null;

  // Dynamic rules state
  private _rulesIndex: RulesIndex | null = null;
  private _touchedPaths: Set<string> = new Set();
  private _activatedScopedRules: Map<string, DiscoveredRulesFile> = new Map();
  private _dynamicContent: string | null = null;
  private _dynamicContentDirty: boolean = true;

  /**
   * Record that rules files have been loaded.
   * Called once per session from rules.loaded event.
   */
  setRules(
    files: RulesFileInfo[],
    mergedTokens: number,
    eventId: string,
    mergedContent?: string
  ): void {
    this.files = files.map(f => ({
      path: f.path,
      relativePath: f.relativePath,
      level: f.level,
      depth: f.depth,
      sizeBytes: f.sizeBytes,
    }));
    this._mergedTokens = mergedTokens;
    this._loadedEventId = eventId;
    this._mergedContent = mergedContent ?? null;
  }

  /**
   * Get all loaded rules files
   */
  getRulesFiles(): TrackedRulesFile[] {
    return [...this.files];
  }

  /**
   * Get the total number of rules files
   */
  getTotalFiles(): number {
    return this.files.length;
  }

  /**
   * Get estimated token count for merged rules content
   */
  getMergedTokens(): number {
    return this._mergedTokens;
  }

  /**
   * Get the event ID of the rules.loaded event
   */
  getEventId(): string | null {
    return this._loadedEventId;
  }

  /**
   * Get cached merged content (if available)
   */
  getMergedContent(): string | null {
    return this._mergedContent;
  }

  /**
   * Check if any rules are loaded (static or dynamic)
   */
  hasRules(): boolean {
    return this.files.length > 0 || (this._rulesIndex !== null && this._rulesIndex.totalCount > 0);
  }

  /**
   * Get the number of files at each level
   */
  getCountsByLevel(): { global: number; project: number; directory: number } {
    const counts = { global: 0, project: 0, directory: 0 };
    for (const file of this.files) {
      counts[file.level]++;
    }
    return counts;
  }

  // ===========================================================================
  // Dynamic Rules Activation
  // ===========================================================================

  /**
   * Set the rules index for dynamic path-scoped matching.
   * Called after discovery + indexing at session start.
   */
  setRulesIndex(index: RulesIndex): void {
    this._rulesIndex = index;
    this._dynamicContentDirty = true;
  }

  /**
   * Get the rules index (if set)
   */
  getRulesIndex(): RulesIndex | null {
    return this._rulesIndex;
  }

  /**
   * Record that a file path was touched by the agent.
   * Checks scoped rules for activation.
   *
   * @returns true if new scoped rules were activated
   */
  touchPath(relativePath: string): boolean {
    if (!this._rulesIndex) return false;

    this._touchedPaths.add(relativePath);

    const matched = this._rulesIndex.matchPath(relativePath);
    let newActivations = false;

    for (const rule of matched) {
      if (!this._activatedScopedRules.has(rule.relativePath)) {
        this._activatedScopedRules.set(rule.relativePath, rule);
        newActivations = true;
      }
    }

    if (newActivations) {
      this._dynamicContentDirty = true;
    }

    return newActivations;
  }

  /**
   * Build the merged dynamic rules content string.
   * Includes global rules (always) and activated scoped rules.
   * Returns undefined if no index is set or no rules to include.
   *
   * Content is cached until new activations occur.
   */
  buildDynamicRulesContent(): string | undefined {
    if (!this._rulesIndex) return undefined;

    const globalRules = this._rulesIndex.getGlobalRules();
    const activatedRules = Array.from(this._activatedScopedRules.values());

    if (globalRules.length === 0 && activatedRules.length === 0) {
      return undefined;
    }

    if (!this._dynamicContentDirty && this._dynamicContent !== null) {
      return this._dynamicContent;
    }

    const sections: string[] = [];

    // Global rules first, sorted by relativePath for determinism
    const sortedGlobals = [...globalRules].sort((a, b) =>
      a.relativePath.localeCompare(b.relativePath)
    );
    for (const rule of sortedGlobals) {
      sections.push(`<!-- Rule: ${rule.relativePath} -->\n${rule.content.trim()}`);
    }

    // Scoped rules in activation order (Map preserves insertion order)
    for (const rule of activatedRules) {
      sections.push(`<!-- Rule: ${rule.relativePath} (activated) -->\n${rule.content.trim()}`);
    }

    this._dynamicContent = sections.join('\n\n');
    this._dynamicContentDirty = false;

    return this._dynamicContent;
  }

  /**
   * Get all activated scoped rules
   */
  getActivatedRules(): DiscoveredRulesFile[] {
    return Array.from(this._activatedScopedRules.values());
  }

  /**
   * Get global rules from the index (if set)
   */
  getGlobalRulesFromIndex(): DiscoveredRulesFile[] {
    return this._rulesIndex?.getGlobalRules() ?? [];
  }

  /**
   * Get the set of all touched file paths
   */
  getTouchedPaths(): ReadonlySet<string> {
    return this._touchedPaths;
  }

  /**
   * Get count of activated scoped rules
   */
  getActivatedScopedRulesCount(): number {
    return this._activatedScopedRules.size;
  }

  /**
   * Clear dynamic activation state (for compaction boundary)
   */
  clearDynamicState(): void {
    this._touchedPaths.clear();
    this._activatedScopedRules.clear();
    this._dynamicContent = null;
    this._dynamicContentDirty = true;
  }

  // ===========================================================================
  // Event Sourcing
  // ===========================================================================

  /**
   * Reconstruct rules state from event history.
   *
   * Since rules are loaded once per session and are not removable,
   * we just look for the rules.loaded event and extract its payload.
   *
   * @param events - Array of events in chronological order
   * @returns New RulesTracker with reconstructed state
   */
  static fromEvents(events: RulesTrackingEvent[]): RulesTracker {
    const tracker = new RulesTracker();

    for (const event of events) {
      if (event.type === 'rules.loaded') {
        const payload = event.payload as unknown as RulesLoadedPayload;
        tracker.setRules(
          payload.files,
          payload.mergedTokens,
          event.id
        );
        // Only one rules.loaded event per session, but continue in case
        // the event history includes resumed/forked ancestry
      }
    }

    return tracker;
  }
}

/**
 * Create a new empty RulesTracker
 */
export function createRulesTracker(): RulesTracker {
  return new RulesTracker();
}
