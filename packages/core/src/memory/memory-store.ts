/**
 * @fileoverview Memory Store
 *
 * Simple in-memory store for session context and patterns.
 * Provides a minimal interface for storing and searching entries.
 */
import { createLogger } from '../logging/logger.js';

const logger = createLogger('memory:store');

// =============================================================================
// Types
// =============================================================================

export interface MemoryEntry {
  id: string;
  content: string;
  type: 'pattern' | 'decision' | 'lesson' | 'context' | 'preference';
  source: 'project' | 'global' | 'session';
  tags?: string[];
  metadata?: Record<string, unknown>;
  createdAt: Date;
}

export interface AddEntryOptions {
  content: string;
  type: 'pattern' | 'decision' | 'lesson' | 'context' | 'preference';
  source: 'project' | 'global' | 'session';
  tags?: string[];
  metadata?: Record<string, unknown>;
}

export interface SearchOptions {
  searchText?: string;
  type?: 'pattern' | 'decision' | 'lesson' | 'context' | 'preference';
  source?: 'project' | 'global' | 'session';
  tags?: string[];
  projectPath?: string;
  limit?: number;
}

export interface SearchResult {
  entries: MemoryEntry[];
  totalCount: number;
}

export interface MemoryStoreConfig {
  dbPath?: string;
  maxEntries?: number;
}

// =============================================================================
// SQLiteMemoryStore (In-Memory Implementation)
// =============================================================================

/**
 * Simple in-memory implementation of a memory store.
 * Can be enhanced with SQLite persistence if needed.
 */
export class SQLiteMemoryStore {
  private entries: Map<string, MemoryEntry> = new Map();
  private config: MemoryStoreConfig;

  constructor(config: MemoryStoreConfig = {}) {
    this.config = {
      maxEntries: 1000,
      ...config,
    };
    logger.debug('Memory store initialized', { config: this.config });
  }

  /**
   * Add a new entry to the store
   */
  async addEntry(options: AddEntryOptions): Promise<MemoryEntry> {
    const id = `mem_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;

    const entry: MemoryEntry = {
      id,
      content: options.content,
      type: options.type,
      source: options.source,
      tags: options.tags,
      metadata: options.metadata,
      createdAt: new Date(),
    };

    // Enforce max entries limit
    if (this.entries.size >= (this.config.maxEntries ?? 1000)) {
      // Remove oldest entry
      const oldest = Array.from(this.entries.values())
        .sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime())[0];
      if (oldest) {
        this.entries.delete(oldest.id);
      }
    }

    this.entries.set(id, entry);
    logger.debug('Entry added', { id, type: options.type });

    return entry;
  }

  /**
   * Search entries with optional filters
   */
  async searchEntries(options: SearchOptions = {}): Promise<SearchResult> {
    let results = Array.from(this.entries.values());

    // Filter by type
    if (options.type) {
      results = results.filter(e => e.type === options.type);
    }

    // Filter by source
    if (options.source) {
      results = results.filter(e => e.source === options.source);
    }

    // Filter by project path in metadata
    if (options.projectPath) {
      results = results.filter(e =>
        e.metadata?.workingDirectory === options.projectPath
      );
    }

    // Filter by tags
    if (options.tags && options.tags.length > 0) {
      results = results.filter(e =>
        options.tags!.some(tag => e.tags?.includes(tag))
      );
    }

    // Filter by search text (simple substring match)
    if (options.searchText) {
      const searchLower = options.searchText.toLowerCase();
      results = results.filter(e =>
        e.content.toLowerCase().includes(searchLower)
      );
    }

    // Sort by creation date (newest first)
    results.sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime());

    const totalCount = results.length;

    // Apply limit
    if (options.limit) {
      results = results.slice(0, options.limit);
    }

    return {
      entries: results,
      totalCount,
    };
  }

  /**
   * Get an entry by ID
   */
  async getEntry(id: string): Promise<MemoryEntry | null> {
    return this.entries.get(id) ?? null;
  }

  /**
   * Delete an entry
   */
  async deleteEntry(id: string): Promise<boolean> {
    return this.entries.delete(id);
  }

  /**
   * Clear all entries
   */
  async clear(): Promise<void> {
    this.entries.clear();
    logger.debug('Memory store cleared');
  }

  /**
   * Close the store (no-op for in-memory, but required for interface)
   */
  async close(): Promise<void> {
    logger.debug('Memory store closed');
  }

  /**
   * Get entry count
   */
  get size(): number {
    return this.entries.size;
  }
}

// =============================================================================
// Factory
// =============================================================================

export function createMemoryStore(config: MemoryStoreConfig = {}): SQLiteMemoryStore {
  return new SQLiteMemoryStore(config);
}
