import XCTest
import SQLite3
@testable import TronMobile

/// Tests for SQLiteHelpers — free functions for SQLite binding and error messages.
final class SQLiteHelpersTests: XCTestCase {

    private var db: OpaquePointer?
    private var dbPath: String!

    override func setUp() async throws {
        let tempDir = NSTemporaryDirectory() + "tron-test-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        dbPath = tempDir + "helpers-test.db"
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)", nil, nil, nil), SQLITE_OK)
    }

    override func tearDown() async throws {
        if let db { sqlite3_close(db) }
        if let dbPath {
            let dir = (dbPath as NSString).deletingLastPathComponent
            try? FileManager.default.removeItem(atPath: dir)
        }
    }

    // MARK: - Bind Optional Text

    func testBindOptionalTextWithValue() throws {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO t (id, name) VALUES (1, ?)", -1, &stmt, nil), SQLITE_OK)

        sqliteBindOptionalText(stmt, 1, "hello")
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)

        // Verify
        var readStmt: OpaquePointer?
        defer { sqlite3_finalize(readStmt) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT name FROM t WHERE id = 1", -1, &readStmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(readStmt), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(readStmt, 0)), "hello")
    }

    func testBindOptionalTextWithNil() throws {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO t (id, name) VALUES (1, ?)", -1, &stmt, nil), SQLITE_OK)

        sqliteBindOptionalText(stmt, 1, nil)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)

        // Verify NULL
        var readStmt: OpaquePointer?
        defer { sqlite3_finalize(readStmt) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT name FROM t WHERE id = 1", -1, &readStmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(readStmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_type(readStmt, 0), SQLITE_NULL)
    }

    // MARK: - Get Optional Text

    func testGetOptionalTextWithValue() throws {
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO t (id, name) VALUES (1, 'world')", nil, nil, nil), SQLITE_OK)

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT name FROM t WHERE id = 1", -1, &stmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)

        let result = sqliteGetOptionalText(stmt, 0)
        XCTAssertEqual(result, "world")
    }

    func testGetOptionalTextWithNilColumn() throws {
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO t (id, name) VALUES (1, NULL)", nil, nil, nil), SQLITE_OK)

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT name FROM t WHERE id = 1", -1, &stmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)

        let result = sqliteGetOptionalText(stmt, 0)
        XCTAssertNil(result)
    }

    // MARK: - Error Message

    func testErrorMessageReturnsLastError() throws {
        // Execute invalid SQL to generate an error
        sqlite3_exec(db, "SELECT * FROM nonexistent_table", nil, nil, nil)
        let msg = sqliteErrorMessage(db)
        XCTAssertTrue(msg.contains("nonexistent_table") || msg.contains("no such table"),
                      "Error message should reference the bad table, got: \(msg)")
    }

    func testErrorMessageWithNilDB() {
        let msg = sqliteErrorMessage(nil)
        XCTAssertEqual(msg, "Unknown database error")
    }
}
