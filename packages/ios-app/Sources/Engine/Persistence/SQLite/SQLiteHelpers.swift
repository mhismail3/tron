import Foundation
import SQLite3

/// Transient destructor for SQLite bindings — tells SQLite to copy the data immediately.
let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Bind an optional string to a prepared statement parameter.
/// Binds NULL if value is nil.
func sqliteBindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
    if let value {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT_DESTRUCTOR)
    } else {
        sqlite3_bind_null(stmt, index)
    }
}

/// Get an optional string from a result column.
/// Returns nil if the column contains NULL.
func sqliteGetOptionalText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
    guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
    return String(cString: ptr)
}

/// Get the last SQLite error message for a database connection.
func sqliteErrorMessage(_ db: OpaquePointer?) -> String {
    db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown database error"
}
