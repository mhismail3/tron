import Foundation
import SQLite3

/// Protocol that domain repositories use to access SQLite database.
/// Provides the database connection and shared SQL helper methods.
@MainActor
protocol DatabaseTransport: AnyObject {
    /// SQLite database pointer
    var db: OpaquePointer? { get }

    /// Path to the database file
    var dbPath: String { get }

    /// Last SQLite error message
    var errorMessage: String { get }

    /// Execute a SQL statement that doesn't return results
    func execute(_ sql: String) throws

    /// Bind an optional string to a prepared statement parameter
    func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?)

    /// Get an optional string from a result column
    func getOptionalText(_ stmt: OpaquePointer?, _ index: Int32) -> String?
}

// MARK: - SQLite Constants (shared across repositories)

/// Transient destructor for SQLite bindings
let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
