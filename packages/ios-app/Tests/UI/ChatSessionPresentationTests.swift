import Testing
@testable import TronMobile

@MainActor
@Suite("Chat session presentation ownership")
struct ChatSessionPresentationTests {
    @Test("cold reopen creates clean disposable state and no replay ledger")
    func coldReopen() {
        let retired = ChatSessionPresentation(sessionID: "session-a")
        retired.showContext = true
        retired.showSettings = true
        retired.showProcesses = true
        retired.modelPresentationGeneration = 7
        retired.canonicalSubmissionHandoffs.formUnion(["prompt-a"])
        retired.queueMutationCommandIsPending = true
        retired.locallyMutatedQueueOperationIDs = ["operation-a"]

        let reopened = ChatSessionPresentation(sessionID: "session-a")

        #expect(reopened.open.phase == .opening)
        #expect(reopened.modelPresentationGeneration == nil)
        #expect(reopened.canonicalSubmissionHandoffs.ids.isEmpty)
        #expect(!reopened.queueMutationCommandIsPending)
        #expect(reopened.locallyMutatedQueueOperationIDs.isEmpty)
        #expect(!reopened.showContext)
        #expect(!reopened.showSettings)
        #expect(!reopened.showProcesses)
    }

    @Test("suspension abandons picker and import targets without changing presentation authority")
    func suspension() throws {
        let owner = ChatSessionPresentation(sessionID: "session-a")
        owner.modelPresentationGeneration = 9
        let epoch = owner.open.begin(retainingVisiblePresentation: true)
        owner.attachmentDestination = .files
        owner.queuedAttachmentDestination = .camera
        owner.photoImportTarget = SessionPresentationIdentity(sessionID: "session-a", generation: 9)

        owner.suspendForBackground()

        #expect(owner.attachmentDestination == nil)
        #expect(owner.queuedAttachmentDestination == nil)
        #expect(owner.photoImportTarget == nil)
        #expect(owner.modelPresentationGeneration == 9)
        #expect(owner.open.epoch == epoch)
        #expect(owner.open.phase == .ready)
        #expect(!owner.needsOpeningResume)
    }

    @Test("opening task reservation is singular and exact-generation owned")
    func openingTaskOwnership() throws {
        let owner = ChatSessionPresentation(sessionID: "session-a")
        let firstTask = Task<Void, Never> {}
        let generation = try #require(owner.installOpeningTask(firstTask))

        #expect(owner.openingTask != nil)
        #expect(owner.installOpeningTask(Task<Void, Never> {}) == nil)

        owner.finishOpeningTask(generation &+ 1)
        #expect(owner.openingTask != nil)
        owner.cancelOpeningTask()
        let replacement = try #require(owner.installOpeningTask(Task<Void, Never> {}))
        owner.finishOpeningTask(generation)
        #expect(owner.openingTask != nil)
        owner.finishOpeningTask(replacement)
        #expect(owner.openingTask == nil)
    }

    @Test("foreground resumes an interrupted opening but not a passive ready session")
    func foregroundResumePolicy() {
        let inProgress = ChatSessionPresentation(sessionID: "session-a")
        _ = inProgress.open.begin()
        inProgress.suspendForBackground()
        #expect(inProgress.open.phase == .opening)
        #expect(inProgress.needsOpeningResume)

        let passive = ChatSessionPresentation(sessionID: "session-b")
        passive.modelPresentationGeneration = 4
        _ = passive.open.begin(retainingVisiblePresentation: true)
        passive.suspendForBackground()
        #expect(passive.open.phase == .ready)
        #expect(!passive.needsOpeningResume)

        passive.modelPresentationGeneration = nil
        #expect(passive.needsOpeningResume)
    }

    @Test("uncover waits for a covered opening and then retries only when still needed")
    func coveredOpeningResumePolicy() {
        #expect(ChatOpeningSurfacePolicy.action(
            surfaceActive: false,
            hasOpeningTask: true,
            needsOpeningResume: false
        ) == .none)
        #expect(ChatOpeningSurfacePolicy.action(
            surfaceActive: true,
            hasOpeningTask: true,
            needsOpeningResume: false
        ) == .waitForCurrentThenBeginIfNeeded)
        #expect(ChatOpeningSurfacePolicy.action(
            surfaceActive: true,
            hasOpeningTask: false,
            needsOpeningResume: true
        ) == .begin)
        #expect(ChatOpeningSurfacePolicy.action(
            surfaceActive: true,
            hasOpeningTask: false,
            needsOpeningResume: false
        ) == .none)
    }

    @Test("background suspension cancels an unanchored page task")
    func unanchoredPageCancellation() async throws {
        let clock = ManualClock()
        let owner = ChatSessionPresentation(sessionID: "session-a")
        owner.startUnanchoredPrepend {
            try? await clock.clock.sleep(.seconds(30))
        }
        try await clock.waitUntilSleeping(count: 1)

        owner.suspendForBackground()
        await Task.yield()

        #expect(clock.activeSleeperCount() == 0)
    }

    @Test("canonical alias ledger is causal one-to-one and bounded")
    func boundedAliases() {
        var ledger = BoundedChatIdentityAliasLedger()
        let inserted = ledger.insert(canonicalID: "canonical-a", presentationID: "lifecycle-a")
        let duplicate = ledger.insert(canonicalID: "canonical-a", presentationID: "lifecycle-a")
        let conflictingCanonical = ledger.insert(
            canonicalID: "canonical-a",
            presentationID: "unrelated"
        )
        let conflictingPresentation = ledger.insert(
            canonicalID: "canonical-b",
            presentationID: "lifecycle-a"
        )
        #expect(inserted)
        #expect(duplicate)
        #expect(!conflictingCanonical)
        #expect(!conflictingPresentation)
        #expect(ledger.aliases == ["canonical-a": "lifecycle-a"])

        var allInserted = true
        for index in 0..<(ChatTranscriptPageRequest.maximumItemCount + 20) {
            allInserted = ledger.insert(
                canonicalID: "canonical-\(index)",
                presentationID: "lifecycle-\(index)"
            ) && allInserted
        }
        #expect(allInserted)
        #expect(ledger.aliases.count == ChatTranscriptPageRequest.maximumItemCount)
    }

    @Test("canonical handoff ledger is bounded")
    func boundedHandoffs() {
        var ledger = BoundedChatIdentityLedger()
        let count = ChatTranscriptPageRequest.maximumItemCount + 20
        ledger.formUnion(Set((0..<count).map { "prompt-\($0)" }))
        #expect(ledger.ids.count == ChatTranscriptPageRequest.maximumItemCount)
    }
}
