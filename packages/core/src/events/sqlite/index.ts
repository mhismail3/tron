/**
 * @fileoverview SQLite Backend Module
 *
 * Modular SQLite persistence layer for the event store.
 */

// Facade (main entry point)
export {
  SQLiteEventStore,
  createSQLiteEventStore,
  type SQLiteBackendConfig,
  type CreateWorkspaceOptions,
  type SearchOptions,
} from './facade.js';

// Database connection
export { DatabaseConnection, DEFAULT_CONFIG } from './database.js';

// Internal Types (for advanced use cases)
export type {
  DatabaseConfig,
  DatabaseState,
  SessionDbRow,
  EventDbRow,
  WorkspaceDbRow,
  BranchDbRow,
  BlobDbRow,
  ColumnInfo,
} from './types.js';

// Repositories
export {
  BaseRepository,
  idUtils,
  rowUtils,
  BlobRepository,
  WorkspaceRepository,
  BranchRepository,
  EventRepository,
  SessionRepository,
  SearchRepository,
} from './repositories/index.js';

// Repository Types
export type {
  EventWithDepth,
  ListEventsOptions,
  SessionRow,
  CreateSessionOptions,
  ListSessionsOptions,
  IncrementCountersOptions,
  MessagePreview,
  BranchRow,
  CreateBranchOptions,
  SearchOptions as RepoSearchOptions,
} from './repositories/index.js';

// Migrations
export {
  migrations,
  runMigrations,
  runIncrementalMigrations,
  MigrationRunner,
  createMigrationRunner,
} from './migrations/index.js';
export type { Migration, MigrationResult, SchemaVersionRow } from './migrations/types.js';
