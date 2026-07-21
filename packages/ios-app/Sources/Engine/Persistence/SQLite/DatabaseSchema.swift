import Foundation
import SQLite3

/// Owns the complete current iOS cache schema.
///
/// The cache is disposable server projection state, so this branch accepts one
/// schema only. Table creation is idempotent and no alternate row-shape decoder
/// runs inside the app.
enum DatabaseSchema {

    static func createTables(db: OpaquePointer?) throws {
        try createEventsTable(db: db)
        try createSessionsTable(db: db)
        try createSyncStateTable(db: db)
        try createDraftsTable(db: db)
    }

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
        try execute(db: db, "CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id)")
        try execute(db: db, "CREATE INDEX IF NOT EXISTS idx_events_session_seq ON events(session_id, sequence)")
        try execute(db: db, "CREATE INDEX IF NOT EXISTS idx_events_parent ON events(parent_id)")
        try execute(db: db, "CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp)")
    }

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
                turn_count INTEGER DEFAULT 0,
                message_count INTEGER DEFAULT 0,
                input_tokens INTEGER DEFAULT 0,
                output_tokens INTEGER DEFAULT 0,
                last_turn_input_tokens INTEGER DEFAULT 0,
                cache_read_tokens INTEGER DEFAULT 0,
                cache_creation_tokens INTEGER DEFAULT 0,
                cost REAL DEFAULT 0,
                is_fork INTEGER DEFAULT 0,
                is_processing INTEGER DEFAULT 0,
                server_origin TEXT,
                activity_lines_json TEXT
            )
        """)
        try execute(db: db, "CREATE INDEX IF NOT EXISTS idx_sessions_workspace ON sessions(workspace_id)")
        try execute(db: db, "CREATE INDEX IF NOT EXISTS idx_sessions_activity ON sessions(last_activity_at)")
        try execute(db: db, "CREATE INDEX IF NOT EXISTS idx_sessions_archived ON sessions(archived_at)")
        try execute(db: db, "CREATE INDEX IF NOT EXISTS idx_sessions_origin ON sessions(server_origin)")
    }

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

    private static func createDraftsTable(db: OpaquePointer?) throws {
        try execute(db: db, """
            CREATE TABLE IF NOT EXISTS session_drafts (
                session_id TEXT PRIMARY KEY,
                text TEXT NOT NULL DEFAULT '',
                attachment_metadata_json TEXT NOT NULL DEFAULT '[]',
                updated_at TEXT NOT NULL
            )
        """)
    }

    private static func execute(db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw EventDatabaseError.executeFailed(errorMessage(db: db))
        }
    }

    private static func errorMessage(db: OpaquePointer?) -> String {
        guard let db else { return "Unknown database error" }
        return String(cString: sqlite3_errmsg(db))
    }
}
