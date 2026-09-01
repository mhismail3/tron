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
        #expect(!reopened.permitsExtensionInteractionPresentation)
        #expect(reopened.requestedInteractionScope == nil)
        #expect(reopened.suppressedInteractionScope == nil)
    }

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

        #expect(!owner.finishOpeningTask(generation &+ 1))
        #expect(owner.openingTask != nil)
        owner.cancelOpeningTask()
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
        #expect(owner.openingTask != nil)
        #expect(owner.installOpeningTask(Task<Void, Never> {}) == nil)
        #expect(owner.finishOpeningTask(firstGeneration))

        let replacement = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        let replacementGeneration = try #require(owner.installOpeningTask(replacement))
        #expect(!owner.expireOpeningTask(firstGeneration))
        #expect(owner.openingTask != nil)
        owner.cancelOpeningTask()
        #expect(owner.finishOpeningTask(replacementGeneration))
    }

    @Test("opening attempts fail closed only while unsettled")
    func openingAttemptSettlementPolicy() {
        #expect(ChatOpeningAttemptPolicy.deadline == .seconds(30))
        #expect(ChatOpeningAttemptPolicy.isUnsettled(.opening))
        #expect(ChatOpeningAttemptPolicy.isUnsettled(.positioning))
        #expect(!ChatOpeningAttemptPolicy.isUnsettled(.ready))
        #expect(!ChatOpeningAttemptPolicy.isUnsettled(.failed("retry")))
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

    @Test("fork navigation advances once through every nested dismissal owner")
    func forkNavigationOwnership() throws {
        var confirmation = ChatForkNavigationOwner()
        var historySelection = ChatForkNavigationOwner()
        var historySheet = ChatForkNavigationOwner()
        var contextSheet = ChatForkNavigationOwner()
        let route = AppModel.SessionNavigationRoute(sessionID: "fork", editorText: "draft")

        confirmation.stage(route)
        #expect(!contextSheet.hasPendingRoute)
        let afterConfirmation = confirmation.consume()
        historySelection.stage(try #require(afterConfirmation))
        #expect(confirmation.consume() == nil)
        let afterSelection = historySelection.consume()
        historySheet.stage(try #require(afterSelection))
        #expect(!contextSheet.hasPendingRoute)
        let afterHistory = historySheet.consume()
        contextSheet.stage(try #require(afterHistory))
        #expect(contextSheet.consume() == route)
        #expect(contextSheet.consume() == nil)
    }

    @Test("session visibility follows synchronized foreground lineage, not ready-frame timing")
    func sessionVisibilityPolicy() {
        #expect(ChatSessionVisibilityPolicy.isVisible(
            sceneActive: true,
            surfaceActive: true,
            hasMountedAuthority: true
        ))
        #expect(ChatSessionVisibilityPolicy.isVisible(
            sceneActive: true,
            surfaceActive: PresentationSurfaceActivity.presentingDescendant.allowsDataPublication,
            hasMountedAuthority: true
        ))
        #expect(!ChatSessionVisibilityPolicy.isVisible(
            sceneActive: false,
            surfaceActive: true,
            hasMountedAuthority: true
        ))
        #expect(!ChatSessionVisibilityPolicy.isVisible(
            sceneActive: true,
            surfaceActive: false,
            hasMountedAuthority: true
        ))
        #expect(!ChatSessionVisibilityPolicy.isVisible(
            sceneActive: true,
            surfaceActive: true,
            hasMountedAuthority: false
        ))
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
