import XCTest
import SQLite3
@testable import TronMobile

/// Tests for DraftStore — draft persistence coordinator with debounce and file I/O
@MainActor
final class DraftStoreTests: XCTestCase {

    var database: EventDatabase!
    var draftStore: DraftStore!
    var testState: IsolatedTestState!

    override func setUp() async throws {
        testState = IsolatedTestState(label: "draft-store")
        testState.registerTeardown(with: self)
        database = testState.makeDatabase()
        try await database.initialize()
        try await database.clearAll()
        draftStore = DraftStore(eventDatabase: database, documentsURL: testState.documentsURL)
    }

    override func tearDown() async throws {
        // Clean up draft files
        draftStore.removeAllDraftFiles()
        try? await database.clearAll()
        await testState.cleanup()
    }

    // MARK: - Helpers

    private func makeAttachment(id: UUID = UUID(), data: Data = Data([0x89, 0x50, 0x4E, 0x47])) -> Attachment {
        Attachment(id: id, type: .image, data: data, mimeType: "image/jpeg", fileName: "photo.jpg")
    }

    private func makeQuestionRequest(invocationId: String) -> UserInputRequest {
        UserInputRequest(
            invocationId: invocationId,
            questions: [
                UserInputQuestion(
                    header: "Choice",
                    id: "choice",
                    question: "Choose one",
                    options: [
                        UserInputOption(label: "First", description: "First option"),
                        UserInputOption(label: "Second", description: "Second option")
                    ]
                )
            ],
            answers: [],
            status: .pending
        )
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
    }

    func testPreparedHandoffRevealsTextEndOnExactlyOneLoad() async throws {
        let state = InputBarState()
        state.text = String(repeating: "Prepared handoff\n", count: 20)
        await draftStore.saveImmediately(sessionId: "handoff", inputBarState: state)
        draftStore.revealTextEndOnNextLoad(sessionId: "handoff")

        let first = InputBarState()
        let firstLoaded = await draftStore.loadDraft(sessionId: "handoff", into: first)
        XCTAssertTrue(firstLoaded)
        XCTAssertEqual(first.textEndRevealRevision, 1)

        let second = InputBarState()
        let secondLoaded = await draftStore.loadDraft(sessionId: "handoff", into: second)
        XCTAssertTrue(secondLoaded)
        XCTAssertEqual(second.textEndRevealRevision, 0)
    }

    func testSaveAndLoad_largeAttachmentUsesFileOwner() async throws {
        let attachmentData = Data(repeating: 0xAB, count: 2 * 1_024 * 1_024)
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

    func testSaveAndLoad_fullState() async throws {
        let state = InputBarState()
        state.text = "Please review"
        state.attachments = [makeAttachment(), makeAttachment()]

        await draftStore.saveImmediately(sessionId: "s1", inputBarState: state)

        let freshState = InputBarState()
        let loaded = await draftStore.loadDraft(sessionId: "s1", into: freshState)

        XCTAssertTrue(loaded)
        XCTAssertEqual(freshState.text, "Please review")
        XCTAssertEqual(freshState.attachments.count, 2)
    }

    func testLoadDraft_noExistingDraft_returnsFalse() async throws {
        let state = InputBarState()
        state.text = "should not change"

        let loaded = await draftStore.loadDraft(sessionId: "nonexistent", into: state)

        XCTAssertFalse(loaded)
        XCTAssertEqual(state.text, "should not change")
    }

    func testGuardedDraftRestoreDoesNotOverwriteNewTyping() async throws {
        let persisted = InputBarState()
        persisted.text = "older persisted draft"
        await draftStore.saveImmediately(sessionId: "s1", inputBarState: persisted)

        let mountedComposer = InputBarState()
        let initialFingerprint = mountedComposer.draftFingerprint
        mountedComposer.text = "typing started while the draft loaded"

        let loaded = await draftStore.loadDraft(
            sessionId: "s1",
            into: mountedComposer,
            ifUnchangedFrom: initialFingerprint
        )

        XCTAssertFalse(loaded)
        XCTAssertEqual(mountedComposer.text, "typing started while the draft loaded")
        XCTAssertTrue(mountedComposer.attachments.isEmpty)
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
        let request = makeQuestionRequest(invocationId: "question-to-delete")
        var questionDraft = UserInputDraft(request: request)
        questionDraft.selectedLabels["choice"] = "First"
        await draftStore.saveUserInputDraft(
            sessionId: "s1",
            invocationId: request.invocationId,
            draft: questionDraft
        )

        let dir = draftStore.draftsDirectory(for: "s1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))

        await draftStore.deleteSessionDraft(sessionId: "s1")

        // Both SQLite and files should be gone
        let freshState = InputBarState()
        let loaded = await draftStore.loadDraft(sessionId: "s1", into: freshState)
        XCTAssertFalse(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        let restoredQuestion = await draftStore.loadUserInputDraft(sessionId: "s1", request: request)
        XCTAssertNil(restoredQuestion)
    }

    func testQuestionDraftSurvivesStoreRecreationAndReconcilesCurrentContract() async throws {
        let original = UserInputRequest(
            invocationId: "question-1",
            questions: [
                UserInputQuestion(
                    header: "Format",
                    id: "format",
                    question: "Choose a format",
                    options: [
                        UserInputOption(label: "Short", description: "Short response"),
                        UserInputOption(label: "Long", description: "Long response")
                    ]
                )
            ],
            answers: [],
            status: .pending
        )
        var draft = UserInputDraft(request: original)
        draft.selectedLabels["format"] = "Long"
        draft.selectedLabels["removed-question"] = "Stale"
        draft.hasBeenPresented = true
        draftStore.scheduleUserInputDraftSave(
            sessionId: "s1",
            invocationId: original.invocationId,
            draft: draft
        )
        await draftStore.flushPending()

        let recreated = DraftStore(
            eventDatabase: database,
            documentsURL: testState.documentsURL
        )
        let restored = await recreated.loadUserInputDraft(
            sessionId: "s1",
            request: original
        )

        XCTAssertEqual(restored?.selectedLabels, ["format": "Long"])
        XCTAssertEqual(restored?.hasBeenPresented, true)
    }

    func testClearingQuestionDraftRemovesPersistedSelection() async throws {
        let request = UserInputRequest(
            invocationId: "question-2",
            questions: [
                UserInputQuestion(
                    header: "Tone",
                    id: "tone",
                    question: "Choose a tone",
                    options: [
                        UserInputOption(label: "Warm", description: "Warm tone"),
                        UserInputOption(label: "Direct", description: "Direct tone")
                    ]
                )
            ],
            answers: [],
            status: .pending
        )
        var draft = UserInputDraft(request: request)
        draft.selectedLabels["tone"] = "Warm"
        draftStore.scheduleUserInputDraftSave(
            sessionId: "s1",
            invocationId: request.invocationId,
            draft: draft
        )
        await draftStore.flushPending()

        await draftStore.clearUserInputDraft(
            sessionId: "s1",
            invocationId: request.invocationId
        )

        let restored = await draftStore.loadUserInputDraft(sessionId: "s1", request: request)
        XCTAssertNil(restored)
    }

    func testQuestionDraftDecodesRowsWrittenBeforePresentationMarkerExisted() throws {
        let legacyJSON = """
        {
          "selectedLabels": {"choice": "First"},
          "customAnswers": {},
          "customQuestionIds": []
        }
        """

        let decoded = try JSONDecoder().decode(
            UserInputDraft.self,
            from: Data(legacyJSON.utf8)
        )

        XCTAssertEqual(decoded.selectedLabels, ["choice": "First"])
        XCTAssertFalse(decoded.hasBeenPresented)
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

        let stateB = InputBarState()
        stateB.text = "session B"

        await draftStore.saveImmediately(sessionId: "sA", inputBarState: stateA)
        await draftStore.saveImmediately(sessionId: "sB", inputBarState: stateB)

        let loadedA = InputBarState()
        let loadedB = InputBarState()
        let resultA = await draftStore.loadDraft(sessionId: "sA", into: loadedA)
        let resultB = await draftStore.loadDraft(sessionId: "sB", into: loadedB)
        XCTAssertTrue(resultA)
        XCTAssertTrue(resultB)

        XCTAssertEqual(loadedA.text, "session A")

        XCTAssertEqual(loadedB.text, "session B")
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
