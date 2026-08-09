import Foundation
import SQLite3

/// SQLite owner for unsubmitted `request_user_input` selections.
///
/// Rows are disposable device-local interaction state. The server event log
/// remains authoritative for the request and for answers that were submitted.
final class UserInputDraftRepository: @unchecked Sendable {
    private weak var transport: (any DatabaseTransport)?

    init(transport: any DatabaseTransport) {
        self.transport = transport
    }

    func save(sessionId: String, invocationId: String, draft: UserInputDraft) async throws {
        guard let transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }
        let draftJSON = String(decoding: try JSONEncoder().encode(draft), as: UTF8.self)
        let updatedAt = ISO8601DateFormatter().string(from: Date())
        try await transport.withDB { db in
            let sql = """
                INSERT INTO session_user_input_drafts
                    (session_id, invocation_id, draft_json, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(session_id, invocation_id) DO UPDATE SET
                    draft_json = excluded.draft_json,
                    updated_at = excluded.updated_at
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, sessionId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(statement, 2, invocationId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(statement, 3, draftJSON, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(statement, 4, updatedAt, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw EventDatabaseError.insertFailed(sqliteErrorMessage(db))
            }
        }
    }

    func load(sessionId: String, invocationId: String) async throws -> UserInputDraft? {
        guard let transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }
        return try await transport.withDB { db in
            let sql = """
                SELECT draft_json FROM session_user_input_drafts
                WHERE session_id = ? AND invocation_id = ?
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, sessionId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(statement, 2, invocationId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let bytes = sqlite3_column_text(statement, 0) else {
                return nil
            }
            return try JSONDecoder().decode(UserInputDraft.self, from: Data(String(cString: bytes).utf8))
        }
    }

    func delete(sessionId: String, invocationId: String) async throws {
        try await executeDelete(
            sql: "DELETE FROM session_user_input_drafts WHERE session_id = ? AND invocation_id = ?",
            values: [sessionId, invocationId]
        )
    }

    func deleteSession(_ sessionId: String) async throws {
        try await executeDelete(
            sql: "DELETE FROM session_user_input_drafts WHERE session_id = ?",
            values: [sessionId]
        )
    }

    private func executeDelete(sql: String, values: [String]) async throws {
        guard let transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }
        try await transport.withDB { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
            }
            defer { sqlite3_finalize(statement) }
            for (offset, value) in values.enumerated() {
                sqlite3_bind_text(statement, Int32(offset + 1), value, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw EventDatabaseError.deleteFailed(sqliteErrorMessage(db))
            }
        }
    }
}
