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

    private func makeSkill(name: String, source: SkillSource = .global) -> Skill {
        Skill(name: name, displayName: name.capitalized, description: "A \(name)", source: source, tags: nil)
    }

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
            skills: [],
            attachmentMetadata: []
        )

        let result = try await database.drafts.load(sessionId: "s1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text, "Hello, world!")
        XCTAssertTrue(result?.skills.isEmpty ?? false)
        XCTAssertTrue(result?.attachmentMetadata.isEmpty ?? false)
    }

    func testSaveAndLoadDraft_withSkills() async throws {
        let skills = [makeSkill(name: "code-review"), makeSkill(name: "testing", source: .project)]

        try await database.drafts.save(
            sessionId: "s1",
            text: "",
            skills: skills,
            attachmentMetadata: []
        )

        let result = try await database.drafts.load(sessionId: "s1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.skills.count, 2)
        XCTAssertEqual(result?.skills[0].name, "code-review")
        XCTAssertEqual(result?.skills[0].source, .global)
        XCTAssertEqual(result?.skills[1].name, "testing")
        XCTAssertEqual(result?.skills[1].source, .project)
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
            skills: [],
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
        let skills = [makeSkill(name: "review")]
        let attachments = [makeAttachmentMetadata(), makeAttachmentMetadata(type: .pdf, mimeType: "application/pdf", fileName: "doc.pdf")]

        try await database.drafts.save(
            sessionId: "s1",
            text: "Please review this",
            skills: skills,
            attachmentMetadata: attachments
        )

        let result = try await database.drafts.load(sessionId: "s1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text, "Please review this")
        XCTAssertEqual(result?.skills.count, 1)
        XCTAssertEqual(result?.attachmentMetadata.count, 2)
    }

    func testSaveAndLoadDraft_emptyArrays() async throws {
        try await database.drafts.save(
            sessionId: "s1",
            text: "",
            skills: [],
            attachmentMetadata: []
        )

        let result = try await database.drafts.load(sessionId: "s1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text, "")
        XCTAssertTrue(result?.skills.isEmpty ?? false)
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
            skills: [],
            attachmentMetadata: []
        )

        try await database.drafts.save(
            sessionId: "s1",
            text: "second version",
            skills: [makeSkill(name: "added-later")],
            attachmentMetadata: []
        )

        let result = try await database.drafts.load(sessionId: "s1")
        XCTAssertEqual(result?.text, "second version")
        XCTAssertEqual(result?.skills.count, 1)
        XCTAssertEqual(result?.skills[0].name, "added-later")
    }

    // MARK: - Delete

    func testDeleteDraft() async throws {
        try await database.drafts.save(
            sessionId: "s1",
            text: "will be deleted",
            skills: [],
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
        try await database.drafts.save(sessionId: "s1", text: "a", skills: [], attachmentMetadata: [])
        try await database.drafts.save(sessionId: "s2", text: "b", skills: [], attachmentMetadata: [])
        try await database.drafts.save(sessionId: "s3", text: "c", skills: [], attachmentMetadata: [])

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
            skills: [],
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
            skills: [],
            attachmentMetadata: []
        )

        let result = try await database.drafts.load(sessionId: "s1")
        XCTAssertEqual(result?.text.count, 100_000)
    }

    // MARK: - Corrupt JSON Handling

    func testLoadDraft_corruptSkillsJson_returnsNil() async throws {
        // Manually insert a row with corrupt JSON
        let sql = """
            INSERT INTO session_drafts (session_id, text, skills_json, attachment_metadata_json, updated_at)
            VALUES ('corrupt', 'text', '{NOT VALID JSON}', '[]', '2026-04-03T00:00:00Z')
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

    func testFreshDatabase_noSpellsJsonColumn() async throws {
        let exists = try await database.withDB { db in
            try DatabaseSchema.columnExists(table: "session_drafts", column: "spells_json", db: db)
        }
        XCTAssertFalse(exists)
    }

    func testMigration_idempotent_runsTwiceWithoutError() async throws {
        try await database.withDB { db in
            try DatabaseSchema.createTables(db: db)
        }
        let exists = try await database.withDB { db in
            try DatabaseSchema.columnExists(table: "session_drafts", column: "spells_json", db: db)
        }
        XCTAssertFalse(exists)
    }
}
