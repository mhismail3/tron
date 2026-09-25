import Testing
@testable import TronMobile

@MainActor
@Suite("Chat session presentation ownership")
struct ChatSessionPresentationTests {

    @Test("pending interaction has one stable presentation owner and explicit reopen intent")
    func interactionPresentationOwnership() {
        let owner = ChatSessionPresentation(sessionID: "session-a")
        let interaction = ExtensionInteraction(
            id: "question", hostEpoch: "epoch", presentationRevision: 3,
            method: .select, title: "Choose", options: ["A"]
        )
        let scope = ExtensionInteractionScope(interaction)

        owner.requestInteractionPresentation(interaction)
        #expect(owner.requestedInteractionScope == scope)
        owner.closeInteractionPresentation(interaction)
        #expect(owner.requestedInteractionScope == nil)
        #expect(owner.suppressedInteractionScope == scope)

        owner.reconcileInteractionPresentation(with: [interaction])
        #expect(owner.suppressedInteractionScope == scope)
        owner.requestInteractionPresentation(interaction)
        #expect(owner.requestedInteractionScope == scope)
        owner.reconcileInteractionPresentation(with: [])
        #expect(owner.requestedInteractionScope == nil)
        #expect(owner.suppressedInteractionScope == nil)
    }

    @Test("suspension abandons picker and import targets without changing presentation authority")
    func suspension() throws {
        let owner = ChatSessionPresentation(sessionID: "session-a")
        owner.modelPresentationGeneration = 9
        let epoch = owner.open.begin(retainingVisiblePresentation: true)
        owner.attachmentDestination = .files
        owner.queuedAttachmentDestination = .camera
        owner.photoImportTarget = SessionPresentationIdentity(sessionID: "session-a", generation: 9)
        let paste = Task<Void, Never> {}
        owner.pastedImageImports[UUID()] = paste

        owner.suspendForBackground()

        #expect(owner.attachmentDestination == nil)
        #expect(owner.queuedAttachmentDestination == nil)
        #expect(owner.photoImportTarget == nil)
        #expect(owner.pastedImageImports.isEmpty)
        #expect(paste.isCancelled)
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

        #expect(!owner.finishOpeningTask(generation &+ 1))
        #expect(owner.openingTask != nil)
        owner.cancelOpeningTask()
        #expect(owner.openingTaskWasCancelled(generation))
        #expect(owner.installOpeningTask(Task<Void, Never> {}) == nil)
        #expect(owner.activeOpeningTaskLease?.generation == generation)
        #expect(owner.finishOpeningTask(generation))
        let replacement = try #require(owner.installOpeningTask(Task<Void, Never> {}))
        #expect(owner.finishOpeningTask(replacement))
        #expect(owner.openingTask == nil)
    }

    @Test("opening deadline expires only its exact task generation")
    func openingDeadlineOwnership() throws {
        let owner = ChatSessionPresentation(sessionID: "session-a")
        let first = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        let firstGeneration = try #require(owner.installOpeningTask(first))

        #expect(!owner.expireOpeningTask(firstGeneration &+ 1))
        #expect(owner.openingTask != nil)
        #expect(owner.expireOpeningTask(firstGeneration))
        #expect(owner.openingTaskWasCancelled(firstGeneration))
        #expect(owner.openingTask != nil)
        #expect(owner.installOpeningTask(Task<Void, Never> {}) == nil)
        #expect(owner.finishOpeningTask(firstGeneration))

        let replacement = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        let replacementGeneration = try #require(owner.installOpeningTask(replacement))
        #expect(!owner.openingTaskWasCancelled(replacementGeneration))
        #expect(!owner.expireOpeningTask(firstGeneration))
        #expect(owner.openingTask != nil)
        owner.cancelOpeningTask()
        #expect(owner.finishOpeningTask(replacementGeneration))
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

        let failed = ChatSessionPresentation(sessionID: "session-c")
        let failedEpoch = failed.open.begin()
        let didFail = failed.open.fail(
            sessionID: "session-c", epoch: failedEpoch, message: "timeout"
        )
        #expect(didFail)
        #expect(!failed.needsOpeningResume)
        #expect(failed.shouldBeginOpening(retryingFailure: true))
        let retiring = Task<Void, Never> {}
        let retiringGeneration = failed.installOpeningTask(retiring)!
        failed.cancelOpeningTask()
        #expect(!failed.shouldBeginOpening(retryingFailure: true))
        #expect(failed.finishOpeningTask(retiringGeneration))
        #expect(!failed.needsOpeningResume)
        #expect(failed.shouldBeginOpening(retryingFailure: true))
    }

    @Test("a drained cancelled opening publishes a new surface-task edge")
    func drainedOpeningPublishesResumeEdge() async throws {
        let presentation = ChatSessionPresentation(sessionID: "session")
        _ = presentation.open.begin()
        let task = Task<Void, Never> {}
        let generation = try #require(presentation.installOpeningTask(task))
        await task.value
        let before = presentation.openingTaskRevision
        #expect(presentation.finishOpeningTask(generation))
        #expect(presentation.openingTaskRevision == before + 1)
        #expect(presentation.needsOpeningResume)
        #expect(ChatOpeningSurfaceTaskID(
            surfaceActive: true,
            openingTaskRevision: presentation.openingTaskRevision
        ) != ChatOpeningSurfaceTaskID(surfaceActive: true, openingTaskRevision: before))
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
