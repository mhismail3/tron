import SQLite3
import XCTest

@testable import TronMobile

/// Pins the disposable iOS cache to its one current schema.
final class DatabaseSchemaTests: XCTestCase {

    private var dbPath: String!

    override func setUp() async throws {
        let tempDir = NSTemporaryDirectory() + "tron-schema-test-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        dbPath = tempDir + "test.db"
    }

    override func tearDown() async throws {
        if let dbPath {
            try? FileManager.default.removeItem(
                atPath: (dbPath as NSString).deletingLastPathComponent
            )
        }
    }

    func testFreshSchemaMatchesRepositoryColumnsExactly() async throws {
        let actor = DatabaseActor(dbPath: dbPath)
        try await actor.open()

        let columns = try await tableColumns("sessions", actor: actor)
        XCTAssertEqual(columns, [
            "id", "workspace_id", "root_event_id", "head_event_id", "title",
            "latest_model", "working_directory", "created_at", "last_activity_at",
            "archived_at", "event_count", "turn_count", "message_count", "input_tokens",
            "output_tokens", "last_turn_input_tokens", "cache_read_tokens",
            "cache_creation_tokens", "cost", "is_fork", "is_processing", "server_origin",
            "activity_lines_json",
            "labels_json", "organization_group", "context_summary_json",
        ])
        await actor.close()
    }

    func testSchemaCreationIsIdempotent() async throws {
        let actor = DatabaseActor(dbPath: dbPath)
        try await actor.open()
        try await actor.withDB { db in
            try DatabaseSchema.createTables(db: db)
        }

        let columns = try await tableColumns("session_drafts", actor: actor)
        XCTAssertEqual(columns, ["session_id", "text", "attachment_metadata_json", "updated_at"])
        await actor.close()
    }

    func testExistingSessionCacheAddsCurrentProjectionColumns() async throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                db,
                """
                CREATE TABLE sessions(
                    id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL,
                    root_event_id TEXT, head_event_id TEXT, title TEXT,
                    latest_model TEXT NOT NULL, working_directory TEXT NOT NULL,
                    created_at TEXT NOT NULL, last_activity_at TEXT NOT NULL,
                    archived_at TEXT, event_count INTEGER, turn_count INTEGER,
                    message_count INTEGER, input_tokens INTEGER, output_tokens INTEGER,
                    last_turn_input_tokens INTEGER, cache_read_tokens INTEGER,
                    cache_creation_tokens INTEGER, cost REAL, is_fork INTEGER,
                    is_processing INTEGER, server_origin TEXT, activity_lines_json TEXT
                )
                """,
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close(db)

        let actor = DatabaseActor(dbPath: dbPath)
        try await actor.open()
        let columns = try await tableColumns("sessions", actor: actor)
        XCTAssertTrue(columns.contains("labels_json"))
        XCTAssertTrue(columns.contains("organization_group"))
        XCTAssertTrue(columns.contains("context_summary_json"))
        await actor.close()
    }

    private func tableColumns(_ table: String, actor: DatabaseActor) async throws -> [String] {
        try await actor.withDB { db in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
            }
            var names: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                names.append(String(cString: sqlite3_column_text(stmt, 1)))
            }
            return names
        }
    }
}
