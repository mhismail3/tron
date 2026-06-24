import XCTest
import SQLite3
@testable import TronMobile

/// Tests for DatabaseActor — verifies actor-based SQLite serialization,
/// off-main-thread execution, and lifecycle management.
final class DatabaseActorTests: XCTestCase {

    private var dbPath: String!

    override func setUp() async throws {
        let tempDir = NSTemporaryDirectory() + "tron-test-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        dbPath = tempDir + "test.db"
    }

    override func tearDown() async throws {
        if let dbPath {
            let dir = (dbPath as NSString).deletingLastPathComponent
            try? FileManager.default.removeItem(atPath: dir)
        }
    }

    // MARK: - Open / Close Lifecycle

    func testOpenCreatesDatabaseFile() async throws {
        let actor = DatabaseActor(dbPath: dbPath)
        try await actor.open()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath))
        await actor.close()
    }

    func testOpenEnablesWALMode() async throws {
        let actor = DatabaseActor(dbPath: dbPath)
        try await actor.open()

        let mode: String = try await actor.withDB { db in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "PRAGMA journal_mode", -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW,
                  let ptr = sqlite3_column_text(stmt, 0)
            else { return "unknown" }
            return String(cString: ptr)
        }
        XCTAssertEqual(mode, "wal")
        await actor.close()
    }

    func testOpenSetsBusyTimeout() async throws {
        let actor = DatabaseActor(dbPath: dbPath)
        try await actor.open()

        let timeout: Int = try await actor.withDB { db in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "PRAGMA busy_timeout", -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW
            else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
        XCTAssertEqual(timeout, 5000)
        await actor.close()
    }

    func testDoubleOpenIsIdempotent() async throws {
        let actor = DatabaseActor(dbPath: dbPath)
        try await actor.open()
        try await actor.open() // should not throw
        await actor.close()
    }

    func testClosePreventsFurtherOperations() async throws {
        let actor = DatabaseActor(dbPath: dbPath)
        try await actor.open()
        await actor.close()

        do {
            _ = try await actor.withDB { _ in 42 }
            XCTFail("Expected error after close")
        } catch {
            XCTAssertTrue(error is EventDatabaseError)
        }
    }

    // MARK: - withDB

    func testWithDBExecutesClosure() async throws {
        let actor = DatabaseActor(dbPath: dbPath)
        try await actor.open()

        // Create a test table, insert, and read back
        try await actor.exec("CREATE TABLE test_kv (key TEXT PRIMARY KEY, val TEXT)")
        try await actor.withDB { db in
            guard sqlite3_exec(db, "INSERT INTO test_kv (key, val) VALUES ('a', 'hello')", nil, nil, nil) == SQLITE_OK else {
                throw EventDatabaseError.executeFailed("insert failed")
            }
        }

        let result: String = try await actor.withDB { db in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT val FROM test_kv WHERE key = 'a'", -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW,
                  let ptr = sqlite3_column_text(stmt, 0)
            else { return "" }
            return String(cString: ptr)
        }
        XCTAssertEqual(result, "hello")
        await actor.close()
    }

    func testWithDBReturnsClosureResult() async throws {
        let actor = DatabaseActor(dbPath: dbPath)
        try await actor.open()

        let value = try await actor.withDB { _ in 42 }
        XCTAssertEqual(value, 42)
        await actor.close()
    }

    func testWithDBPropagatesErrors() async throws {
        let actor = DatabaseActor(dbPath: dbPath)
        try await actor.open()

        struct TestError: Error {}

        do {
            _ = try await actor.withDB { _ -> Int in throw TestError() }
            XCTFail("Expected error to propagate")
        } catch {
            XCTAssertTrue(error is TestError)
        }
        await actor.close()
    }

    func testConcurrentWithDBSerializes() async throws {
        let actor = DatabaseActor(dbPath: dbPath)
        try await actor.open()
        try await actor.exec("CREATE TABLE counter (id INTEGER PRIMARY KEY, n INTEGER)")
        try await actor.exec("INSERT INTO counter (id, n) VALUES (1, 0)")

        // Launch 100 concurrent increments
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    try? await actor.withDB { db in
                        guard sqlite3_exec(db, "UPDATE counter SET n = n + 1 WHERE id = 1", nil, nil, nil) == SQLITE_OK else {
                            throw EventDatabaseError.executeFailed("increment failed")
                        }
                    }
                }
            }
        }

        let count: Int = try await actor.withDB { db in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT n FROM counter WHERE id = 1", -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW
            else { return -1 }
            return Int(sqlite3_column_int(stmt, 0))
        }
        XCTAssertEqual(count, 100)
        await actor.close()
    }

    func testWithDBRunsOffMainThread() async throws {
        let actor = DatabaseActor(dbPath: dbPath)
        try await actor.open()

        let isMain: Bool = try await actor.withDB { _ in
            Thread.isMainThread
        }
        XCTAssertFalse(isMain, "Database operations should not run on the main thread")
        await actor.close()
    }
}
