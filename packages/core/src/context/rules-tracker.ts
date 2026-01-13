/**
 * @fileoverview Rules Tracker
 *
 * Manages tracking of rules files loaded for a session's context.
 * Rules are loaded once at session start and are not removable.
 * Supports event-sourced reconstruction for session resume/fork.
 */

import type {
  RulesLoadedPayload,
  RulesFileInfo,
  RulesLevel,
} from '../events/types.js';

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
 */
export class RulesTracker {
  private files: TrackedRulesFile[] = [];
  private _mergedTokens: number = 0;
  private _loadedEventId: string | null = null;
  /** Cached merged content (optional - may not always be stored) */
  private _mergedContent: string | null = null;

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
   * Check if any rules are loaded
   */
  hasRules(): boolean {
    return this.files.length > 0;
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
