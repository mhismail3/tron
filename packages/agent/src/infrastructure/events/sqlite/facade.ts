/**
 * @fileoverview SQLite Event Store Facade
 *
 * Provides a unified interface to the modular SQLite repositories.
 * This is the main entry point for SQLite-based event storage.
 *
 * MIGRATION NOTE: This facade maintains the same interface as the legacy
 * sqlite-backend.ts for backward compatibility. New code should use the
 * individual repositories directly when possible.
 */

import { createRequire } from 'module';
import type { Database } from 'bun:sqlite';
import { DatabaseConnection, getDefaultConfig } from './database.js';
import { runMigrations, runIncrementalMigrations } from './migrations/index.js';
import {
  BlobRepository,
  WorkspaceRepository,
  BranchRepository,
  EventRepository,
  SessionRepository,
  SearchRepository,
  VectorRepository,
  type SessionRow,
  type BranchRow,
  type CreateSessionOptions,
  type ListSessionsOptions,
  type IncrementCountersOptions,
  type CreateBranchOptions,
} from './repositories/index.js';
import { createLogger } from '@infrastructure/logging/index.js';

const logger = createLogger('sqlite-event-store');
import {
  EventId,
  SessionId,
  WorkspaceId,
  BranchId,
  type SessionEvent,
  type EventType,
  type Workspace,
  type SearchResult,
} from '../types.js';

// =============================================================================
// Types (re-exported for backward compatibility)
// =============================================================================

export interface SQLiteBackendConfig {
  dbPath: string;
  enableWAL?: boolean;
  busyTimeout?: number;
}

export interface CreateWorkspaceOptions {
  path: string;
  name?: string;
}

export interface SearchOptions {
  workspaceId?: WorkspaceId;
  sessionId?: SessionId;
  types?: EventType[];
  limit?: number;
  offset?: number;
}

// Re-export types from repositories
export type {
  SessionRow,
  BranchRow,
  CreateSessionOptions,
  ListSessionsOptions,
  IncrementCountersOptions,
  CreateBranchOptions,
};

// =============================================================================
// Facade Implementation
// =============================================================================

/**
 * SQLite Event Store - Unified facade for all repositories
 *
 * Provides the same interface as the legacy SQLiteBackend while
 * delegating to modular repositories internally.
 */
export class SQLiteEventStore {
  private connection: DatabaseConnection;
  private initialized = false;

  // Repositories
  private blobRepo!: BlobRepository;
  private workspaceRepo!: WorkspaceRepository;
  private branchRepo!: BranchRepository;
  private eventRepo!: EventRepository;
  private sessionRepo!: SessionRepository;
  private searchRepo!: SearchRepository;
  private vectorRepo: VectorRepository | null = null;
  private sqliteVecLoaded = false;

  constructor(dbPath: string, config?: Partial<SQLiteBackendConfig>) {
    const defaults = getDefaultConfig();
    this.connection = new DatabaseConnection(dbPath, {
      enableWAL: config?.enableWAL ?? defaults.enableWAL,
      busyTimeout: config?.busyTimeout ?? defaults.busyTimeout,
    });
  }

  // ===========================================================================
  // Lifecycle
  // ===========================================================================

  async initialize(): Promise<void> {
    if (this.initialized) return;

    const db = this.connection.open();
    runMigrations(db);
    // Run incremental migrations for existing databases
    // This adds columns that were introduced after v001
    runIncrementalMigrations(db);
    this.connection.markInitialized();

    // Initialize repositories
    this.blobRepo = new BlobRepository(this.connection);
    this.workspaceRepo = new WorkspaceRepository(this.connection);
    this.branchRepo = new BranchRepository(this.connection);
    this.eventRepo = new EventRepository(this.connection);
    this.sessionRepo = new SessionRepository(this.connection);
    this.searchRepo = new SearchRepository(this.connection);

    // Load sqlite-vec extension for vector search
    this.loadSqliteVec(db);

    this.initialized = true;
  }

  async close(): Promise<void> {
    this.connection.close();
    this.initialized = false;
  }

  /**
   * Check if the store is initialized
   */
  isInitialized(): boolean {
    return this.initialized;
  }

  /**
   * Run incremental migrations (for upgrading existing databases)
   */
  runIncrementalMigrations(): void {
    runIncrementalMigrations(this.connection.getDatabase());
  }

  /**
   * Get the underlying database instance
   */
  getDatabase(): Database {
    return this.connection.getDatabase();
  }

  /**
   * Get the underlying database instance
   * @deprecated Use getDatabase() instead
   */
  getDb(): Database {
    return this.connection.getDatabase();
  }

  // ===========================================================================
  // sqlite-vec Extension
  // ===========================================================================

  private loadSqliteVec(db: Database): void {
    try {
      // sqlite-vec provides getLoadablePath() which returns the native extension path.
      // We call db.loadExtension() directly to avoid the load() wrapper's
      // compatibility issues across different SQLite bindings.
      //
      const require = createRequire(import.meta.url);
      const { getLoadablePath } = require('sqlite-vec');
      const extensionPath = getLoadablePath();
      db.loadExtension(extensionPath);
      this.sqliteVecLoaded = true;

      // Create vector repo and ensure table exists
      this.vectorRepo = new VectorRepository(this.connection);
      this.vectorRepo.ensureTable();

      logger.info('sqlite-vec extension loaded');
    } catch (err) {
      logger.debug('sqlite-vec extension not available, semantic search disabled', {
        error: (err as Error).message,
      });
    }
  }

  /**
   * Get the VectorRepository (null if sqlite-vec not loaded)
   */
  getVectorRepository(): VectorRepository | null {
    return this.vectorRepo;
  }

  /**
   * Check if sqlite-vec is available
   */
  hasVectorSupport(): boolean {
    return this.sqliteVecLoaded;
  }

  // ===========================================================================
  // Workspace Operations
  // ===========================================================================

  async createWorkspace(options: CreateWorkspaceOptions): Promise<Workspace> {
    return this.workspaceRepo.create(options);
  }

  async getWorkspaceByPath(path: string): Promise<Workspace | null> {
    return this.workspaceRepo.getByPath(path);
  }

  async getOrCreateWorkspace(path: string, name?: string): Promise<Workspace> {
    const existing = await this.getWorkspaceByPath(path);
    if (existing) return existing;
    return this.createWorkspace({ path, name });
  }

  async listWorkspaces(): Promise<Workspace[]> {
    return this.workspaceRepo.list();
  }

  // ===========================================================================
  // Session Operations
  // ===========================================================================

  async createSession(options: CreateSessionOptions): Promise<SessionRow> {
    return this.sessionRepo.create(options);
  }

  async getSession(sessionId: SessionId): Promise<SessionRow | null> {
    return this.sessionRepo.getById(sessionId);
  }

  async getSessionsByIds(sessionIds: SessionId[]): Promise<Map<SessionId, SessionRow>> {
    return this.sessionRepo.getByIds(sessionIds);
  }

  async listSessions(options: ListSessionsOptions): Promise<SessionRow[]> {
    return this.sessionRepo.list(options);
  }

  async getSessionMessagePreviews(
    sessionIds: SessionId[]
  ): Promise<Map<SessionId, { lastUserPrompt?: string; lastAssistantResponse?: string }>> {
    return this.sessionRepo.getMessagePreviews(sessionIds);
  }

  async updateSessionHead(sessionId: SessionId, headEventId: EventId): Promise<void> {
    this.sessionRepo.updateHead(sessionId, headEventId);
  }

  async updateSessionRoot(sessionId: SessionId, rootEventId: EventId): Promise<void> {
    this.sessionRepo.updateRoot(sessionId, rootEventId);
  }

  async markSessionEnded(sessionId: SessionId): Promise<void> {
    this.sessionRepo.markEnded(sessionId);
  }

  async clearSessionEnded(sessionId: SessionId): Promise<void> {
    this.sessionRepo.clearEnded(sessionId);
  }

  async updateLatestModel(sessionId: SessionId, model: string): Promise<void> {
    this.sessionRepo.updateLatestModel(sessionId, model);
  }

  async incrementSessionCounters(
    sessionId: SessionId,
    counters: IncrementCountersOptions
  ): Promise<void> {
    this.sessionRepo.incrementCounters(sessionId, counters);
  }

  // ===========================================================================
  // Event Operations
  // ===========================================================================

  async insertEvent(event: SessionEvent): Promise<void> {
    await this.eventRepo.insert(event);
  }

  async getEvent(eventId: EventId): Promise<SessionEvent | null> {
    const event = this.eventRepo.getById(eventId);
    if (!event) return null;
    // Remove depth field to match legacy interface
    const { depth, ...sessionEvent } = event;
    return sessionEvent as SessionEvent;
  }

  async getEvents(eventIds: EventId[]): Promise<Map<EventId, SessionEvent>> {
    const events = this.eventRepo.getByIds(eventIds);
    // Convert to legacy format (without depth)
    const result = new Map<EventId, SessionEvent>();
    events.forEach((event, id) => {
      const { depth, ...sessionEvent } = event;
      result.set(id, sessionEvent as SessionEvent);
    });
    return result;
  }

  async getEventsBySession(
    sessionId: SessionId,
    options?: { limit?: number; offset?: number }
  ): Promise<SessionEvent[]> {
    const events = this.eventRepo.getBySession(sessionId, options);
    return events.map(({ depth, ...event }) => event as SessionEvent);
  }

  async getEventsByType(
    sessionId: SessionId,
    types: EventType[],
    options?: { limit?: number }
  ): Promise<SessionEvent[]> {
    const events = this.eventRepo.getByTypes(sessionId, types, options);
    return events.map(({ depth, ...event }) => event as SessionEvent);
  }

  async getEventsByWorkspaceAndTypes(
    workspaceId: WorkspaceId,
    types: EventType[],
    options?: { limit?: number; offset?: number }
  ): Promise<SessionEvent[]> {
    const events = this.eventRepo.getByWorkspaceAndTypes(workspaceId, types, options);
    return events.map(({ depth, ...event }) => event as SessionEvent);
  }

  async countEventsByWorkspaceAndTypes(
    workspaceId: WorkspaceId,
    types: EventType[]
  ): Promise<number> {
    return this.eventRepo.countByWorkspaceAndTypes(workspaceId, types);
  }

  async getNextSequence(sessionId: SessionId): Promise<number> {
    return this.eventRepo.getNextSequence(sessionId);
  }

  async getAncestors(eventId: EventId): Promise<SessionEvent[]> {
    const events = this.eventRepo.getAncestors(eventId);
    return events.map(({ depth, ...event }) => event as SessionEvent);
  }

  async getChildren(eventId: EventId): Promise<SessionEvent[]> {
    const events = this.eventRepo.getChildren(eventId);
    return events.map(({ depth, ...event }) => event as SessionEvent);
  }

  async countEvents(sessionId: SessionId): Promise<number> {
    return this.eventRepo.countBySession(sessionId);
  }

  // ===========================================================================
  // Blob Operations
  // ===========================================================================

  async storeBlob(content: string | Buffer, mimeType = 'text/plain'): Promise<string> {
    return this.blobRepo.store(content, mimeType);
  }

  async getBlob(blobId: string): Promise<string | null> {
    return this.blobRepo.getContent(blobId);
  }

  async getBlobRefCount(blobId: string): Promise<number> {
    return this.blobRepo.getRefCount(blobId);
  }

  // ===========================================================================
  // FTS5 Search
  // ===========================================================================

  async indexEventForSearch(event: SessionEvent): Promise<void> {
    this.searchRepo.index(event);
  }

  async searchEvents(query: string, options?: SearchOptions): Promise<SearchResult[]> {
    return this.searchRepo.search(query, options);
  }

  // ===========================================================================
  // Branch Operations
  // ===========================================================================

  async createBranch(options: CreateBranchOptions): Promise<BranchRow> {
    return this.branchRepo.create(options);
  }

  async getBranch(branchId: BranchId): Promise<BranchRow | null> {
    return this.branchRepo.getById(branchId);
  }

  async getBranchesBySession(sessionId: SessionId): Promise<BranchRow[]> {
    return this.branchRepo.getBySession(sessionId);
  }

  async updateBranchHead(branchId: BranchId, headEventId: EventId): Promise<void> {
    this.branchRepo.updateHead(branchId, headEventId);
  }

  // ===========================================================================
  // Transaction Support
  // ===========================================================================

  /**
   * Execute an async function within a transaction
   */
  async transactionAsync<T>(fn: () => Promise<T>): Promise<T> {
    return this.connection.transactionAsync(fn);
  }

  // ===========================================================================
  // Schema Inspection
  // ===========================================================================

  /**
   * Get the current schema version
   */
  getSchemaVersion(): number {
    const db = this.connection.getDatabase();
    const row = db.prepare('SELECT MAX(version) as version FROM schema_version').get() as
      | { version: number }
      | undefined;
    return row?.version ?? 0;
  }

  /**
   * List all tables in the database
   */
  listTables(): string[] {
    const db = this.connection.getDatabase();
    const rows = db
      .prepare(
        `SELECT name FROM sqlite_master
         WHERE type='table' OR type='virtual table'
         ORDER BY name`
      )
      .all() as { name: string }[];
    return rows.map((r) => r.name);
  }

  // ===========================================================================
  // Stats
  // ===========================================================================

  async getStats(): Promise<{
    totalEvents: number;
    totalSessions: number;
    totalWorkspaces: number;
    totalBlobs: number;
  }> {
    const db = this.connection.getDatabase();

    const workspaceRow = db.prepare('SELECT COUNT(*) as count FROM workspaces').get() as
      | { count: number }
      | undefined;
    const sessionRow = db.prepare('SELECT COUNT(*) as count FROM sessions').get() as
      | { count: number }
      | undefined;
    const eventCount = this.eventRepo.count();

    const blobStats = db
      .prepare('SELECT COUNT(*) as count FROM blobs')
      .get() as { count: number } | undefined;

    return {
      totalWorkspaces: workspaceRow?.count ?? 0,
      totalSessions: sessionRow?.count ?? 0,
      totalEvents: eventCount,
      totalBlobs: blobStats?.count ?? 0,
    };
  }

  // ===========================================================================
  // Direct Repository Access (for advanced use cases)
  // ===========================================================================

  /**
   * Get direct access to repositories for advanced operations
   */
  getRepositories() {
    this.ensureInitialized();
    return {
      blob: this.blobRepo,
      workspace: this.workspaceRepo,
      branch: this.branchRepo,
      event: this.eventRepo,
      session: this.sessionRepo,
      search: this.searchRepo,
      vector: this.vectorRepo,
    };
  }

  private ensureInitialized(): void {
    if (!this.initialized) {
      throw new Error('SQLiteEventStore not initialized. Call initialize() first.');
    }
  }
}

// =============================================================================
// Factory Function
// =============================================================================

/**
 * Create and initialize a SQLite event store
 */
export async function createSQLiteEventStore(
  dbPath: string,
  config?: Partial<SQLiteBackendConfig>
): Promise<SQLiteEventStore> {
  const store = new SQLiteEventStore(dbPath, config);
  await store.initialize();
  return store;
}

// NOTE: SQLiteBackend alias removed - use SQLiteEventStore directly
