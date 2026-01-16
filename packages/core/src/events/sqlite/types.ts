/**
 * @fileoverview Internal SQLite Types
 *
 * Types used internally by the SQLite backend modules.
 * Public types are exported from events/types.ts.
 */

import type Database from 'better-sqlite3';

/**
 * Configuration for SQLite database connection
 */
export interface DatabaseConfig {
  /** Path to SQLite database file, or ':memory:' for in-memory */
  dbPath: string;
  /** Enable WAL mode (default: true) */
  enableWAL?: boolean;
  /** Busy timeout in milliseconds (default: 5000) */
  busyTimeout?: number;
  /** Cache size in kilobytes (default: 64000 = 64MB) */
  cacheSize?: number;
}

/**
 * Database connection state
 */
export interface DatabaseState {
  db: Database.Database | null;
  initialized: boolean;
  config: Required<Omit<DatabaseConfig, 'dbPath'>> & { dbPath: string };
}

/**
 * Raw row from sessions table
 */
export interface SessionDbRow {
  id: string;
  workspace_id: string;
  head_event_id: string | null;
  root_event_id: string | null;
  title: string | null;
  latest_model: string;
  working_directory: string;
  parent_session_id: string | null;
  fork_from_event_id: string | null;
  created_at: string;
  last_activity_at: string;
  ended_at: string | null;
  event_count: number;
  message_count: number;
  turn_count: number;
  total_input_tokens: number;
  total_output_tokens: number;
  last_turn_input_tokens: number;
  total_cost: number;
  total_cache_read_tokens: number;
  total_cache_creation_tokens: number;
  tags: string;
}

/**
 * Raw row from events table
 */
export interface EventDbRow {
  id: string;
  session_id: string;
  parent_id: string | null;
  sequence: number;
  depth: number;
  type: string;
  timestamp: string;
  payload: string;
  content_blob_id: string | null;
  workspace_id: string;
  role: string | null;
  tool_name: string | null;
  tool_call_id: string | null;
  turn: number | null;
  input_tokens: number | null;
  output_tokens: number | null;
  cache_read_tokens: number | null;
  cache_creation_tokens: number | null;
  checksum: string | null;
}

/**
 * Raw row from workspaces table
 */
export interface WorkspaceDbRow {
  id: string;
  path: string;
  name: string | null;
  created_at: string;
  last_activity_at: string;
  session_count?: number;
}

/**
 * Raw row from branches table
 */
export interface BranchDbRow {
  id: string;
  session_id: string;
  name: string;
  description: string | null;
  root_event_id: string;
  head_event_id: string;
  is_default: number;
  created_at: string;
  last_activity_at: string;
}

/**
 * Raw row from blobs table
 */
export interface BlobDbRow {
  id: string;
  hash: string;
  content: Buffer;
  mime_type: string;
  size_original: number;
  size_compressed: number;
  compression: string;
  created_at: string;
  ref_count: number;
}

/**
 * Column info from PRAGMA table_info
 */
export interface ColumnInfo {
  cid: number;
  name: string;
  type: string;
  notnull: number;
  dflt_value: string | null;
  pk: number;
}
