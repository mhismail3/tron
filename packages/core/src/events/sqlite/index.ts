/**
 * @fileoverview SQLite Backend Module
 *
 * Modular SQLite persistence layer for the event store.
 */

// Database connection
export { DatabaseConnection, DEFAULT_CONFIG } from './database.js';

// Types
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
export { BaseRepository, idUtils, rowUtils } from './repositories/base.js';
