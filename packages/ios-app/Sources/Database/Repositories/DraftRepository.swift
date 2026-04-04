import Foundation
import SQLite3

/// Repository for session draft persistence.
/// Stores unsent input state (text, skills, spells, attachment metadata) per session.
@MainActor
final class DraftRepository {

    private weak var transport: DatabaseTransport?

    init(transport: DatabaseTransport) {
        self.transport = transport
    }

    // MARK: - Save (UPSERT)

    /// Save or update a draft for a session.
    func save(
        sessionId: String,
        text: String,
        skills: [Skill],
        spells: [Skill],
        attachmentMetadata: [DraftAttachmentMetadata]
    ) throws {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        let skillsJson = try JSONEncoder().encode(skills)
        let spellsJson = try JSONEncoder().encode(spells)
        let attachmentJson = try JSONEncoder().encode(attachmentMetadata)
        let updatedAt = ISO8601DateFormatter().string(from: Date())

        let sql = """
            INSERT OR REPLACE INTO session_drafts
            (session_id, text, skills_json, spells_json, attachment_metadata_json, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(transport.db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(transport.errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 2, text, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 3, String(data: skillsJson, encoding: .utf8), -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 4, String(data: spellsJson, encoding: .utf8), -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 5, String(data: attachmentJson, encoding: .utf8), -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 6, updatedAt, -1, SQLITE_TRANSIENT_DESTRUCTOR)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw EventDatabaseError.insertFailed(transport.errorMessage)
        }
    }

    // MARK: - Load

    /// Load a draft for a session. Returns nil if no draft exists or if JSON is corrupt.
    func load(sessionId: String) throws -> (text: String, skills: [Skill], spells: [Skill], attachmentMetadata: [DraftAttachmentMetadata])? {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        let sql = "SELECT text, skills_json, spells_json, attachment_metadata_json FROM session_drafts WHERE session_id = ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(transport.db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(transport.errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT_DESTRUCTOR)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        let text = String(cString: sqlite3_column_text(stmt, 0))
        let skillsJsonStr = String(cString: sqlite3_column_text(stmt, 1))
        let spellsJsonStr = String(cString: sqlite3_column_text(stmt, 2))
        let attachmentJsonStr = String(cString: sqlite3_column_text(stmt, 3))

        let decoder = JSONDecoder()

        do {
            let skills = try decoder.decode([Skill].self, from: Data(skillsJsonStr.utf8))
            let spells = try decoder.decode([Skill].self, from: Data(spellsJsonStr.utf8))
            let attachmentMetadata = try decoder.decode([DraftAttachmentMetadata].self, from: Data(attachmentJsonStr.utf8))
            return (text: text, skills: skills, spells: spells, attachmentMetadata: attachmentMetadata)
        } catch {
            logger.warning("Failed to decode draft JSON for session \(sessionId): \(error.localizedDescription)", category: .database)
            return nil
        }
    }

    // MARK: - Delete

    /// Delete a draft for a session.
    func delete(sessionId: String) throws {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }

        let sql = "DELETE FROM session_drafts WHERE session_id = ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(transport.db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EventDatabaseError.prepareFailed(transport.errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT_DESTRUCTOR)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw EventDatabaseError.deleteFailed(transport.errorMessage)
        }
    }

    /// Delete all drafts.
    func deleteAll() throws {
        guard let transport = transport else {
            throw EventDatabaseError.executeFailed("Database transport not available")
        }
        try transport.execute("DELETE FROM session_drafts")
    }
}
