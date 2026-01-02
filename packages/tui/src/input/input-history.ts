/**
 * @fileoverview Input History Manager
 *
 * Manages prompt history with up/down navigation.
 * Pure TypeScript class (no React dependency) for testability.
 */

export interface InputHistoryOptions {
  /** Maximum number of history entries to keep */
  maxEntries?: number;
}

const DEFAULT_MAX_ENTRIES = 100;

/**
 * Input history manager for prompt navigation.
 */
export class InputHistory {
  private entries: string[] = [];
  private index = -1; // -1 means not navigating (at end)
  private temporary = ''; // Stores in-progress input during navigation
  private readonly maxEntries: number;

  constructor(options: InputHistoryOptions = {}) {
    this.maxEntries = options.maxEntries ?? DEFAULT_MAX_ENTRIES;
  }

  /**
   * Add an entry to history.
   * - Trims whitespace
   * - Ignores empty entries
   * - Ignores consecutive duplicates
   * - Resets navigation index
   * - Clears temporary input
   */
  add(entry: string): void {
    const trimmed = entry.trim();

    // Ignore empty entries
    if (!trimmed) {
      return;
    }

    // Ignore consecutive duplicates
    if (this.entries.length > 0 && this.entries[this.entries.length - 1] === trimmed) {
      return;
    }

    this.entries.push(trimmed);

    // Enforce max entries limit
    if (this.entries.length > this.maxEntries) {
      this.entries = this.entries.slice(-this.maxEntries);
    }

    // Reset navigation state
    this.index = -1;
    this.temporary = '';
  }

  /**
   * Navigate up (older) in history.
   * Returns the entry or null if at/past beginning.
   */
  navigateUp(): string | null {
    if (this.entries.length === 0) {
      return null;
    }

    if (this.index === -1) {
      // Start navigating from most recent
      this.index = this.entries.length - 1;
    } else if (this.index > 0) {
      // Move to older entry
      this.index--;
    }
    // If already at 0, stay there

    return this.getCurrent();
  }

  /**
   * Navigate down (newer) in history.
   * Returns the entry or null if past end.
   */
  navigateDown(): string | null {
    if (this.entries.length === 0 || this.index === -1) {
      return null;
    }

    if (this.index < this.entries.length - 1) {
      // Move to newer entry
      this.index++;
      return this.getCurrent();
    } else {
      // Past end - return to temporary input
      this.index = -1;
      return null;
    }
  }

  /**
   * Get current entry at index, or null if not navigating.
   */
  getCurrent(): string | null {
    if (this.index === -1 || this.index >= this.entries.length) {
      return null;
    }
    return this.entries[this.index] ?? null;
  }

  /**
   * Get the full history array.
   */
  getHistory(): string[] {
    return [...this.entries];
  }

  /**
   * Get current navigation index.
   */
  getIndex(): number {
    return this.index;
  }

  /**
   * Save temporary input (in-progress text before navigation).
   */
  setTemporary(value: string): void {
    this.temporary = value;
  }

  /**
   * Get the temporary input.
   */
  getTemporary(): string {
    return this.temporary;
  }

  /**
   * Clear all history.
   */
  clear(): void {
    this.entries = [];
    this.index = -1;
    this.temporary = '';
  }

  /**
   * Reset navigation without clearing history.
   */
  resetNavigation(): void {
    this.index = -1;
  }
}
