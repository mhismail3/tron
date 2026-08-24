import SwiftUI
import Testing
@testable import TronMobile

@MainActor
@Suite("Chat viewport behavior")
struct ChatScrollCoordinatorTests {
    private let bottom = ChatTranscriptGeometry(
        offsetY: 600, contentHeight: 1_000, containerHeight: 400
    )
    private let away = ChatTranscriptGeometry(
        offsetY: 300, contentHeight: 1_000, containerHeight: 400
    )
    private let farAway = ChatTranscriptGeometry(
        offsetY: 0, contentHeight: 1_000, containerHeight: 400
    )

    @Test("stale command application cannot authorize a target release")
    func staleCommandCannotApply() throws {
        let coordinator = ChatScrollCoordinator()
        coordinator.geometryChanged(previous: .zero, current: farAway)
        coordinator.requestCatchUp(reduceMotion: true)
        let first = try #require(coordinator.command)
        #expect(coordinator.commandApplied(first))
        coordinator.requestCatchUp(reduceMotion: true)
        let second = try #require(coordinator.command)
        #expect(!coordinator.commandApplied(first))
        #expect(coordinator.command?.token == second.token)
    }

    @Test("application target survives until exact catch-up geometry settles")
    func targetReleaseIsSettlementOwned() async throws {
        let frames = ManualViewportFrameScheduler()
        let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
        coordinator.geometryChanged(previous: .zero, current: farAway)
        coordinator.requestCatchUp(reduceMotion: true)
        let command = try #require(coordinator.command)
        #expect(coordinator.commandApplied(command))
        #expect(!coordinator.consumeTargetRelease())

        coordinator.geometryChanged(previous: farAway, current: bottom)
        await frames.waitForRequest(count: 1)
        #expect(coordinator.targetReleaseGeneration == 0)
        frames.releaseNext()
        await Task.yield()

        #expect(coordinator.targetReleaseGeneration == 1)
        #expect(coordinator.consumeTargetRelease())
        #expect(!coordinator.consumeTargetRelease())
    }

    @Test("submission retires only the applied app target before layout mutation")
    func submissionRetiresAppliedTarget() throws {
        let coordinator = ChatScrollCoordinator()
        coordinator.geometryChanged(previous: .zero, current: farAway)
        coordinator.requestCatchUp(reduceMotion: true)
        let command = try #require(coordinator.command)
        #expect(coordinator.commandApplied(command))
        #expect(coordinator.retireAppliedTargetForSubmission())
        #expect(!coordinator.retireAppliedTargetForSubmission())
        #expect(coordinator.targetReleaseGeneration == 0)
        #expect(!coordinator.consumeTargetRelease())
    }

    // MARK: Group B replacements — deleted command-arbitration mechanisms

    @Test("discrete pinned growth coalesces to one nonanimated tail lease")
    func pinnedNativeEdgeEliminatesFollowCommandStream() throws {
        let coordinator = ChatScrollCoordinator()
        coordinator.geometryChanged(previous: .zero, current: bottom)
        for index in 1...4 {
            let growth = ChatTranscriptGeometry(
                offsetY: 600,
                contentHeight: 1_000 + CGFloat(index * 80),
                containerHeight: 400
            )
            coordinator.geometryChanged(previous: bottom, current: growth)
            coordinator.discreteContentInserted(renderedID: "row-\(index)")
            coordinator.installedLifecycleChanged(try installedToolTranscript(
                ids: ["tool"], statuses: [.running], timelineGeneration: index
            ))
            #expect(coordinator.command?.origin == .pinnedGrowth)
            #expect(coordinator.command?.destination == .tail)
            #expect(coordinator.command?.animation == .disabled)
            #expect(coordinator.command?.token == 1)
        }
        #expect(coordinator.viewportMode == .pinned)
    }

    @Test("anchored restore waits for fresh semantic and geometry evidence")
    func anchoredRestoreRequiresFreshEvidence() throws {
        let initial = try installedToolTranscript(
            ids: ["tool"], statuses: [.running], timelineGeneration: 1
        )
        let row = try #require(initial.timeline.ids.first)
        let semantic = try #require(initial.timeline.preferredSemanticIDByRenderedID[row])
        let coordinator = detachedCoordinator(at: away)
        coordinator.semanticFrameChanged(
            renderedID: row,
            layoutEpoch: coordinator.layoutEpoch,
            frame: CGRect(x: 0, y: 24, width: 100, height: 30)
        )
        coordinator.transcriptProjectionWillChange(from: initial)
        let replacement = try installedToolTranscript(
            ids: ["tool"], statuses: [.running], timelineGeneration: 2
        )
        coordinator.installedTranscriptChanged(replacement)
        #expect(coordinator.command == nil)

        let replacementRow = try #require(replacement.timeline.renderedIDBySemanticID[semantic])
        coordinator.semanticFrameChanged(
            renderedID: replacementRow,
            layoutEpoch: coordinator.layoutEpoch,
            frame: CGRect(x: 0, y: 84, width: 100, height: 30)
        )
        #expect(coordinator.command == nil)
        coordinator.geometryChanged(previous: away, current: away)
        #expect(coordinator.command?.origin == .layout)
        #expect(coordinator.command?.destination == .offsetY(360))
    }

    @Test("semantic restore deadline retires missing layout evidence")
    func semanticRestoreDeadline() async throws {
        try await withTestWatchdog { @MainActor in
            let clock = ManualClock()
            let initial = try installedToolTranscript(
                ids: ["tool"], statuses: [.running], timelineGeneration: 1
            )
            let row = try #require(initial.timeline.ids.first)
            let coordinator = ChatScrollCoordinator(clock: clock.clock)
            coordinator.geometryChanged(previous: .zero, current: away)
            coordinator.scrollPositionChanged(isPositionedByUser: true)
            coordinator.semanticFrameChanged(
                renderedID: row,
                layoutEpoch: coordinator.layoutEpoch,
                frame: CGRect(x: 0, y: 24, width: 100, height: 30)
            )
            coordinator.transcriptProjectionWillChange(from: initial)
            try await clock.waitUntilSleeping(count: 1)
            clock.advance(by: .seconds(1))
            await Task.yield()

            coordinator.installedTranscriptChanged(try installedToolTranscript(
                ids: ["tool"], statuses: [.completed], timelineGeneration: 2
            ))
            coordinator.geometryChanged(previous: away, current: away)
            #expect(coordinator.command == nil)
        }
    }

    @Test("explicit prepend supersedes a pending semantic-restore command")
    func prependSupersedesRestoreCommand() throws {
        let initial = try installedToolTranscript(
            ids: ["tool"], statuses: [.running], timelineGeneration: 1
        )
        let row = try #require(initial.timeline.ids.first)
        let coordinator = detachedCoordinator(at: away)
        coordinator.semanticFrameChanged(
            renderedID: row,
            layoutEpoch: coordinator.layoutEpoch,
            frame: CGRect(x: 0, y: 24, width: 100, height: 30)
        )
        coordinator.transcriptProjectionWillChange(from: initial)
        let replacement = try installedToolTranscript(
            ids: ["tool"], statuses: [.running], timelineGeneration: 2
        )
        coordinator.installedTranscriptChanged(replacement)
        let replacementRow = try #require(replacement.timeline.ids.first)
        coordinator.semanticFrameChanged(
            renderedID: replacementRow,
            layoutEpoch: coordinator.layoutEpoch,
            frame: CGRect(x: 0, y: 84, width: 100, height: 30)
        )
        coordinator.geometryChanged(previous: away, current: away)
        #expect(coordinator.command?.origin == .layout)

        let began = coordinator.beginPrepend(
            anchor: nil,
            load: { @MainActor @Sendable in nil },
            completion: { @MainActor _ in }
        )
        #expect(!began)
        #expect(coordinator.command == nil)
    }

    @Test("direct takeover cancels semantic restore without a release command")
    func directTakeoverCancelsPendingSemanticRestore() throws {
        let initial = try installedToolTranscript(
            ids: ["tool"], statuses: [.running], timelineGeneration: 1
        )
        let row = try #require(initial.timeline.ids.first)
        let coordinator = detachedCoordinator(at: away)
        coordinator.semanticFrameChanged(
            renderedID: row,
            layoutEpoch: coordinator.layoutEpoch,
            frame: CGRect(x: 0, y: 20, width: 100, height: 30)
        )
        coordinator.transcriptProjectionWillChange(from: initial)
        coordinator.installedTranscriptChanged(try installedToolTranscript(
            ids: ["tool"], statuses: [.completed], timelineGeneration: 2
        ))
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(previous: away, current: away)
        #expect(coordinator.viewportMode == .anchored)
        #expect(coordinator.command == nil)
    }

    @Test("sticky pinned mode uses one tail lease while anchored mode remains inert")
    func stickyModeHasNoOffsetCommandDestination() {
        let coordinator = ChatScrollCoordinator()
        coordinator.submitted()
        coordinator.discreteContentInserted(renderedID: "row")
        coordinator.geometryChanged(
            previous: bottom,
            current: ChatTranscriptGeometry(
                offsetY: 600, contentHeight: 1_120, containerHeight: 320, bottomInset: 80
            )
        )
        #expect(coordinator.viewportMode == .pinned)
        #expect(coordinator.command?.origin == .pinnedGrowth)
        #expect(coordinator.command?.destination == .tail)

        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.submitted()
        #expect(coordinator.viewportMode == .anchored)
        #expect(coordinator.command == nil)
    }

    @Test("submission corrects only a pinned reader and leaves anchored layout inert")
    func composerMutationsDoNotOwnScrollCommands() {
        let coordinator = ChatScrollCoordinator()
        coordinator.submitted()
        coordinator.geometryChanged(previous: bottom, current: away)
        #expect(coordinator.viewportMode == .pinned)
        #expect(coordinator.command?.origin == .pinnedGrowth)
        #expect(coordinator.command?.destination == .tail)

        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.submitted()
        coordinator.viewportChanged(
            previous: away,
            current: ChatTranscriptGeometry(
                offsetY: 300, contentHeight: 1_000, containerHeight: 320, bottomInset: 80
            )
        )
        #expect(coordinator.viewportMode == .anchored)
        #expect(coordinator.command == nil)
    }

    // MARK: Group A — preserved user-visible outcomes

    @Test("detached projection topology change preserves a fresh surviving semantic anchor")
    func detachedProjectionMutationPreservesAnchor() throws {
        try anchoredRestoreRequiresFreshEvidence()
    }

    @Test("pinned and detached shrink geometry emits no automatic write")
    func shrinkIsInert() {
        let shrink = ChatTranscriptGeometry(
            offsetY: 500, contentHeight: 900, containerHeight: 400
        )
        let pinned = ChatScrollCoordinator()
        pinned.geometryChanged(previous: bottom, current: shrink)
        #expect(pinned.command == nil)
        let detached = detachedCoordinator(at: away)
        detached.geometryChanged(previous: away, current: shrink)
        #expect(detached.command == nil)
    }

    @Test("ordinary shrink is inert while pinned and detached overshoot stays native-owned")
    func shrinkAndOvershootOwnership() {
        let overshoot = ChatTranscriptGeometry(
            offsetY: 900,
            contentHeight: 900,
            containerHeight: 400,
            visibleTopY: 900,
            visibleBottomY: 1_300
        )
        let pinned = ChatScrollCoordinator()
        pinned.geometryChanged(previous: bottom, current: overshoot)
        #expect(pinned.viewportMode == .pinned)
        #expect(pinned.command == nil)
        let detached = detachedCoordinator(at: away)
        detached.geometryChanged(previous: away, current: overshoot)
        #expect(detached.viewportMode == .anchored)
        #expect(detached.command == nil)
    }

    @Test("phase-only overshoot and direct rubber-band both avoid app writes")
    func phaseOnlyOvershootRespectsOwnership() {
        let overshoot = ChatTranscriptGeometry(
            offsetY: 900, contentHeight: 900, containerHeight: 400
        )
        let automatic = ChatScrollCoordinator()
        automatic.scrollPhaseChanged(from: .animating, to: .idle, finalGeometry: overshoot)
        #expect(automatic.command == nil)
        let direct = ChatScrollCoordinator()
        direct.scrollPhaseChanged(from: .interacting, to: .decelerating, finalGeometry: overshoot)
        #expect(direct.viewportMode == .anchored)
        #expect(direct.command == nil)
    }

    @Test("detached composer transitions preserve reader ownership and issue no tail command")
    func detachedComposerStructuralTransition() {
        let coordinator = detachedCoordinator(at: away)
        coordinator.submitted()
        coordinator.viewportChanged(
            previous: away,
            current: ChatTranscriptGeometry(
                offsetY: 300, contentHeight: 1_000, containerHeight: 320, bottomInset: 80
            )
        )
        #expect(coordinator.viewportMode == .anchored)
        #expect(coordinator.command == nil)
    }

    @Test("upward interaction publishes catch-up immediately")
    func upwardInteractionPublishesCatchUpImmediately() {
        let coordinator = ChatScrollCoordinator()
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: away)
        #expect(coordinator.shouldShowCatchUpButton)
        #expect(coordinator.viewportMode == .anchored)
    }

    @Test("geometry and native ownership callback permutations both detach")
    func callbackOrdering() {
        let geometryFirst = ChatScrollCoordinator()
        geometryFirst.geometryChanged(previous: bottom, current: away)
        geometryFirst.scrollPositionChanged(isPositionedByUser: true)
        let ownershipFirst = ChatScrollCoordinator()
        ownershipFirst.scrollPositionChanged(isPositionedByUser: true)
        ownershipFirst.geometryChanged(previous: bottom, current: away)
        #expect(geometryFirst.viewportMode == .anchored)
        #expect(ownershipFirst.viewportMode == .anchored)
        #expect(geometryFirst.command == ownershipFirst.command)
    }

    @Test("geometry-first manual return to tail immediately clears catch-up state")
    func geometryFirstManualReturnClearsCatchUp() {
        assertManualTailReturn(after: { coordinator in
            coordinator.geometryChanged(previous: self.away, current: self.bottom)
        })
    }

    @Test("manual return to tail remains pinned through keyboard viewport contraction")
    func manualReturnThenKeyboardFollowsTail() {
        let coordinator = detachedCoordinator(at: away)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle, finalGeometry: bottom)
        coordinator.viewportChanged(
            previous: bottom,
            current: ChatTranscriptGeometry(
                offsetY: 600, contentHeight: 1_000, containerHeight: 320, bottomInset: 80
            )
        )
        #expect(coordinator.viewportMode == .pinned)
        #expect(!coordinator.hasUnreadContent)
        #expect(coordinator.command == nil)
    }

    @Test("direct mixed viewport geometry return to tail clears catch-up")
    func mixedViewportManualReturnClearsCatchUp() {
        assertManualTailReturn(after: { coordinator in
            coordinator.viewportChanged(previous: self.away, current: self.bottom)
        })
    }

    @Test("active keyboard viewport settlement without content motion preserves detachment")
    func activeKeyboardViewportDoesNotRepin() {
        let coordinator = detachedCoordinator(at: away)
        let keyboard = ChatTranscriptGeometry(
            offsetY: 300, contentHeight: 1_000, containerHeight: 320, bottomInset: 80
        )
        coordinator.viewportChanged(previous: away, current: keyboard)
        coordinator.scrollPhaseChanged(from: .animating, to: .idle, finalGeometry: keyboard)
        #expect(coordinator.viewportMode == .anchored)
        #expect(coordinator.command == nil)
    }

    @Test("detached stream viewport composer and image-like settlement emit zero writes")
    func detachedLayoutNeverWrites() {
        let coordinator = detachedCoordinator(at: away)
        coordinator.submitted()
        coordinator.discreteContentInserted(renderedID: "image")
        coordinator.geometryChanged(
            previous: away,
            current: ChatTranscriptGeometry(
                offsetY: 300, contentHeight: 1_180, containerHeight: 320, bottomInset: 80
            )
        )
        #expect(coordinator.viewportMode == .anchored)
        #expect(coordinator.command == nil)
    }

    @Test("viewport expansion and later unattributed boundary settlement preserve detachment")
    func viewportExpansionPreservesDetachment() {
        let coordinator = detachedCoordinator(at: away)
        let expanded = ChatTranscriptGeometry(
            offsetY: 300, contentHeight: 1_000, containerHeight: 700
        )
        coordinator.viewportChanged(previous: away, current: expanded)
        coordinator.geometryChanged(previous: expanded, current: expanded)
        #expect(coordinator.viewportMode == .anchored)
        #expect(coordinator.command == nil)
    }

    @Test("native ownership end and accessibility phase preserve one-shot direct tail return")
    func directTailReturnAdmission() {
        let coordinator = detachedCoordinator(at: away)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle, finalGeometry: bottom)
        let generation = coordinator.tailSettlementGeneration
        coordinator.scrollPhaseChanged(from: .idle, to: .idle, finalGeometry: bottom)
        #expect(coordinator.viewportMode == .pinned)
        #expect(coordinator.tailSettlementGeneration == generation)
    }

    @Test("long catch-up stages and finishes on separate display frames")
    func catchUpFrameSeparation() async throws {
        try await withTestWatchdog { @MainActor in
            let frames = ManualViewportFrameScheduler()
            let coordinator = self.detachedCoordinator(at: self.farAway, frames: frames)
            coordinator.requestCatchUp(reduceMotion: false)
            let staged = try #require(coordinator.command)
            guard case .offsetY = staged.destination else {
                Issue.record("expected staged point command")
                return
            }
            coordinator.commandApplied(staged)
            await frames.waitForRequest(count: 1)
            #expect(coordinator.command == nil)
            frames.releaseNext()
            let final = try await coordinator.hostedNextCommand()
            #expect(final.destination == .tail)
            #expect(final.animation == .smooth(duration: 0.30))
        }
    }

    @Test("response during staged catch-up survives interruption as unread")
    func stagedCatchUpInterruption() {
        let coordinator = detachedCoordinator(at: farAway, withUnread: false)
        coordinator.requestCatchUp(reduceMotion: false)
        #expect(coordinator.command?.origin == .catchUp)
        coordinator.semanticResponseArrived()
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        #expect(coordinator.viewportMode == .anchored)
        #expect(coordinator.hasUnreadContent)
        #expect(coordinator.command == nil)
    }

    @Test("response during final catch-up command survives interruption as unread")
    func finalCatchUpInterruption() {
        let coordinator = detachedCoordinator(at: away, withUnread: false)
        coordinator.requestCatchUp(reduceMotion: false)
        #expect(coordinator.command?.destination == .tail)
        coordinator.semanticResponseArrived()
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: away)
        #expect(coordinator.viewportMode == .anchored)
        #expect(coordinator.hasUnreadContent)
        #expect(coordinator.command == nil)
    }

    @Test("interaction during catch-up settlement restores detachment; exact boundary settles")
    func settlingCatchUpInterruptionAndSuccess() throws {
        let interrupted = detachedCoordinator(at: away)
        interrupted.requestCatchUp(reduceMotion: true)
        interrupted.commandApplied(try #require(interrupted.command))
        interrupted.scrollPositionChanged(isPositionedByUser: true)
        #expect(interrupted.viewportMode == .anchored)
        #expect(interrupted.hasUnreadContent)

        let settled = detachedCoordinator(at: away)
        settled.requestCatchUp(reduceMotion: true)
        settled.commandApplied(try #require(settled.command))
        settled.geometryChanged(previous: away, current: bottom)
        #expect(settled.viewportMode == .pinned)
        #expect(!settled.hasUnreadContent)
    }

    @Test("presentation reset revokes an unacknowledged opening command")
    func presentationResetRevokesCommand() async {
        let frames = ManualViewportFrameScheduler()
        let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
        coordinator.resetForPresentation(1)
        coordinator.requestOpeningTail(targetRenderedID: "old-tail")
        await frames.waitForRequest(count: 1)
        frames.releaseNext()
        await Task.yield()
        #expect(coordinator.command?.presentation == 1)
        coordinator.resetForPresentation(2)
        #expect(coordinator.command == nil)
        #expect(coordinator.viewportMode == .pinned)
    }

    @Test("same-session presentation handoff reconciles physical tail without moving a reader")
    func retainedPresentationHandoffReconcilesViewport() {
        let reader = detachedCoordinator(at: away)
        reader.resetForPresentation(2, retainingVisibleViewport: true)
        reader.geometryChanged(previous: away, current: away)
        #expect(reader.viewportMode == .anchored)
        #expect(!reader.isAtBottom)
        #expect(reader.command == nil)

        let tail = detachedCoordinator(at: away)
        tail.resetForPresentation(2, retainingVisibleViewport: true)
        tail.geometryChanged(previous: away, current: .zero)
        #expect(tail.viewportMode == .anchored)
        #expect(!tail.isAtBottom)
        tail.geometryChanged(previous: .zero, current: bottom)
        #expect(tail.viewportMode == .pinned)
        #expect(tail.isAtBottom)
        #expect(tail.command == nil)
    }

    @Test("opening tail opaque fallback defaults to 750 milliseconds")
    func openingTailDefaultTimeout() {
        #expect(ChatScrollCoordinator.defaultOpeningTailTimeout == .milliseconds(750))
    }

    @Test("opening timeout reveals after one exact-ID attempt when geometry disappears")
    func openingTailTimeoutFallsBackToExactTail() async throws {
        try await assertOpeningTimeout(target: "missing-tail", reveals: true)
    }

    @Test("opening timeout clears a published command before delayed application")
    func openingTimeoutClearsDelayedCommand() async throws {
        try await withTestWatchdog { @MainActor in
            let clock = ManualClock()
            let frames = ManualViewportFrameScheduler()
            let coordinator = ChatScrollCoordinator(
                frameScheduler: frames.scheduler,
                clock: clock.clock,
                openingTailTimeout: .seconds(1)
            )
            coordinator.requestOpeningTail(targetRenderedID: "tail")
            await frames.waitForRequest(count: 1)
            frames.releaseNext()
            await Task.yield()
            #expect(coordinator.command != nil)
            try await clock.waitUntilSleeping(count: 1)
            clock.advance(by: .seconds(1))
            await Task.yield()
            #expect(coordinator.command == nil)
        }
    }

    @Test("physical opening proof clears a published command before delayed application")
    func physicalOpeningClearsDelayedCommand() async throws {
        try await withTestWatchdog { @MainActor in
            let frames = ManualViewportFrameScheduler()
            let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
            let positioning = Task {
                await coordinator.positionOpeningTail(targetRenderedID: "tail")
            }
            await frames.waitForRequest(count: 1)
            frames.releaseNext()
            _ = try await coordinator.hostedNextCommand()
            #expect(coordinator.command != nil)

            coordinator.semanticFrameChanged(
                renderedID: "tail",
                layoutEpoch: coordinator.layoutEpoch,
                frame: CGRect(x: 0, y: 350, width: 100, height: 40)
            )
            coordinator.geometryChanged(previous: .zero, current: self.bottom)

            #expect(await positioning.value)
            #expect(coordinator.command == nil)
            coordinator.cancel()
        }
    }

    @Test("opening timeout keeps native pinning through reveal and stable frames")
    func openingTailTimeoutRevealsThenSettles() async throws {
        try await withTestWatchdog { @MainActor in
            let clock = ManualClock()
            let frames = ManualViewportFrameScheduler()
            let coordinator = ChatScrollCoordinator(
                frameScheduler: frames.scheduler,
                clock: clock.clock,
                openingTailTimeout: .seconds(1)
            )
            let positioning = Task {
                await coordinator.positionOpeningTail(targetRenderedID: "tail")
            }
            try await clock.waitUntilSleeping(count: 1)
            clock.advance(by: .seconds(1))
            #expect(await positioning.value)
            let baseline = frames.requestCount
            coordinator.openingRevealCompleted()
            await frames.waitForRequest(count: baseline + 1)
            frames.releaseNext()
            await frames.waitForRequest(count: baseline + 2)
            frames.releaseNext()
            await coordinator.waitForOpeningTailSettlement()
            #expect(coordinator.viewportMode == .pinned)
            #expect(coordinator.command == nil)
        }
    }

    @Test("best-effort timeout settles after two reveal frames without later geometry")
    func openingTailBestEffortReleaseWithoutGeometry() async throws {
        try await openingTailTimeoutRevealsThenSettles()
    }

    @Test("physical positioning cancels the deadline before reveal settlement")
    func openingTailDeadlineEndsAtPhysicalPositioning() async throws {
        try await withTestWatchdog { @MainActor in
            let clock = ManualClock()
            let coordinator = ChatScrollCoordinator(clock: clock.clock, openingTailTimeout: .seconds(1))
            let task = Task { await coordinator.positionOpeningTail(targetRenderedID: "tail") }
            coordinator.semanticFrameChanged(
                renderedID: "tail", layoutEpoch: coordinator.layoutEpoch,
                frame: CGRect(x: 0, y: 350, width: 100, height: 40)
            )
            coordinator.geometryChanged(previous: .zero, current: self.bottom)
            #expect(await task.value)
            #expect(clock.activeSleeperCount() == 0)
            coordinator.cancel()
        }
    }

    @Test("unrealized opening tail receives one frame-gated correction and physical proof")
    func openingTailCorrectsUnrealizedTarget() async throws {
        try await withTestWatchdog { @MainActor in
            let frames = ManualViewportFrameScheduler()
            let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
            let task = Task { await coordinator.positionOpeningTail(targetRenderedID: "tail") }
            await frames.waitForRequest(count: 1)
            frames.releaseNext()
            let command = try await coordinator.hostedNextCommand()
            #expect(command.destination == .openingTail("tail"))
            #expect(command.animation == .disabled)
            coordinator.commandApplied(command)
            coordinator.semanticFrameChanged(
                renderedID: "tail", layoutEpoch: coordinator.layoutEpoch,
                frame: CGRect(x: 0, y: 350, width: 100, height: 40)
            )
            coordinator.geometryChanged(previous: .zero, current: self.bottom)
            #expect(await task.value)
            coordinator.cancel()
        }
    }

    @Test("opening phase owns submission, insertion, projection, and pinned overshoot")
    func openingPhaseSuppressesOrdinaryTailWork() throws {
        let coordinator = ChatScrollCoordinator()
        coordinator.requestOpeningTail(targetRenderedID: "tail")
        coordinator.submitted()
        coordinator.discreteContentInserted(renderedID: "row")
        coordinator.installedLifecycleChanged(try installedToolTranscript(
            ids: ["tool"], statuses: [.running], timelineGeneration: 1
        ))
        coordinator.geometryChanged(previous: .zero, current: away)
        #expect(!coordinator.canAutomaticallyFollow)
        #expect(coordinator.command == nil)
        coordinator.cancel()
    }

    @Test("opening tail admits exact physical evidence in either callback order")
    func openingTailExactEvidencePermutations() async {
        let geometryFirst = ChatScrollCoordinator()
        geometryFirst.requestOpeningTail(targetRenderedID: "tail")
        geometryFirst.geometryChanged(previous: .zero, current: bottom)
        geometryFirst.semanticFrameChanged(
            renderedID: "tail", layoutEpoch: geometryFirst.layoutEpoch,
            frame: CGRect(x: 0, y: 350, width: 100, height: 40)
        )
        #expect(geometryFirst.command == nil)

        let frameFirst = ChatScrollCoordinator()
        frameFirst.requestOpeningTail(targetRenderedID: "tail")
        frameFirst.semanticFrameChanged(
            renderedID: "tail", layoutEpoch: frameFirst.layoutEpoch,
            frame: CGRect(x: 0, y: 350, width: 100, height: 40)
        )
        frameFirst.geometryChanged(previous: .zero, current: bottom)
        #expect(frameFirst.command == nil)
        geometryFirst.cancel(); frameFirst.cancel()
    }

    @Test("opening tail leaves undersized and empty transcripts top aligned")
    func openingTailClearsForUndersizedOrEmptyTimeline() async {
        let coordinator = ChatScrollCoordinator()
        #expect(await coordinator.positionOpeningTail(targetRenderedID: nil))
        #expect(coordinator.command == nil)
        #expect(coordinator.viewportMode == .pinned)
        let short = ChatTranscriptGeometry(offsetY: 0, contentHeight: 180, containerHeight: 400)
        coordinator.geometryChanged(previous: .zero, current: short)
        #expect(coordinator.command == nil)
    }

    @Test("native interaction cancels exact pending opening tail")
    func nativeInteractionCancelsOpeningTail() async {
        let frames = ManualViewportFrameScheduler()
        let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
        coordinator.requestOpeningTail(targetRenderedID: "tail")
        await frames.waitForRequest(count: 1)
        frames.releaseNext()
        await Task.yield()
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        #expect(coordinator.viewportMode == .anchored)
        #expect(coordinator.command == nil)
    }

    @Test("stale opening target cannot repin a replacement presentation")
    func staleOpeningLayoutCannotRepinReplacement() async {
        let frames = ManualViewportFrameScheduler()
        let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
        coordinator.resetForPresentation(1)
        let staleEpoch = coordinator.layoutEpoch
        coordinator.requestOpeningTail(targetRenderedID: "stale")
        coordinator.resetForPresentation(2, retainingVisibleViewport: true)
        coordinator.semanticFrameChanged(
            renderedID: "stale", layoutEpoch: staleEpoch,
            frame: CGRect(x: 0, y: 350, width: 100, height: 40)
        )
        coordinator.geometryChanged(previous: .zero, current: bottom)
        #expect(coordinator.command == nil)
        #expect(coordinator.viewportMode == .pinned)
    }

    @Test("semantic frame projection is count bounded")
    func semanticFramesAreBounded() {
        let coordinator = ChatScrollCoordinator()
        for index in 0..<300 {
            coordinator.semanticFrameChanged(
                renderedID: "row-\(index)", layoutEpoch: coordinator.layoutEpoch,
                frame: CGRect(x: 0, y: index, width: 100, height: 20)
            )
        }
        #expect(coordinator.hostedSemanticFrameCount == 256)
    }

    @Test("Reduce Motion catch-up is one nonanimated tail command")
    func reduceMotionCatchUp() throws {
        let coordinator = detachedCoordinator(at: away)
        coordinator.requestCatchUp(reduceMotion: true)
        let command = try #require(coordinator.command)
        #expect(command.destination == .tail)
        #expect(command.animation == .disabled)
        coordinator.commandApplied(command)
        coordinator.geometryChanged(previous: away, current: bottom)
        #expect(coordinator.command == nil)
        #expect(coordinator.viewportMode == .pinned)
    }

    @Test("prepend growth cannot arm a later automatic tail follow")
    func prependGrowthDoesNotFollowTail() async throws {
        try await withTestWatchdog { @MainActor in
            let recorder = ResultRecorder()
            let coordinator = self.prependReadyCoordinator()
            let anchor = self.anchor(for: coordinator)
            let began = coordinator.beginPrepend(
                anchor: anchor,
                load: {
                    let epoch = coordinator.beginInstalledLayoutEpoch()
                    return ChatPrependPage(renderedAnchorID: "row", installedLayout: epoch)
                },
                completion: recorder.record
            )
            #expect(began)
            try await coordinator.hostedWaitForPrependSemanticSample()
            coordinator.discreteContentInserted(renderedID: "new")
            coordinator.geometryChanged(previous: self.away, current: self.away)
            #expect(coordinator.command == nil)
        }
    }

    @Test("missing measured anchor discards without starting page load")
    func missingAnchorDoesNotLoad() {
        let recorder = ResultRecorder()
        let loadCount = Counter()
        let coordinator = ChatScrollCoordinator()
        let began = coordinator.beginPrepend(
            anchor: nil,
            load: { loadCount.value += 1; return nil },
            completion: recorder.record
        )
        #expect(!began)
        #expect(loadCount.value == 0)
        #expect(recorder.values == [.discarded])
    }

    @Test("prepend cannot overwrite catch-up command ownership")
    func prependRejectsCatchUpOverlap() throws {
        let coordinator = prependReadyCoordinator()
        coordinator.requestCatchUp(reduceMotion: true)
        let catchUp = try #require(coordinator.command)
        let recorder = ResultRecorder()
        let began = coordinator.beginPrepend(
            anchor: anchor(for: coordinator), load: { nil }, completion: recorder.record
        )
        #expect(!began)
        #expect(coordinator.command == catchUp)
    }

    @Test("prepend cannot overlap opening-tail settlement")
    func prependRejectsOpeningOverlap() {
        let coordinator = prependReadyCoordinator()
        coordinator.requestOpeningTail(targetRenderedID: "tail")
        let recorder = ResultRecorder()
        let began = coordinator.beginPrepend(
            anchor: anchor(for: coordinator), load: { nil }, completion: recorder.record
        )
        #expect(!began)
        #expect(recorder.values == [.discarded])
        coordinator.cancel()
    }

    @Test("repeat prepend cannot cancel useful work")
    func prependOwnership() {
        let coordinator = prependReadyCoordinator()
        let first = ResultRecorder()
        let firstBegan = coordinator.beginPrepend(
            anchor: anchor(for: coordinator),
            load: { try? await Task.sleep(for: .seconds(1)); return nil },
            completion: first.record
        )
        #expect(firstBegan)
        let second = ResultRecorder()
        let secondBegan = coordinator.beginPrepend(
            anchor: anchor(for: coordinator), load: { nil }, completion: second.record
        )
        #expect(!secondBegan)
        #expect(coordinator.isPrependingHistory)
        #expect(second.values == [.discarded])
        coordinator.cancel()
    }

    @Test("prepend passively waits for newer exact-epoch semantic samples after every correction")
    func prependEpochAndLateCorrection() async throws {
        try await withTestWatchdog { @MainActor in
            let (coordinator, recorder) = try await self.beginCorrectingPrepend()
            let first = try #require(coordinator.command)
            #expect(first.destination == .offsetY(360))
            coordinator.commandApplied(first)
            #expect(coordinator.command == nil)
            coordinator.semanticFrameChanged(
                renderedID: "row", layoutEpoch: coordinator.layoutEpoch,
                frame: CGRect(x: 0, y: 20, width: 100, height: 30)
            )
            coordinator.geometryChanged(previous: self.away, current: self.away)
            #expect(recorder.values == [.success])
            #expect(!coordinator.isPrependingHistory)
        }
    }

    @Test("prepend deadline revokes a pending correction command")
    func prependDeadlineRevokesPendingCorrection() async throws {
        try await withTestWatchdog { @MainActor in
            let clock = ManualClock()
            let recorder = ResultRecorder()
            let coordinator = self.prependReadyCoordinator(clock: clock)
            let began = coordinator.beginPrepend(
                anchor: self.anchor(for: coordinator),
                load: {
                    let epoch = coordinator.beginInstalledLayoutEpoch()
                    return ChatPrependPage(renderedAnchorID: "row", installedLayout: epoch)
                }, completion: recorder.record
            )
            #expect(began)
            try await clock.waitUntilSleeping(count: 1)
            clock.advance(by: .seconds(8))
            await recorder.waitForValue()
            #expect(recorder.values == [.failure])
            #expect(coordinator.command == nil)
        }
    }

    @Test("prepend bounded failure clears its point command")
    func prependFailureSettlesAppliedCorrection() async throws {
        try await withTestWatchdog { @MainActor in
            let (coordinator, recorder) = try await self.beginCorrectingPrepend()
            for _ in 0..<2 {
                let command = try #require(coordinator.command)
                coordinator.commandApplied(command)
                coordinator.semanticFrameChanged(
                    renderedID: "row", layoutEpoch: coordinator.layoutEpoch,
                    frame: CGRect(x: 0, y: 90, width: 100, height: 30)
                )
                coordinator.geometryChanged(previous: self.away, current: self.away)
            }
            #expect(recorder.values == [.failure])
            #expect(coordinator.command == nil)
        }
    }

    @Test("native cancellation of applied prepend publishes no stale release")
    func nativeCancellationKeepsPrependCorrectionBounded() async throws {
        let (coordinator, recorder) = try await beginCorrectingPrepend()
        #expect(coordinator.command?.origin == .prepend)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        #expect(recorder.values == [.discarded])
        #expect(coordinator.command == nil)
        #expect(coordinator.viewportMode == .anchored)
    }

    @Test("prepend admits fresh paired callbacks that arrive before page return")
    func prependSampleBeforePageReturn() async throws {
        try await withTestWatchdog { @MainActor in
            let recorder = ResultRecorder()
            let coordinator = self.prependReadyCoordinator()
            let began = coordinator.beginPrepend(
                anchor: self.anchor(for: coordinator),
                load: {
                    let epoch = coordinator.beginInstalledLayoutEpoch()
                    coordinator.semanticFrameChanged(
                        renderedID: "row", layoutEpoch: epoch.value,
                        frame: CGRect(x: 0, y: 80, width: 100, height: 30)
                    )
                    coordinator.geometryChanged(previous: self.away, current: self.away)
                    return ChatPrependPage(renderedAnchorID: "row", installedLayout: epoch)
                }, completion: recorder.record
            )
            #expect(began)
            let command = try await coordinator.hostedNextCommand()
            #expect(command.origin == .prepend)
            coordinator.cancel()
        }
    }

    @Test("prepend accepts an installed layout boundary without a native geometry delta")
    func prependInstalledLayoutBoundaryReplay() async throws {
        try await withTestWatchdog { @MainActor in
            let recorder = ResultRecorder()
            let coordinator = self.prependReadyCoordinator()
            let began = coordinator.beginPrepend(
                anchor: self.anchor(for: coordinator),
                load: {
                    let epoch = coordinator.beginInstalledLayoutEpoch()
                    return ChatPrependPage(renderedAnchorID: "row", installedLayout: epoch)
                }, completion: recorder.record
            )
            #expect(began)
            try await coordinator.hostedWaitForPrependSemanticSample()
            coordinator.semanticFrameChanged(
                renderedID: "row", layoutEpoch: coordinator.layoutEpoch,
                frame: CGRect(x: 0, y: 80, width: 100, height: 30)
            )
            coordinator.installedLayoutEpochChanged()
            #expect(coordinator.command?.origin == .prepend)
            coordinator.cancel()
        }
    }

    @Test("semantic anchor correction preserves viewport offset without total-height input")
    func semanticAnchorCorrection() {
        #expect(ChatScrollCoordinator.prependCorrectionOffset(
            currentOffsetY: 420,
            capturedViewportOffsetY: 20,
            installedFrameMinY: 92
        ) == 492)
    }

    @Test("gesture interruption synchronously suppresses pending prepend commands")
    func gestureInterruptsPrepend() async throws {
        let (coordinator, recorder) = try await beginCorrectingPrepend()
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: away)
        #expect(coordinator.command == nil)
        #expect(!coordinator.isPrependingHistory)
        #expect(recorder.values == [.discarded])
    }

    @Test("pinned streamed growth is smooth through native size-change anchoring")
    func streamedGrowthIsSmooth() {
        let coordinator = ChatScrollCoordinator()
        coordinator.geometryChanged(
            previous: bottom,
            current: ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_160, containerHeight: 400)
        )
        #expect(coordinator.viewportMode.sizeChangeAnchorIsBottom)
        #expect(coordinator.command == nil)
        #expect(ChatScrollCoordinator.liveGrowthAnimationDuration == 0.16)
    }

    @Test("new agent row receives one nonanimated pinned-tail correction")
    func insertedRowIsSmooth() {
        let coordinator = ChatScrollCoordinator()
        coordinator.discreteContentInserted(renderedID: "new-agent-row")
        coordinator.geometryChanged(
            previous: bottom,
            current: ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_100, containerHeight: 400)
        )
        #expect(coordinator.viewportMode == .pinned)
        #expect(coordinator.command?.origin == .pinnedGrowth)
        #expect(coordinator.command?.destination == .tail)
        #expect(coordinator.command?.animation == .disabled)
    }

    @Test("physical overshoot is clamped by native pinning without an animated app command")
    func overshootCorrectionIsDisabled() {
        let coordinator = ChatScrollCoordinator()
        let overshoot = ChatTranscriptGeometry(
            offsetY: 900, contentHeight: 900, containerHeight: 400
        )
        coordinator.geometryChanged(previous: bottom, current: overshoot)
        #expect(coordinator.viewportMode == .pinned)
        #expect(coordinator.command == nil)
    }

    @Test("detached reader receives no growth write")
    func detachedGrowthIsInert() {
        let coordinator = detachedCoordinator(at: away)
        coordinator.geometryChanged(
            previous: away,
            current: ChatTranscriptGeometry(offsetY: 300, contentHeight: 1_120, containerHeight: 400)
        )
        #expect(coordinator.viewportMode == .anchored)
        #expect(coordinator.command == nil)
    }

    // MARK: Helpers

    private func detachedCoordinator(
        at geometry: ChatTranscriptGeometry,
        withUnread: Bool = true,
        frames: ManualViewportFrameScheduler? = nil
    ) -> ChatScrollCoordinator {
        let coordinator = ChatScrollCoordinator(frameScheduler: frames?.scheduler ?? .displayLink)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(previous: bottom, current: geometry)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle, finalGeometry: geometry)
        if withUnread { coordinator.semanticResponseArrived() }
        return coordinator
    }

    private func assertManualTailReturn(
        after geometryUpdate: (ChatScrollCoordinator) -> Void
    ) {
        let coordinator = detachedCoordinator(at: away)
        geometryUpdate(coordinator)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle, finalGeometry: bottom)
        #expect(coordinator.viewportMode == .pinned)
        #expect(!coordinator.hasUnreadContent)
        #expect(coordinator.command == nil)
    }

    private func assertOpeningTimeout(target: String, reveals: Bool) async throws {
        try await withTestWatchdog { @MainActor in
            let clock = ManualClock()
            let coordinator = ChatScrollCoordinator(
                clock: clock.clock, openingTailTimeout: .seconds(1)
            )
            let task = Task { await coordinator.positionOpeningTail(targetRenderedID: target) }
            try await clock.waitUntilSleeping(count: 1)
            clock.advance(by: .seconds(1))
            #expect(await task.value == reveals)
            #expect(coordinator.command == nil)
            coordinator.cancel()
        }
    }

    private func prependReadyCoordinator(clock: ManualClock? = nil) -> ChatScrollCoordinator {
        let coordinator = ChatScrollCoordinator(clock: clock?.clock ?? .continuous)
        coordinator.geometryChanged(previous: .zero, current: away)
        coordinator.semanticFrameChanged(
            renderedID: "row", layoutEpoch: coordinator.layoutEpoch,
            frame: CGRect(x: 0, y: 20, width: 100, height: 30)
        )
        return coordinator
    }

    private func anchor(for coordinator: ChatScrollCoordinator) -> ChatSemanticAnchor {
        ChatSemanticAnchor(
            semanticID: "semantic", renderedID: "row",
            layoutEpoch: coordinator.layoutEpoch, viewportOffsetY: 20
        )
    }

    private func beginCorrectingPrepend() async throws -> (ChatScrollCoordinator, ResultRecorder) {
        let recorder = ResultRecorder()
        let coordinator = prependReadyCoordinator()
        let began = coordinator.beginPrepend(
            anchor: anchor(for: coordinator),
            load: {
                let epoch = coordinator.beginInstalledLayoutEpoch()
                return ChatPrependPage(renderedAnchorID: "row", installedLayout: epoch)
            }, completion: recorder.record
        )
        #expect(began)
        try await coordinator.hostedWaitForPrependSemanticSample()
        coordinator.semanticFrameChanged(
            renderedID: "row", layoutEpoch: coordinator.layoutEpoch,
            frame: CGRect(x: 0, y: 80, width: 100, height: 30)
        )
        coordinator.geometryChanged(previous: away, current: away)
        return (coordinator, recorder)
    }
}

private func installedToolTranscript(
    ids: [String],
    statuses: [ToolExecutionState.Status],
    timelineGeneration: Int
) throws -> InstalledChatTranscript {
    var snapshot = try JSONDecoder.gateway.decode(SessionSnapshot.self, from: Data("""
    {
      "sessionId":"scroll-session","runtimeGeneration":"runtime","revision":1,"eventSequence":1,"phase":"running","cwd":"/workspace",
      "model":{"provider":"test","id":"model"},"thinkingLevel":"high","availableThinkingLevels":["off","high"],
      "stats":{"userMessages":0,"assistantMessages":0,"toolCalls":0,"toolResults":0,"totalMessages":0,"tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0},"cost":0},
      "queued":{"steering":[],"followUp":[]},"transcript":[],"transcriptStart":0,"transcriptTotal":0,
      "toolExecutions":[],"extensionPresentation":{"version":2,"hostEpoch":"host","revision":0,"capabilities":[],"diagnostics":[],"semanticState":{"statuses":{},"working":{"visible":false},"widgets":[],"toolsExpanded":false,"editorRevision":0,"editorText":""},"surfaces":[],"pendingInteractions":[]},"diagnostics":[]
    }
    """.utf8))
    snapshot.eventSequence = timelineGeneration
    snapshot.toolExecutions = zip(ids, statuses).enumerated().map { index, pair in
        ToolExecutionState(
            toolCallId: pair.0, toolName: "read", order: index, status: pair.1,
            arguments: .object([:]), partialResult: nil,
            result: pair.1 == .completed ? .object(["ok": .bool(true)]) : nil,
            output: pair.1 == .completed ? "done" : nil,
            isError: false,
            startedAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:01Z",
            lastProgressAt: "2026-01-01T00:00:01Z",
            completedAt: pair.1 == .completed ? "2026-01-01T00:00:01Z" : nil,
            durationMs: pair.1 == .completed ? 1_000 : nil,
            progressSequence: pair.1 == .completed ? 2 : 1
        )
    }
    let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
    let tag = ChatTranscriptProjectionTag(
        snapshot: snapshot,
        presentationGeneration: 1,
        canonicalGeneration: 1,
        timelineGeneration: timelineGeneration
    )
    return InstalledChatTranscript(
        tag: tag,
        timeline: candidate.timeline,
        runtimeItems: candidate.runtimeItems,
        sourceWindow: .init(snapshot: snapshot)
    )
}

@MainActor
private final class Counter {
    var value = 0
}

@MainActor
private final class ResultRecorder {
    private(set) var values: [PerformanceResult] = []
    private var waiter: CheckedContinuation<Void, Never>?

    func record(_ value: PerformanceResult) {
        values.append(value)
        waiter?.resume()
        waiter = nil
    }

    func waitForValue() async {
        guard values.isEmpty else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

@MainActor
private final class ManualViewportFrameScheduler {
    private struct Waiter {
        let target: Int
        let continuation: CheckedContinuation<Void, Never>
    }
    private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var waiters: [Waiter] = []
    private var nextID = 0
    private(set) var requestCount = 0

    lazy var scheduler = DisplayFrameScheduler { [weak self] in
        guard let self else { throw CancellationError() }
        try await self.wait()
    }

    private func wait() async throws {
        let id = nextID
        nextID &+= 1
        requestCount &+= 1
        let ready = waiters.filter { $0.target <= requestCount }
        waiters.removeAll { $0.target <= requestCount }
        ready.forEach { $0.continuation.resume() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { continuations[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor in
                self.continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    func waitForRequest(count: Int) async {
        guard requestCount < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append(.init(target: count, continuation: continuation))
        }
    }

    func releaseNext() {
        guard let id = continuations.keys.min(),
              let continuation = continuations.removeValue(forKey: id) else { return }
        continuation.resume()
    }
}
