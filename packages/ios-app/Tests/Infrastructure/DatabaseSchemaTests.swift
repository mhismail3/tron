import XCTest
import SQLite3
@testable import TronMobile

/// Tests for DatabaseSchema — verifies the created schema matches the
/// live column set used by repositories. Guards against dead/removed
/// columns being re-added without a schema version bump.
final class DatabaseSchemaTests: XCTestCase {

    private var dbPath: String!

    override func setUp() async throws {
        let tempDir = NSTemporaryDirectory() + "tron-schema-test-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        dbPath = tempDir + "test.db"
    }

    override func tearDown() async throws {
        if let dbPath {
            let dir = (dbPath as NSString).deletingLastPathComponent
            try? FileManager.default.removeItem(atPath: dir)
        }
    }

    // MARK: - D3: is_chat column is gone

    /// Fresh install: sessions table must not contain the dead is_chat column.
    /// The column was always written as 0 and never read — removed in schema v11.
    func testSessionsSchemaHasNoIsChatColumn() async throws {
        let actor = DatabaseActor(dbPath: dbPath)
        try await actor.open()

        let columns = try await sessionsColumns(actor: actor)
        XCTAssertFalse(columns.contains("is_chat"),
                       "is_chat column should be absent from fresh sessions table schema, got: \(columns)")
        await actor.close()
    }

    /// Existing install: if an old DB has is_chat (e.g. schema v10 cached DB),
    /// opening it must migrate — the version bump fires the DROP COLUMN
    /// migration, and the re-opened schema must not contain is_chat.
    func testExistingInstallDropsIsChatColumnOnVersionBump() async throws {
        // Simulate a v10 database: create the sessions table with is_chat,
        // set user_version back to 10, then re-open and verify the
        // migration dropped the column.
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            XCTFail("sqlite3_open failed")
            return
        }
        // Minimal sessions table with is_chat, matching pre-v11 shape.
        let createSQL = """
            CREATE TABLE sessions (
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
                cost REAL DEFAULT 0,
                is_fork INTEGER DEFAULT 0,
                server_origin TEXT,
                is_chat INTEGER DEFAULT 0,
                activity_lines_json TEXT,
                source TEXT
            )
        """
        XCTAssertEqual(sqlite3_exec(db, createSQL, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version = 10", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        // Re-open through DatabaseActor — this triggers the migration chain.
        let actor = DatabaseActor(dbPath: dbPath)
        try await actor.open()

        let columns = try await sessionsColumns(actor: actor)
        XCTAssertFalse(columns.contains("is_chat"),
                       "is_chat should be dropped by v11 migration, got columns: \(columns)")
        await actor.close()
    }

    // MARK: - Helpers

    private func sessionsColumns(actor: DatabaseActor) async throws -> Set<String> {
        try await actor.withDB { db in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(sessions)", -1, &stmt, nil) == SQLITE_OK else {
                return []
            }
            var names: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let ptr = sqlite3_column_text(stmt, 1) {
                    names.insert(String(cString: ptr))
                }
            }
            return names
        }
    }
}
