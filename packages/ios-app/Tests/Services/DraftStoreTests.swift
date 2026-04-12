import XCTest
import SQLite3
@testable import TronMobile

/// Tests for DraftStore — draft persistence coordinator with debounce and file I/O
@MainActor
final class DraftStoreTests: XCTestCase {

    var database: EventDatabase!
    var draftStore: DraftStore!

    override func setUp() async throws {
        database = EventDatabase()
        try await database.initialize()
        try await database.clearAll()
        draftStore = DraftStore(eventDatabase: database, documentsURL: FileManager.default.temporaryDirectory)
    }

    override func tearDown() async throws {
        // Clean up draft files
        draftStore.removeAllDraftFiles()
        try? await database.clearAll()
        await database.close()
    }

    // MARK: - Helpers

    private func makeAttachment(id: UUID = UUID(), data: Data = Data([0x89, 0x50, 0x4E, 0x47])) -> Attachment {
        Attachment(id: id, type: .image, data: data, mimeType: "image/jpeg", fileName: "photo.jpg")
    }

    private func makeSkill(name: String, source: SkillSource = .global) -> Skill {
        Skill(name: name, displayName: name.capitalized, description: "A \(name)", source: source, tags: nil)
    }

    // MARK: - Core Save/Load/Clear

    func testSaveAndLoad_textOnly() async throws {
        let state = InputBarState()
        state.text = "Hello, world!"

        await draftStore.saveImmediately(sessionId: "s1", inputBarState: state)

        let freshState = InputBarState()
        let loaded = await draftStore.loadDraft(sessionId: "s1", into: freshState)

        XCTAssertTrue(loaded)
        XCTAssertEqual(freshState.text, "Hello, world!")
        XCTAssertTrue(freshState.attachments.isEmpty)
        XCTAssertTrue(freshState.selectedSkills.isEmpty)
        XCTAssertTrue(freshState.selectedSpells.isEmpty)
    }

    func testSaveAndLoad_withAttachments() async throws {
        let attachmentData = Data(repeating: 0xAB, count: 256)
        let attachmentId = UUID()
        let state = InputBarState()
        state.attachments = [makeAttachment(id: attachmentId, data: attachmentData)]

        await draftStore.saveImmediately(sessionId: "s1", inputBarState: state)

        let freshState = InputBarState()
        let loaded = await draftStore.loadDraft(sessionId: "s1", into: freshState)

        XCTAssertTrue(loaded)
        XCTAssertEqual(freshState.attachments.count, 1)
        XCTAssertEqual(freshState.attachments[0].id, attachmentId)
        XCTAssertEqual(freshState.attachments[0].data, attachmentData)
        XCTAssertEqual(freshState.attachments[0].mimeType, "image/jpeg")
        XCTAssertEqual(freshState.attachments[0].fileName, "photo.jpg")
    }

    func testSaveAndLoad_withSkills() async throws {
        let state = InputBarState()
        state.selectedSkills = [makeSkill(name: "code-review"), makeSkill(name: "testing", source: .project)]

        await draftStore.saveImmediately(sessionId: "s1", inputBarState: state)

        let freshState = InputBarState()
        let loaded = await draftStore.loadDraft(sessionId: "s1", into: freshState)

        XCTAssertTrue(loaded)
        XCTAssertEqual(freshState.selectedSkills.count, 2)
        XCTAssertEqual(freshState.selectedSkills[0].name, "code-review")
        XCTAssertEqual(freshState.selectedSkills[1].name, "testing")
        XCTAssertEqual(freshState.selectedSkills[1].source, .project)
    }

    func testSaveAndLoad_withSpells() async throws {
        let state = InputBarState()
        state.selectedSpells = [makeSkill(name: "old-english")]

        await draftStore.saveImmediately(sessionId: "s1", inputBarState: state)

        let freshState = InputBarState()
        let loaded = await draftStore.loadDraft(sessionId: "s1", into: freshState)

        XCTAssertTrue(loaded)
        XCTAssertEqual(freshState.selectedSpells.count, 1)
        XCTAssertEqual(freshState.selectedSpells[0].name, "old-english")
    }

    func testSaveAndLoad_fullState() async throws {
        let state = InputBarState()
        state.text = "Please review"
        state.selectedSkills = [makeSkill(name: "review")]
        state.selectedSpells = [makeSkill(name: "formal")]
        state.attachments = [makeAttachment(), makeAttachment()]

        await draftStore.saveImmediately(sessionId: "s1", inputBarState: state)

        let freshState = InputBarState()
        let loaded = await draftStore.loadDraft(sessionId: "s1", into: freshState)

        XCTAssertTrue(loaded)
        XCTAssertEqual(freshState.text, "Please review")
        XCTAssertEqual(freshState.selectedSkills.count, 1)
        XCTAssertEqual(freshState.selectedSpells.count, 1)
        XCTAssertEqual(freshState.attachments.count, 2)
    }

    func testLoadDraft_noExistingDraft_returnsFalse() async throws {
        let state = InputBarState()
        state.text = "should not change"

        let loaded = await draftStore.loadDraft(sessionId: "nonexistent", into: state)

        XCTAssertFalse(loaded)
        XCTAssertEqual(state.text, "should not change")
    }

    func testClearDraft_removesSqliteRow() async throws {
        let state = InputBarState()
        state.text = "will be cleared"
        await draftStore.saveImmediately(sessionId: "s1", inputBarState: state)

        await draftStore.clearDraft(sessionId: "s1")

        let freshState = InputBarState()
        let loaded = await draftStore.loadDraft(sessionId: "s1", into: freshState)
        XCTAssertFalse(loaded)
    }

    func testClearDraft_removesAttachmentFiles() async throws {
        let state = InputBarState()
        state.attachments = [makeAttachment()]
        await draftStore.saveImmediately(sessionId: "s1", inputBarState: state)

        // Verify files exist
        let dir = draftStore.draftsDirectory(for: "s1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))

        await draftStore.clearDraft(sessionId: "s1")

        // Verify files removed
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testClearDraft_nonExistentSession_noError() async throws {
        // Should not crash
        await draftStore.clearDraft(sessionId: "nonexistent")
    }

    func testDeleteSessionDraft_fullCleanup() async throws {
        let state = InputBarState()
        state.text = "test"
        state.attachments = [makeAttachment()]
        await draftStore.saveImmediately(sessionId: "s1", inputBarState: state)

        let dir = draftStore.draftsDirectory(for: "s1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))

        await draftStore.deleteSessionDraft(sessionId: "s1")

        // Both SQLite and files should be gone
        let freshState = InputBarState()
        let loaded = await draftStore.loadDraft(sessionId: "s1", into: freshState)
        XCTAssertFalse(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    // MARK: - Edge Cases

    func testSaveImmediately_emptyState_deletesExistingDraft() async throws {
        // First save a draft with content
        let state = InputBarState()
        state.text = "something"
        await draftStore.saveImmediately(sessionId: "s1", inputBarState: state)

        // Now save with empty state — should delete existing draft
        let emptyState = InputBarState()
        await draftStore.saveImmediately(sessionId: "s1", inputBarState: emptyState)

        let freshState = InputBarState()
        let loaded = await draftStore.loadDraft(sessionId: "s1", into: freshState)
        XCTAssertFalse(loaded)
    }

    func testSaveImmediately_emptyState_noExistingDraft_noOp() async throws {
        // Should not crash or create empty rows
        let emptyState = InputBarState()
        await draftStore.saveImmediately(sessionId: "nonexistent", inputBarState: emptyState)

        let freshState = InputBarState()
        let loaded = await draftStore.loadDraft(sessionId: "nonexistent", into: freshState)
        XCTAssertFalse(loaded)
    }

    func testLoadDraft_missingAttachmentFile_skipsGracefully() async throws {
        let state = InputBarState()
        state.attachments = [makeAttachment(), makeAttachment()]
        await draftStore.saveImmediately(sessionId: "s1", inputBarState: state)

        // Delete one attachment file manually
        let dir = draftStore.draftsDirectory(for: "s1")
        let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        if let firstFile = files?.first {
            try? FileManager.default.removeItem(at: firstFile)
        }

        // Load should succeed with remaining attachment
        let freshState = InputBarState()
        let loaded = await draftStore.loadDraft(sessionId: "s1", into: freshState)
        XCTAssertTrue(loaded)
        // Should have 1 attachment (the one whose file still exists)
        XCTAssertEqual(freshState.attachments.count, 1)
    }

    func testSaveImmediately_overwritesPreviousDraft() async throws {
        let state = InputBarState()
        state.text = "first"
        await draftStore.saveImmediately(sessionId: "s1", inputBarState: state)

        state.text = "second"
        await draftStore.saveImmediately(sessionId: "s1", inputBarState: state)

        let freshState = InputBarState()
        _ = await draftStore.loadDraft(sessionId: "s1", into: freshState)
        XCTAssertEqual(freshState.text, "second")
    }

    func testConcurrentSessions_independentDrafts() async throws {
        let stateA = InputBarState()
        stateA.text = "session A"
        stateA.selectedSkills = [makeSkill(name: "skill-a")]

        let stateB = InputBarState()
        stateB.text = "session B"
        stateB.selectedSpells = [makeSkill(name: "spell-b")]

        await draftStore.saveImmediately(sessionId: "sA", inputBarState: stateA)
        await draftStore.saveImmediately(sessionId: "sB", inputBarState: stateB)

        let loadedA = InputBarState()
        let loadedB = InputBarState()
        let resultA = await draftStore.loadDraft(sessionId: "sA", into: loadedA)
        let resultB = await draftStore.loadDraft(sessionId: "sB", into: loadedB)
        XCTAssertTrue(resultA)
        XCTAssertTrue(resultB)

        XCTAssertEqual(loadedA.text, "session A")
        XCTAssertEqual(loadedA.selectedSkills.count, 1)
        XCTAssertTrue(loadedA.selectedSpells.isEmpty)

        XCTAssertEqual(loadedB.text, "session B")
        XCTAssertTrue(loadedB.selectedSkills.isEmpty)
        XCTAssertEqual(loadedB.selectedSpells.count, 1)
    }

    func testSelectedImages_notPersisted() async throws {
        let state = InputBarState()
        state.text = "test"
        await draftStore.saveImmediately(sessionId: "s1", inputBarState: state)

        let freshState = InputBarState()
        _ = await draftStore.loadDraft(sessionId: "s1", into: freshState)
        XCTAssertTrue(freshState.selectedImages.isEmpty)
    }

    func testReasoningLevel_notPersistedByDraftStore() async throws {
        let state = InputBarState()
        state.text = "test"
        state.reasoningLevel = "high"
        await draftStore.saveImmediately(sessionId: "s1", inputBarState: state)

        let freshState = InputBarState()
        freshState.reasoningLevel = "low"
        _ = await draftStore.loadDraft(sessionId: "s1", into: freshState)
        XCTAssertEqual(freshState.reasoningLevel, "low")
    }

    func testAttachmentFileDirectory_createdOnSave() async throws {
        let state = InputBarState()
        state.attachments = [makeAttachment()]

        let dir = draftStore.draftsDirectory(for: "s1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))

        await draftStore.saveImmediately(sessionId: "s1", inputBarState: state)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    // MARK: - Debounce

    func testScheduleSave_debouncesRapidCalls() async throws {
        let state = InputBarState()

        // Rapid calls — only the last should be saved
        for i in 0..<10 {
            state.text = "version \(i)"
            draftStore.scheduleSave(sessionId: "s1", inputBarState: state)
        }

        // Wait for debounce to fire
        try? await Task.sleep(for: .milliseconds(700))

        let freshState = InputBarState()
        let loaded = await draftStore.loadDraft(sessionId: "s1", into: freshState)
        XCTAssertTrue(loaded)
        XCTAssertEqual(freshState.text, "version 9")
    }

    func testSaveImmediately_cancelsPendingDebounce() async throws {
        let state = InputBarState()
        state.text = "debounced version"
        draftStore.scheduleSave(sessionId: "s1", inputBarState: state)

        // Immediately save a different version
        state.text = "immediate version"
        await draftStore.saveImmediately(sessionId: "s1", inputBarState: state)

        // Wait past debounce interval
        try? await Task.sleep(for: .milliseconds(700))

        let freshState = InputBarState()
        _ = await draftStore.loadDraft(sessionId: "s1", into: freshState)
        XCTAssertEqual(freshState.text, "immediate version")
    }

    func testScheduleSave_savesAfterInterval() async throws {
        let state = InputBarState()
        state.text = "deferred save"
        draftStore.scheduleSave(sessionId: "s1", inputBarState: state)

        // Not saved yet
        let beforeState = InputBarState()
        let beforeLoaded = await draftStore.loadDraft(sessionId: "s1", into: beforeState)
        XCTAssertFalse(beforeLoaded)

        // Wait for debounce
        try? await Task.sleep(for: .milliseconds(700))

        let afterState = InputBarState()
        let afterLoaded = await draftStore.loadDraft(sessionId: "s1", into: afterState)
        XCTAssertTrue(afterLoaded)
        XCTAssertEqual(afterState.text, "deferred save")
    }

    // MARK: - Fingerprint Dedup

    func testSaveImmediately_identicalState_skipsRedundantWrite() async throws {
        let state = InputBarState()
        state.text = "same text"
        state.selectedSkills = [makeSkill(name: "review")]

        // First save
        await draftStore.saveImmediately(sessionId: "s1", inputBarState: state)

        // Modify DB directly to detect if second save actually writes
        try? await database.withDB { db in
            guard sqlite3_exec(db, "UPDATE session_drafts SET text = 'MARKER' WHERE session_id = 's1'", nil, nil, nil) == SQLITE_OK else {
                throw EventDatabaseError.executeFailed(sqliteErrorMessage(db))
            }
        }

        // Second save with identical state — should skip
        await draftStore.saveImmediately(sessionId: "s1", inputBarState: state)

        // If save was skipped, the MARKER should still be there
        let freshState = InputBarState()
        _ = await draftStore.loadDraft(sessionId: "s1", into: freshState)
        XCTAssertEqual(freshState.text, "MARKER")
    }
}
