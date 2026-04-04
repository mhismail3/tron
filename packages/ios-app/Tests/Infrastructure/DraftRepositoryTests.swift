import XCTest
import SQLite3
@testable import TronMobile

/// Tests for DraftRepository — SQLite CRUD for session_drafts table
final class DraftRepositoryTests: XCTestCase {

    var database: EventDatabase!

    @MainActor
    override func setUp() async throws {
        database = EventDatabase()
        try await database.initialize()
        try database.clearAll()
    }

    @MainActor
    override func tearDown() async throws {
        try? database.clearAll()
        database.close()
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

    @MainActor
    func testSaveAndLoadDraft_textOnly() throws {
        try database.drafts.save(
            sessionId: "s1",
            text: "Hello, world!",
            skills: [],
            spells: [],
            attachmentMetadata: []
        )

        let result = try database.drafts.load(sessionId: "s1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text, "Hello, world!")
        XCTAssertTrue(result?.skills.isEmpty ?? false)
        XCTAssertTrue(result?.spells.isEmpty ?? false)
        XCTAssertTrue(result?.attachmentMetadata.isEmpty ?? false)
    }

    @MainActor
    func testSaveAndLoadDraft_withSkills() throws {
        let skills = [makeSkill(name: "code-review"), makeSkill(name: "testing", source: .project)]

        try database.drafts.save(
            sessionId: "s1",
            text: "",
            skills: skills,
            spells: [],
            attachmentMetadata: []
        )

        let result = try database.drafts.load(sessionId: "s1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.skills.count, 2)
        XCTAssertEqual(result?.skills[0].name, "code-review")
        XCTAssertEqual(result?.skills[0].source, .global)
        XCTAssertEqual(result?.skills[1].name, "testing")
        XCTAssertEqual(result?.skills[1].source, .project)
    }

    @MainActor
    func testSaveAndLoadDraft_withSpells() throws {
        let spells = [makeSkill(name: "old-english")]

        try database.drafts.save(
            sessionId: "s1",
            text: "test",
            skills: [],
            spells: spells,
            attachmentMetadata: []
        )

        let result = try database.drafts.load(sessionId: "s1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.spells.count, 1)
        XCTAssertEqual(result?.spells[0].name, "old-english")
    }

    @MainActor
    func testSaveAndLoadDraft_withAttachmentMetadata() throws {
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

        try database.drafts.save(
            sessionId: "s1",
            text: "",
            skills: [],
            spells: [],
            attachmentMetadata: metadata
        )

        let result = try database.drafts.load(sessionId: "s1")
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

    @MainActor
    func testSaveAndLoadDraft_fullDraft() throws {
        let skills = [makeSkill(name: "review")]
        let spells = [makeSkill(name: "formal")]
        let attachments = [makeAttachmentMetadata(), makeAttachmentMetadata(type: .pdf, mimeType: "application/pdf", fileName: "doc.pdf")]

        try database.drafts.save(
            sessionId: "s1",
            text: "Please review this",
            skills: skills,
            spells: spells,
            attachmentMetadata: attachments
        )

        let result = try database.drafts.load(sessionId: "s1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text, "Please review this")
        XCTAssertEqual(result?.skills.count, 1)
        XCTAssertEqual(result?.spells.count, 1)
        XCTAssertEqual(result?.attachmentMetadata.count, 2)
    }

    @MainActor
    func testSaveAndLoadDraft_emptyArrays() throws {
        try database.drafts.save(
            sessionId: "s1",
            text: "",
            skills: [],
            spells: [],
            attachmentMetadata: []
        )

        let result = try database.drafts.load(sessionId: "s1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text, "")
        XCTAssertTrue(result?.skills.isEmpty ?? false)
        XCTAssertTrue(result?.spells.isEmpty ?? false)
        XCTAssertTrue(result?.attachmentMetadata.isEmpty ?? false)
    }

    // MARK: - Load Non-Existent

    @MainActor
    func testLoadDraft_nonExistentSession_returnsNil() throws {
        let result = try database.drafts.load(sessionId: "no-such-session")
        XCTAssertNil(result)
    }

    // MARK: - Overwrite (UPSERT)

    @MainActor
    func testSaveDraft_overwritesExisting() throws {
        try database.drafts.save(
            sessionId: "s1",
            text: "first version",
            skills: [],
            spells: [],
            attachmentMetadata: []
        )

        try database.drafts.save(
            sessionId: "s1",
            text: "second version",
            skills: [makeSkill(name: "added-later")],
            spells: [],
            attachmentMetadata: []
        )

        let result = try database.drafts.load(sessionId: "s1")
        XCTAssertEqual(result?.text, "second version")
        XCTAssertEqual(result?.skills.count, 1)
        XCTAssertEqual(result?.skills[0].name, "added-later")
    }

    // MARK: - Delete

    @MainActor
    func testDeleteDraft() throws {
        try database.drafts.save(
            sessionId: "s1",
            text: "will be deleted",
            skills: [],
            spells: [],
            attachmentMetadata: []
        )

        try database.drafts.delete(sessionId: "s1")

        let result = try database.drafts.load(sessionId: "s1")
        XCTAssertNil(result)
    }

    @MainActor
    func testDeleteDraft_nonExistent_noError() throws {
        // Should not throw
        try database.drafts.delete(sessionId: "no-such-session")
    }

    @MainActor
    func testDeleteAll() throws {
        try database.drafts.save(sessionId: "s1", text: "a", skills: [], spells: [], attachmentMetadata: [])
        try database.drafts.save(sessionId: "s2", text: "b", skills: [], spells: [], attachmentMetadata: [])
        try database.drafts.save(sessionId: "s3", text: "c", skills: [], spells: [], attachmentMetadata: [])

        try database.drafts.deleteAll()

        XCTAssertNil(try database.drafts.load(sessionId: "s1"))
        XCTAssertNil(try database.drafts.load(sessionId: "s2"))
        XCTAssertNil(try database.drafts.load(sessionId: "s3"))
    }

    // MARK: - Special Characters

    @MainActor
    func testSaveDraft_specialCharactersInText() throws {
        let text = "Hello 🌍! \"Quotes\" & <brackets> \n\ttabs\n日本語テスト"

        try database.drafts.save(
            sessionId: "s1",
            text: text,
            skills: [],
            spells: [],
            attachmentMetadata: []
        )

        let result = try database.drafts.load(sessionId: "s1")
        XCTAssertEqual(result?.text, text)
    }

    @MainActor
    func testSaveDraft_veryLongText() throws {
        let text = String(repeating: "x", count: 100_000)

        try database.drafts.save(
            sessionId: "s1",
            text: text,
            skills: [],
            spells: [],
            attachmentMetadata: []
        )

        let result = try database.drafts.load(sessionId: "s1")
        XCTAssertEqual(result?.text.count, 100_000)
    }

    // MARK: - Corrupt JSON Handling

    @MainActor
    func testLoadDraft_corruptSkillsJson_returnsNil() throws {
        // Manually insert a row with corrupt JSON
        let sql = """
            INSERT INTO session_drafts (session_id, text, skills_json, spells_json, attachment_metadata_json, updated_at)
            VALUES ('corrupt', 'text', '{NOT VALID JSON}', '[]', '[]', '2026-04-03T00:00:00Z')
        """
        try database.execute(sql)

        let result = try database.drafts.load(sessionId: "corrupt")
        XCTAssertNil(result)
    }
}
