import Foundation
import SQLite3

/// Repository for session draft persistence.
/// Stores unsent input state (text, skills, attachment metadata) per session.
final class DraftRepository: @unchecked Sendable {

    private weak var transport: (any DatabaseTransport)?

    init(transport: any DatabaseTransport) {
        self.transport = transport
    }

    // MARK: - Save (UPSERT)

    /// Save or update a draft for a session.
    func save(
        sessionId: String,
        text: String,
        skills: [Skill],
        attachmentMetadata: [DraftAttachmentMetadata]
    ) async throws {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        let skillsJson = try JSONEncoder().encode(skills)
        let attachmentJson = try JSONEncoder().encode(attachmentMetadata)
        let updatedAt = ISO8601DateFormatter().string(from: Date())

        try await transport.withDB { db in
            let sql = """
                INSERT OR REPLACE INTO session_drafts
                (session_id, text, skills_json, attachment_metadata_json, updated_at)
                VALUES (?, ?, ?, ?, ?)
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 2, text, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 3, String(data: skillsJson, encoding: .utf8), -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 4, String(data: attachmentJson, encoding: .utf8), -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 5, updatedAt, -1, SQLITE_TRANSIENT_DESTRUCTOR)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw EventDatabaseError.insertFailed(sqliteErrorMessage(db))
            }
        }
    }

    // MARK: - Load

    /// Load a draft for a session. Returns nil if no draft exists or if JSON is corrupt.
    func load(sessionId: String) async throws -> (text: String, skills: [Skill], attachmentMetadata: [DraftAttachmentMetadata])? {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        return try await transport.withDB { db in
            let sql = "SELECT text, skills_json, attachment_metadata_json FROM session_drafts WHERE session_id = ?"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT_DESTRUCTOR)

            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }

            let text = String(cString: sqlite3_column_text(stmt, 0))
            let skillsJsonStr = String(cString: sqlite3_column_text(stmt, 1))
            let attachmentJsonStr = String(cString: sqlite3_column_text(stmt, 2))

            let decoder = JSONDecoder()

            do {
                let skills = try decoder.decode([Skill].self, from: Data(skillsJsonStr.utf8))
                let attachmentMetadata = try decoder.decode([DraftAttachmentMetadata].self, from: Data(attachmentJsonStr.utf8))
                return (text: text, skills: skills, attachmentMetadata: attachmentMetadata)
            } catch {
                logger.warning("Failed to decode draft JSON for session \(sessionId): \(error.localizedDescription)", category: .database)
                return nil
            }
        }
    }

    // MARK: - Delete

    /// Delete a draft for a session.
    func delete(sessionId: String) async throws {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        try await transport.withDB { db in
            let sql = "DELETE FROM session_drafts WHERE session_id = ?"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT_DESTRUCTOR)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw EventDatabaseError.deleteFailed(sqliteErrorMessage(db))
            }
        }
    }

    /// Delete all drafts.
    func deleteAll() async throws {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        try await transport.withDB { db in
            guard sqlite3_exec(db, "DELETE FROM session_drafts", nil, nil, nil) == SQLITE_OK else {
                throw EventDatabaseError.executeFailed(sqliteErrorMessage(db))
            }
        }
    }
}
