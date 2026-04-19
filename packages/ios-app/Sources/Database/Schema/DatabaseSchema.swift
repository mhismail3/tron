import Foundation
import SQLite3

/// Manages database schema creation and migrations.
/// Extracted from EventDatabase for single responsibility.
enum DatabaseSchema {

    /// Current schema version. Stored as `PRAGMA user_version` after a
    /// successful migration so subsequent app launches can short-circuit
    /// the create-table / column-add IF-NOT-EXISTS dance.
    static let version: Int32 = 10

    // MARK: - Public API

    /// Create all tables and run migrations. Skips work if `PRAGMA
    /// user_version` is already at the current `version`. Brand-new
    /// databases (PRAGMA = 0) and older databases both run the full
    /// idempotent CREATE/ALTER chain once, then bump the PRAGMA.
    /// - Parameter db: SQLite database pointer
    static func createTables(db: OpaquePointer?) throws {
        let current = try readUserVersion(db: db)
        guard current < version else { return }

        try createEventsTable(db: db)
        try createSessionsTable(db: db)
        try runSessionsMigrations(db: db)
        try createSyncStateTable(db: db)
        try createDraftsTable(db: db)
        try runDraftsMigrations(db: db)

        try setUserVersion(db: db, version)
    }

    /// Check if a column exists in a table.
    /// - Parameters:
    ///   - table: Table name
    ///   - column: Column name
    ///   - db: SQLite database pointer
    /// - Returns: true if column exists
    static func columnExists(table: String, column: String, db: OpaquePointer?) throws -> Bool {
        let sql = "PRAGMA table_info(\(table))"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(errorMessage(db: db))
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let colName = String(cString: sqlite3_column_text(stmt, 1))
            if colName == column {
                return true
            }
        }
        return false
    }

    // MARK: - Events Table

    private static func createEventsTable(db: OpaquePointer?) throws {
        try execute(db: db, """
            CREATE TABLE IF NOT EXISTS events (
                id TEXT PRIMARY KEY,
                parent_id TEXT,
                session_id TEXT NOT NULL,
                workspace_id TEXT NOT NULL,
                type TEXT NOT NULL,
                timestamp TEXT NOT NULL,
                sequence INTEGER NOT NULL,
                payload TEXT NOT NULL
            )
        """)

        // Indexes for common queries
        try execute(db: db, "CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id)")
        // Covering index for getBySession ORDER BY sequence — eliminates temp B-tree sort
        try execute(db: db, "CREATE INDEX IF NOT EXISTS idx_events_session_seq ON events(session_id, sequence)")
        try execute(db: db, "CREATE INDEX IF NOT EXISTS idx_events_parent ON events(parent_id)")
        try execute(db: db, "CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp)")
    }

    // MARK: - Sessions Table

    private static func createSessionsTable(db: OpaquePointer?) throws {
        try execute(db: db, """
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL,
                root_event_id TEXT,
                head_event_id TEXT,
                title TEXT,
                latest_model TEXT NOT NULL,
                working_directory TEXT NOT NULL,
                created_at TEXT NOT NULL,
                last_activity_at TEXT NOT NULL,
                archived_at TEXT,
                event_count INTEGER DEFAULT 0,
                message_count INTEGER DEFAULT 0,
                input_tokens INTEGER DEFAULT 0,
                output_tokens INTEGER DEFAULT 0,
                last_turn_input_tokens INTEGER DEFAULT 0,
                cache_read_tokens INTEGER DEFAULT 0,
                cache_creation_tokens INTEGER DEFAULT 0,
                cost REAL DEFAULT 0
            )
        """)

        // Indexes for common queries
        try execute(db: db, "CREATE INDEX IF NOT EXISTS idx_sessions_workspace ON sessions(workspace_id)")
        try execute(db: db, "CREATE INDEX IF NOT EXISTS idx_sessions_activity ON sessions(last_activity_at)")
        // Note: idx_sessions_archived created in runSessionsMigrations after ended_at → archived_at rename
    }

    private static func runSessionsMigrations(db: OpaquePointer?) throws {
        // Migration: Add cost column
        try addColumnIfNotExists(db: db, table: "sessions", column: "cost", definition: "REAL DEFAULT 0")

        // Migration: Add is_fork column
        try addColumnIfNotExists(db: db, table: "sessions", column: "is_fork", definition: "INTEGER DEFAULT 0")

        // Migration: Add last_turn_input_tokens for context size tracking
        try addColumnIfNotExists(db: db, table: "sessions", column: "last_turn_input_tokens", definition: "INTEGER DEFAULT 0")

        // Migration: Add cache token columns for prompt caching
        try addColumnIfNotExists(db: db, table: "sessions", column: "cache_read_tokens", definition: "INTEGER DEFAULT 0")
        try addColumnIfNotExists(db: db, table: "sessions", column: "cache_creation_tokens", definition: "INTEGER DEFAULT 0")

        // Migration: Add server_origin for environment filtering
        try addColumnIfNotExists(db: db, table: "sessions", column: "server_origin", definition: "TEXT")
        try execute(db: db, "CREATE INDEX IF NOT EXISTS idx_sessions_origin ON sessions(server_origin)")

        // Migration: Add is_chat column for persistent chat session
        try addColumnIfNotExists(db: db, table: "sessions", column: "is_chat", definition: "INTEGER DEFAULT 0")

        // Migration: Remove provider, status columns; rename model to latest_model
        // Only needed for very old databases with the provider column
        if try columnExists(table: "sessions", column: "provider", db: db) {
            try migrateSessionsTableSchema(db: db)
        }

        // Migration: Rename ended_at to archived_at (sessions no longer "end")
        if try columnExists(table: "sessions", column: "ended_at", db: db) {
            try execute(db: db, "ALTER TABLE sessions RENAME COLUMN ended_at TO archived_at")
            try execute(db: db, "DROP INDEX IF EXISTS idx_sessions_ended")
        }

        // Create archived_at index (safe after migration has run)
        try execute(db: db, "CREATE INDEX IF NOT EXISTS idx_sessions_archived ON sessions(archived_at)")

        // Migration: Add activity_lines_json for server-computed dashboard activity lines
        try addColumnIfNotExists(db: db, table: "sessions", column: "activity_lines_json", definition: "TEXT")

        // Migration: Add source column for session type (e.g. "chat", "cron")
        try addColumnIfNotExists(db: db, table: "sessions", column: "source", definition: "TEXT")
    }

    /// Migrate old sessions table schema by rebuilding the table.
    /// Removes provider/status columns and renames model to latest_model.
    private static func migrateSessionsTableSchema(db: OpaquePointer?) throws {
        try execute(db: db, """
            CREATE TABLE sessions_new (
                id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL,
                root_event_id TEXT,
                head_event_id TEXT,
                title TEXT,
                latest_model TEXT NOT NULL,
                working_directory TEXT NOT NULL,
                created_at TEXT NOT NULL,
                last_activity_at TEXT NOT NULL,
                archived_at TEXT,
                event_count INTEGER DEFAULT 0,
                message_count INTEGER DEFAULT 0,
                input_tokens INTEGER DEFAULT 0,
                output_tokens INTEGER DEFAULT 0,
                last_turn_input_tokens INTEGER DEFAULT 0,
                cost REAL DEFAULT 0
            )
        """)

        try execute(db: db, """
            INSERT INTO sessions_new
            SELECT id, workspace_id, root_event_id, head_event_id, title,
                   model, working_directory, created_at, last_activity_at,
                   NULL,
                   event_count, message_count, input_tokens, output_tokens, 0, cost
            FROM sessions
        """)

        try execute(db: db, "DROP TABLE sessions")
        try execute(db: db, "ALTER TABLE sessions_new RENAME TO sessions")
    }

    // MARK: - Sync State Table

    private static func createSyncStateTable(db: OpaquePointer?) throws {
        try execute(db: db, """
            CREATE TABLE IF NOT EXISTS sync_state (
                key TEXT PRIMARY KEY,
                last_synced_event_id TEXT,
                last_sync_timestamp TEXT,
                pending_event_ids TEXT
            )
        """)
    }

    // MARK: - Drafts Table

    private static func createDraftsTable(db: OpaquePointer?) throws {
        try execute(db: db, """
            CREATE TABLE IF NOT EXISTS session_drafts (
                session_id TEXT PRIMARY KEY,
                text TEXT NOT NULL DEFAULT '',
                skills_json TEXT NOT NULL DEFAULT '[]',
                attachment_metadata_json TEXT NOT NULL DEFAULT '[]',
                updated_at TEXT NOT NULL
            )
        """)
    }

    private static func runDraftsMigrations(db: OpaquePointer?) throws {
        // Migration: Remove spells_json (spells feature removed in schema v10)
        if try columnExists(table: "session_drafts", column: "spells_json", db: db) {
            try execute(db: db, "ALTER TABLE session_drafts DROP COLUMN spells_json")
        }
    }

    // MARK: - Helpers

    /// Add a column to a table if it doesn't already exist.
    private static func addColumnIfNotExists(
        db: OpaquePointer?,
        table: String,
        column: String,
        definition: String
    ) throws {
        do {
            try execute(db: db, "ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
        } catch {
            // Column already exists, ignore the error
        }
    }

    private static func execute(db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw EventDatabaseError.executeFailed(errorMessage(db: db))
        }
    }

    /// Read SQLite's per-database `PRAGMA user_version`. Defaults to `0`
    /// for fresh databases (which then run the full migration chain).
    private static func readUserVersion(db: OpaquePointer?) throws -> Int32 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(errorMessage(db: db))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw EventDatabaseError.executeFailed("PRAGMA user_version returned no row")
        }
        return sqlite3_column_int(stmt, 0)
    }

    /// Write SQLite's per-database `PRAGMA user_version`. Inlined into
    /// the SQL statement because PRAGMA values can't be parameterized.
    /// `version` is a hard-coded `Int32` literal so injection is moot.
    private static func setUserVersion(db: OpaquePointer?, _ version: Int32) throws {
        try execute(db: db, "PRAGMA user_version = \(version)")
    }

    private static func errorMessage(db: OpaquePointer?) -> String {
        if let db = db {
            return String(cString: sqlite3_errmsg(db))
        }
        return "Unknown database error"
    }
}
