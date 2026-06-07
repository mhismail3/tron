import XCTest
import SQLite3
@testable import TronMobile

/// Tests for DraftRepository — SQLite CRUD for session_drafts table
@MainActor
final class DraftRepositoryTests: XCTestCase {

    var database: EventDatabase!

    override func setUp() async throws {
        database = EventDatabase()
        try await database.initialize()
        try await database.clearAll()
    }

    override func tearDown() async throws {
        try? await database.clearAll()
        await database.close()
    }

    // MARK: - Helpers

    private func makeAttachmentMetadata(
        id: UUID = UUID(),
        type: AttachmentType = .image,
        mimeType: String = "image/jpeg",
        fileName: String? = "photo.jpg"
    ) -> DraftAttachmentMetadata {
        DraftAttachmentMetadata(
            id: id,
            type: type,
            mimeType: mimeType,
            fileName: fileName,
            originalSize: 1024,
            wasConverted: false,
            originalMimeType: nil
        )
    }

    // MARK: - Save and Load

    func testSaveAndLoadDraft_textOnly() async throws {
        try await database.drafts.save(
            sessionId: "s1",
            text: "Hello, world!",
            attachmentMetadata: []
        )

        let result = try await database.drafts.load(sessionId: "s1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text, "Hello, world!")
        XCTAssertTrue(result?.attachmentMetadata.isEmpty ?? false)
    }

    func testSaveAndLoadDraft_withAttachmentMetadata() async throws {
        let attachmentId = UUID()
        let metadata = [
            DraftAttachmentMetadata(
                id: attachmentId,
                type: .image,
                mimeType: "image/jpeg",
                fileName: "photo.jpg",
                originalSize: 5000,
                wasConverted: true,
                originalMimeType: "image/gif"
            ),
        ]

        try await database.drafts.save(
            sessionId: "s1",
            text: "",
            attachmentMetadata: metadata
        )

        let result = try await database.drafts.load(sessionId: "s1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.attachmentMetadata.count, 1)

        let loaded = result!.attachmentMetadata[0]
        XCTAssertEqual(loaded.id, attachmentId)
        XCTAssertEqual(loaded.type, .image)
        XCTAssertEqual(loaded.mimeType, "image/jpeg")
        XCTAssertEqual(loaded.fileName, "photo.jpg")
        XCTAssertEqual(loaded.originalSize, 5000)
        XCTAssertTrue(loaded.wasConverted)
        XCTAssertEqual(loaded.originalMimeType, "image/gif")
    }

    func testSaveAndLoadDraft_fullDraft() async throws {
        let attachments = [makeAttachmentMetadata(), makeAttachmentMetadata(type: .pdf, mimeType: "application/pdf", fileName: "doc.pdf")]

        try await database.drafts.save(
            sessionId: "s1",
            text: "Please review this",
            attachmentMetadata: attachments
        )

        let result = try await database.drafts.load(sessionId: "s1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text, "Please review this")
        XCTAssertEqual(result?.attachmentMetadata.count, 2)
    }

    func testSaveAndLoadDraft_emptyArrays() async throws {
        try await database.drafts.save(
            sessionId: "s1",
            text: "",
            attachmentMetadata: []
        )

        let result = try await database.drafts.load(sessionId: "s1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text, "")
        XCTAssertTrue(result?.attachmentMetadata.isEmpty ?? false)
    }

    // MARK: - Load Non-Existent

    func testLoadDraft_nonExistentSession_returnsNil() async throws {
        let result = try await database.drafts.load(sessionId: "no-such-session")
        XCTAssertNil(result)
    }

    // MARK: - Overwrite (UPSERT)

    func testSaveDraft_overwritesExisting() async throws {
        try await database.drafts.save(
            sessionId: "s1",
            text: "first version",
            attachmentMetadata: []
        )

        try await database.drafts.save(
            sessionId: "s1",
            text: "second version",
            attachmentMetadata: []
        )

        let result = try await database.drafts.load(sessionId: "s1")
        XCTAssertEqual(result?.text, "second version")
    }

    // MARK: - Delete

    func testDeleteDraft() async throws {
        try await database.drafts.save(
            sessionId: "s1",
            text: "will be deleted",
            attachmentMetadata: []
        )

        try await database.drafts.delete(sessionId: "s1")

        let result = try await database.drafts.load(sessionId: "s1")
        XCTAssertNil(result)
    }

    func testDeleteDraft_nonExistent_noError() async throws {
        // Should not throw
        try await database.drafts.delete(sessionId: "no-such-session")
    }

    func testDeleteAll() async throws {
        try await database.drafts.save(sessionId: "s1", text: "a", attachmentMetadata: [])
        try await database.drafts.save(sessionId: "s2", text: "b", attachmentMetadata: [])
        try await database.drafts.save(sessionId: "s3", text: "c", attachmentMetadata: [])

        try await database.drafts.deleteAll()

        let r1 = try await database.drafts.load(sessionId: "s1")
        let r2 = try await database.drafts.load(sessionId: "s2")
        let r3 = try await database.drafts.load(sessionId: "s3")
        XCTAssertNil(r1)
        XCTAssertNil(r2)
        XCTAssertNil(r3)
    }

    // MARK: - Special Characters

    func testSaveDraft_specialCharactersInText() async throws {
        let text = "Hello 🌍! \"Quotes\" & <brackets> \n\ttabs\n日本語テスト"

        try await database.drafts.save(
            sessionId: "s1",
            text: text,
            attachmentMetadata: []
        )

        let result = try await database.drafts.load(sessionId: "s1")
        XCTAssertEqual(result?.text, text)
    }

    func testSaveDraft_veryLongText() async throws {
        let text = String(repeating: "x", count: 100_000)

        try await database.drafts.save(
            sessionId: "s1",
            text: text,
            attachmentMetadata: []
        )

        let result = try await database.drafts.load(sessionId: "s1")
        XCTAssertEqual(result?.text.count, 100_000)
    }

    // MARK: - Corrupt JSON Handling

    func testLoadDraft_corruptAttachmentMetadataJson_returnsNil() async throws {
        // Manually insert a row with corrupt JSON
        let sql = """
            INSERT INTO session_drafts (session_id, text, attachment_metadata_json, updated_at)
            VALUES ('corrupt', 'text', '{NOT VALID JSON}', '2026-04-03T00:00:00Z')
        """
        try await database.withDB { db in
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw EventDatabaseError.executeFailed(sqliteErrorMessage(db))
            }
        }

        let result = try await database.drafts.load(sessionId: "corrupt")
        XCTAssertNil(result)
    }

    // MARK: - Schema migration regression guards

    func testFreshDatabase_hasNoDraftSkillColumns() async throws {
        let columns = try await withFreshDatabase { freshDatabase in
            try await draftColumns(in: freshDatabase)
        }
        XCTAssertFalse(columns.contains("skills" + "_json"))
        XCTAssertFalse(columns.contains("spells" + "_json"))
    }

    func testMigration_idempotent_runsTwiceWithoutError() async throws {
        let columns = try await withFreshDatabase { freshDatabase in
            try await freshDatabase.withDB { db in
                try DatabaseSchema.createTables(db: db)
            }
            return try await draftColumns(in: freshDatabase)
        }
        XCTAssertEqual(columns, ["session_id", "text", "attachment_metadata_json", "updated_at"])
    }

    private func withFreshDatabase<T>(_ body: (EventDatabase) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let freshDatabase = EventDatabase(temporaryCachePath: directory.appendingPathComponent("drafts.db").path)
        try await freshDatabase.initialize()

        do {
            let result = try await body(freshDatabase)
            await freshDatabase.close()
            try? FileManager.default.removeItem(at: directory)
            return result
        } catch {
            await freshDatabase.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func draftColumns(in database: EventDatabase) async throws -> [String] {
        try await database.withDB { db in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }

            guard sqlite3_prepare_v2(db, "PRAGMA table_info(session_drafts)", -1, &stmt, nil) == SQLITE_OK else {
                throw EventDatabaseError.prepareFailed(sqliteErrorMessage(db))
            }

            var columns: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                columns.append(String(cString: sqlite3_column_text(stmt, 1)))
            }
            return columns
        }
    }
}
