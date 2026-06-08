import Foundation
import SQLite3

/// Serializes all SQLite access on a background executor.
///
/// Owns the database connection exclusively — no other code touches the OpaquePointer.
/// All repository I/O goes through `withDB`, which runs the provided closure on this
/// actor's serial executor. This guarantees:
/// - No concurrent SQLite access (actor serialization)
/// - No I/O on the main thread (actor runs on cooperative pool)
/// - No pointer escape (OpaquePointer stays inside actor)
actor DatabaseActor {
    private var db: OpaquePointer?
    private let dbPath: String
    private var isClosed = false

    init(dbPath: String) {
        self.dbPath = dbPath
    }

    /// Open the database, enable WAL mode, and create schema tables.
    func open() throws {
        guard db == nil else { return }
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            throw EventDatabaseError.openFailed(msg)
        }
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA busy_timeout = 5000")
        try DatabaseSchema.createTables(db: db)
        isClosed = false
    }

    /// Close the database connection. Subsequent `withDB` calls will throw.
    func close() {
        if let db = db {
            sqlite3_close(db)
            self.db = nil
            isClosed = true
        }
    }

    /// Execute a closure with exclusive access to the SQLite connection.
    ///
    /// All repository I/O goes through this method. The closure runs on this actor's
    /// serial executor, ensuring no concurrent access and no main-thread I/O.
    func withDB<T: Sendable>(_ body: (OpaquePointer?) throws -> T) throws -> T {
        guard !isClosed, db != nil else {
            throw EventDatabaseError.executeFailed("Database is closed")
        }
        return try body(db)
    }

    /// Execute a SQL statement that doesn't return results.
    func exec(_ sql: String) throws {
        guard let db = db else {
            throw EventDatabaseError.executeFailed("Database not open")
        }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw EventDatabaseError.executeFailed(String(cString: sqlite3_errmsg(db)))
        }
    }
}
