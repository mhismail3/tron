import SwiftUI
import Testing
@testable import TronMobile

@MainActor
@Suite("Chat scroll coordinator")
struct ChatScrollCoordinatorTests {
    private let bottom = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_000, containerHeight: 400)
    private let away = ChatTranscriptGeometry(offsetY: 300, contentHeight: 1_000, containerHeight: 400)

    @Test("pinned streaming growth coalesces to one command per displayed frame")
    func pinnedGrowthCoalesces() async throws {
        try await withTestWatchdog { @MainActor in
            let frames = ManualScrollFrameScheduler()
            let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
            let first = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_080, containerHeight: 400)
            let second = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_160, containerHeight: 400)
            coordinator.geometryChanged(previous: bottom, current: first)
            coordinator.geometryChanged(previous: first, current: second)
            await frames.waitForRequest(count: 1)
            #expect(coordinator.command == nil)
            frames.releaseNext()
            let command = try await coordinator.hostedNextCommand()
            #expect(command.destination == .tail)
            #expect(frames.requestCount == 1)
        }
    }

    @Test("growth arriving before an earlier tail command settles remains logically pinned")
    func continuousGrowthWhileSettling() async throws {
        try await withTestWatchdog { @MainActor in
            let frames = ManualScrollFrameScheduler()
            let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
            let first = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_120, containerHeight: 400)
            coordinator.geometryChanged(previous: bottom, current: first)
            await frames.waitForRequest(count: 1)
            frames.releaseNext()
            let firstCommand = try await coordinator.hostedNextCommand()
            coordinator.commandApplied(firstCommand)

            let second = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_200, containerHeight: 400)
            coordinator.geometryChanged(previous: first, current: second)
            await frames.waitForRequest(count: 2)
            frames.releaseNext()
            let secondCommand = try await coordinator.hostedNextCommand()
            #expect(secondCommand.destination == .tail)
            #expect(!coordinator.userScrolledAway)
        }
    }

    @Test("growth inside practical bottom tolerance emits no command")
    func noWriteInsideTolerance() async throws {
        let frames = ManualScrollFrameScheduler()
        let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
        let near = ChatTranscriptGeometry(offsetY: 675, contentHeight: 1_080, containerHeight: 400)
        coordinator.geometryChanged(previous: bottom, current: near)
        #expect(frames.requestCount == 0)
        #expect(coordinator.command?.destination == .releaseBinding)
    }

    @Test("geometry and native ownership callback permutations both detach")
    func callbackOrdering() {
        let nativeFirst = ChatScrollCoordinator()
        nativeFirst.scrollPositionChanged(isPositionedByUser: true)
        nativeFirst.geometryChanged(previous: bottom, current: away)
        nativeFirst.scrollPhaseChanged(from: .interacting, to: .idle, finalGeometry: away)
        #expect(nativeFirst.userScrolledAway)

        let geometryFirst = ChatScrollCoordinator()
        geometryFirst.geometryChanged(previous: bottom, current: away)
        geometryFirst.scrollPositionChanged(isPositionedByUser: true)
        #expect(geometryFirst.userScrolledAway)
    }

    @Test("geometry-first detachment consumes direct return through later viewport settlement")
    func geometryFirstDetachmentConsumesDirectReturn() {
        let coordinator = ChatScrollCoordinator()
        coordinator.geometryChanged(previous: bottom, current: away)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        #expect(coordinator.userScrolledAway)

        let expanded = ChatTranscriptGeometry(
            offsetY: 300,
            contentHeight: 1_000,
            containerHeight: 700
        )
        coordinator.viewportChanged(previous: away, current: expanded)
        coordinator.geometryChanged(previous: expanded, current: expanded)
        coordinator.scrollPhaseChanged(from: .idle, to: .idle, finalGeometry: expanded)
        #expect(coordinator.userScrolledAway)
        #expect(!coordinator.isAtBottom)
        #expect(coordinator.command == nil)
    }

    @Test("geometry-first manual return to tail immediately clears catch-up state")
    func geometryFirstManualReturnClearsCatchUp() {
        let coordinator = detachedCoordinator(at: away, withUnread: true)
        #expect(coordinator.shouldShowCatchUpButton)
        #expect(coordinator.tailSettlementGeneration == 0)

        coordinator.geometryChanged(previous: away, current: bottom)
        #expect(coordinator.shouldShowCatchUpButton)

        coordinator.scrollPositionChanged(isPositionedByUser: true)
        #expect(!coordinator.shouldShowCatchUpButton)
        #expect(!coordinator.userScrolledAway)
        #expect(!coordinator.hasUnreadContent)
        #expect(coordinator.isAtBottom)
        #expect(coordinator.tailSettlementGeneration == 1)
        #expect(coordinator.command?.destination == .releaseBinding)
    }

    @Test("native visible edge admits manual tail despite stale inset arithmetic")
    func nativeVisibleEdgeAdmitsManualTail() {
        let coordinator = detachedCoordinator(at: away, withUnread: true)
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: away)
        let visibleTail = ChatTranscriptGeometry(
            offsetY: 400,
            contentHeight: 1_000,
            containerHeight: 400,
            bottomInset: 200,
            visibleBottomY: 1_200
        )
        coordinator.geometryChanged(previous: away, current: visibleTail)
        coordinator.scrollPhaseChanged(
            from: .interacting,
            to: .idle,
            finalGeometry: visibleTail
        )

        #expect(!coordinator.shouldShowCatchUpButton)
        #expect(!coordinator.hasUnreadContent)
        #expect(coordinator.isAtBottom)
        #expect(coordinator.command?.destination == .releaseBinding)
    }

    @Test("manual return to tail remains pinned through keyboard viewport contraction")
    func manualReturnThenKeyboardFollowsTail() async throws {
        try await withTestWatchdog { @MainActor in
            let frames = ManualScrollFrameScheduler()
            let coordinator = detachedCoordinator(at: away, withUnread: true, frames: frames)
            coordinator.geometryChanged(previous: away, current: bottom)
            coordinator.scrollPositionChanged(isPositionedByUser: true)
            if let release = coordinator.command { coordinator.commandApplied(release) }

            coordinator.composerViewportTransitionBegan()
            let keyboard = ChatTranscriptGeometry(
                offsetY: 600,
                contentHeight: 1_000,
                containerHeight: 300,
                bottomInset: 100
            )
            coordinator.viewportChanged(previous: bottom, current: keyboard)
            await frames.waitForRequest(count: 1)
            frames.releaseNext()

            let command = try await coordinator.hostedNextCommand()
            #expect(command.destination == .tail)
            #expect(command.origin == .automaticFollow)
            #expect(!coordinator.shouldShowCatchUpButton)
        }
    }

    @Test("direct mixed viewport geometry return to tail clears catch-up")
    func mixedViewportManualReturnClearsCatchUp() {
        let coordinator = detachedCoordinator(at: away, withUnread: true)
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: away)
        let intermediateViewport = ChatTranscriptGeometry(
            offsetY: 300,
            contentHeight: 1_000,
            containerHeight: 350
        )
        coordinator.viewportChanged(previous: away, current: intermediateViewport)
        #expect(coordinator.shouldShowCatchUpButton)

        // SwiftUI may coalesce the final scroll geometry into the idle phase.
        let mixedBottom = ChatTranscriptGeometry(
            offsetY: 700,
            contentHeight: 1_000,
            containerHeight: 300
        )
        coordinator.scrollPhaseChanged(
            from: .interacting,
            to: .idle,
            finalGeometry: mixedBottom
        )

        #expect(!coordinator.shouldShowCatchUpButton)
        #expect(!coordinator.hasUnreadContent)
        #expect(coordinator.isAtBottom)
    }

    @Test("active keyboard viewport settlement without content motion preserves detachment")
    func activeKeyboardViewportDoesNotRepin() {
        let coordinator = detachedCoordinator(at: away, withUnread: true)
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: away)
        let expandedToBoundary = ChatTranscriptGeometry(
            offsetY: 300,
            contentHeight: 1_000,
            containerHeight: 700
        )
        coordinator.viewportChanged(previous: away, current: expandedToBoundary)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        let streamedWithinBoundary = ChatTranscriptGeometry(
            offsetY: 300,
            contentHeight: 1_005,
            containerHeight: 700
        )
        coordinator.geometryChanged(
            previous: expandedToBoundary,
            current: streamedWithinBoundary
        )
        #expect(coordinator.shouldShowCatchUpButton)
        #expect(coordinator.hasUnreadContent)
        let measuredReturn = ChatTranscriptGeometry(
            offsetY: 305,
            contentHeight: 1_005,
            containerHeight: 700
        )
        coordinator.scrollPhaseChanged(
            from: .interacting,
            to: .idle,
            finalGeometry: measuredReturn
        )

        #expect(!coordinator.shouldShowCatchUpButton)
        #expect(!coordinator.hasUnreadContent)
        #expect(coordinator.isAtBottom)

        let lateNative = detachedCoordinator(at: away, withUnread: true)
        lateNative.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: away)
        lateNative.viewportChanged(previous: away, current: expandedToBoundary)
        lateNative.scrollPhaseChanged(
            from: .interacting,
            to: .idle,
            finalGeometry: expandedToBoundary
        )
        lateNative.scrollPositionChanged(isPositionedByUser: true)
        lateNative.geometryChanged(
            previous: expandedToBoundary,
            current: streamedWithinBoundary
        )
        #expect(lateNative.shouldShowCatchUpButton)
        #expect(lateNative.hasUnreadContent)
        #expect(lateNative.command == nil)
    }

    @Test("native positioning after released binding emits a new typed release at tail")
    func nativePositioningRearmsBindingRelease() {
        let coordinator = ChatScrollCoordinator()
        coordinator.geometryChanged(previous: bottom, current: bottom)
        let firstRelease = coordinator.command!
        #expect(firstRelease.destination == .releaseBinding)
        coordinator.commandApplied(firstRelease)
        #expect(coordinator.command == nil)

        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(previous: bottom, current: bottom)
        #expect(coordinator.command?.destination == .releaseBinding)
        #expect(coordinator.command?.origin == .binding)
    }

    @Test("detached stream viewport composer and image-like settlement emit zero writes")
    func detachedLayoutNeverWrites() {
        let frames = ManualScrollFrameScheduler()
        let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(previous: bottom, current: away)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle, finalGeometry: away)
        let stream = ChatTranscriptGeometry(offsetY: 300, contentHeight: 1_080, containerHeight: 400)
        coordinator.geometryChanged(previous: away, current: stream)
        let composer = ChatTranscriptGeometry(offsetY: 300, contentHeight: 1_080, containerHeight: 320, bottomInset: 80)
        coordinator.viewportChanged(previous: stream, current: composer)
        let image = ChatTranscriptGeometry(offsetY: 300, contentHeight: 1_240, containerHeight: 320, bottomInset: 80)
        coordinator.geometryChanged(previous: composer, current: image)
        coordinator.composerViewportTransitionBegan()
        coordinator.semanticResponseArrived()
        #expect(coordinator.userScrolledAway)
        #expect(coordinator.shouldShowCatchUpButton)
        #expect(coordinator.hasUnreadContent)
        #expect(frames.requestCount == 0)
        #expect(coordinator.command == nil)
    }

    @Test("viewport expansion and later unattributed boundary settlement preserve detachment")
    func viewportExpansionPreservesDetachment() {
        let coordinator = ChatScrollCoordinator()
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(previous: bottom, current: away)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle, finalGeometry: away)
        coordinator.semanticResponseArrived()

        let expanded = ChatTranscriptGeometry(
            offsetY: 300,
            contentHeight: 1_000,
            containerHeight: 700
        )
        coordinator.viewportChanged(previous: away, current: expanded)
        coordinator.geometryChanged(previous: expanded, current: expanded)
        coordinator.scrollPhaseChanged(from: .idle, to: .idle, finalGeometry: expanded)
        #expect(coordinator.userScrolledAway)
        #expect(coordinator.hasUnreadContent)
        #expect(!coordinator.isAtBottom)
        #expect(coordinator.command == nil)

        let taller = ChatTranscriptGeometry(
            offsetY: 300,
            contentHeight: 1_200,
            containerHeight: 700
        )
        coordinator.geometryChanged(previous: expanded, current: taller)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        let manuallyReturned = ChatTranscriptGeometry(
            offsetY: 500,
            contentHeight: 1_200,
            containerHeight: 700
        )
        coordinator.geometryChanged(previous: taller, current: manuallyReturned)
        #expect(!coordinator.userScrolledAway)
        #expect(!coordinator.hasUnreadContent)
        #expect(coordinator.command?.destination == .releaseBinding)
    }

    @Test("native ownership end and accessibility phase preserve one-shot direct tail return")
    func directTailReturnAdmission() {
        let native = detachedCoordinator(at: away, withUnread: false)
        native.scrollPositionChanged(isPositionedByUser: true)
        native.scrollPositionChanged(isPositionedByUser: false)
        native.geometryChanged(previous: away, current: bottom)
        #expect(!native.userScrolledAway)
        #expect(native.command?.destination == .releaseBinding)

        let accessibility = detachedCoordinator(at: away, withUnread: false)
        accessibility.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: away)
        accessibility.scrollPhaseChanged(from: .interacting, to: .idle, finalGeometry: bottom)
        #expect(!accessibility.userScrolledAway)
        #expect(accessibility.command?.destination == .releaseBinding)
    }

    @Test("direct interaction cancels a pending automatic frame command")
    func interactionCancelsPendingFollow() async throws {
        try await withTestWatchdog { @MainActor in
            let frames = ManualScrollFrameScheduler()
            let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
            let grown = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_100, containerHeight: 400)
            coordinator.geometryChanged(previous: bottom, current: grown)
            await frames.waitForRequest(count: 1)
            coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: grown)
            frames.releaseNext()
            #expect(coordinator.command == nil)
            #expect(coordinator.isUserInteracting)
        }
    }

    @Test("long catch-up stages and finishes on separate display frames")
    func catchUpFrameSeparation() async throws {
        try await withTestWatchdog { @MainActor in
            let frames = ManualScrollFrameScheduler()
            let coordinator = ChatScrollCoordinator(frameScheduler: frames.scheduler)
            let farAway = ChatTranscriptGeometry(offsetY: 0, contentHeight: 1_000, containerHeight: 400)
            coordinator.geometryChanged(previous: farAway, current: farAway)
            coordinator.requestCatchUp(reduceMotion: false)
            let staged = try await coordinator.hostedNextCommand()
            guard case .offsetY = staged.destination else {
                Issue.record("expected staged point command")
                return
            }
            #expect(frames.requestCount == 0)
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
        let farAway = ChatTranscriptGeometry(offsetY: 0, contentHeight: 1_000, containerHeight: 400)
        let coordinator = detachedCoordinator(at: farAway, withUnread: false)
        coordinator.requestCatchUp(reduceMotion: false)
        #expect(coordinator.command?.destination == .offsetY(520))
        #expect(!coordinator.hasUnreadContent)
        coordinator.semanticResponseArrived()
        #expect(coordinator.hasUnreadContent)
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: farAway)
        #expect(coordinator.userScrolledAway)
        #expect(coordinator.hasUnreadContent)
        #expect(coordinator.command == nil)
    }

    @Test("response during final catch-up command survives interruption as unread")
    func finalCatchUpInterruption() {
        let coordinator = detachedCoordinator(at: away, withUnread: false)
        coordinator.requestCatchUp(reduceMotion: false)
        #expect(coordinator.command?.destination == .tail)
        coordinator.semanticResponseArrived()
        #expect(coordinator.hasUnreadContent)
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: away)
        #expect(coordinator.userScrolledAway)
        #expect(coordinator.hasUnreadContent)
        #expect(coordinator.command == nil)
    }

    @Test("interaction during catch-up physical settlement restores detachment; exact boundary settles")
    func settlingCatchUpInterruptionAndSuccess() {
        let interrupted = detachedCoordinator(at: away, withUnread: false)
        interrupted.requestCatchUp(reduceMotion: true)
        #expect(interrupted.tailSettlementGeneration == 0)
        let command = interrupted.command!
        interrupted.commandApplied(command)
        interrupted.semanticResponseArrived()
        #expect(interrupted.hasUnreadContent)
        interrupted.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: away)
        #expect(interrupted.userScrolledAway)
        #expect(interrupted.hasUnreadContent)
        #expect(interrupted.tailSettlementGeneration == 0)
        #expect(interrupted.command == nil)

        let settled = detachedCoordinator(at: away)
        settled.requestCatchUp(reduceMotion: true)
        #expect(settled.hasUnreadContent)
        #expect(settled.tailSettlementGeneration == 0)
        settled.commandApplied(settled.command!)
        settled.semanticResponseArrived()
        #expect(settled.hasUnreadContent)
        settled.geometryChanged(previous: away, current: bottom)
        #expect(!settled.userScrolledAway)
        #expect(!settled.hasUnreadContent)
        #expect(settled.tailSettlementGeneration == 1)
        #expect(settled.command?.destination == .releaseBinding)
    }

    @Test("presentation reset revokes an unacknowledged command")
    func presentationResetRevokesCommand() {
        let coordinator = ChatScrollCoordinator()
        coordinator.resetForPresentation(1)
        coordinator.requestOpeningTail()
        let stale = coordinator.command
        #expect(stale?.presentation == 1)
        coordinator.resetForPresentation(2)
        let current = coordinator.command
        if let stale { coordinator.commandApplied(stale) }
        #expect(current?.destination == .resetToBottom)
        #expect(coordinator.command == current)
    }

    @Test("semantic frame projection is count bounded")
    func semanticFramesAreBounded() {
        let coordinator = ChatScrollCoordinator()
        for index in 0..<300 {
            coordinator.semanticFrameChanged(
                renderedID: "row-\(index)",
                layoutEpoch: coordinator.layoutEpoch,
                frame: CGRect(x: 0, y: index, width: 100, height: 40)
            )
        }
        #expect(coordinator.hostedSemanticFrameCount == 256)
    }

    @Test("Reduce Motion catch-up is one nonanimated tail command")
    func reduceMotionCatchUp() async throws {
        let coordinator = ChatScrollCoordinator()
        coordinator.geometryChanged(previous: away, current: away)
        coordinator.requestCatchUp(reduceMotion: true)
        let command = try await coordinator.hostedNextCommand()
        #expect(command.destination == .tail)
        #expect(command.animation == .disabled)
    }

    @Test("missing measured anchor discards without starting page load")
    func missingAnchorDoesNotLoad() {
        let coordinator = ChatScrollCoordinator()
        let results = ScrollResultRecorder()
        let loads = ScrollCounter()
        let began = coordinator.beginPrepend(
            anchor: nil,
            load: { loads.value &+= 1; return nil },
            completion: { results.record($0) }
        )
        #expect(!began)
        #expect(loads.value == 0)
        #expect(results.values == [.discarded])
    }

    @Test("repeat prepend cannot cancel useful work")
    func prependOwnership() {
        let coordinator = ChatScrollCoordinator()
        coordinator.geometryChanged(previous: away, current: away)
        coordinator.semanticFrameChanged(
            renderedID: "row",
            layoutEpoch: coordinator.layoutEpoch,
            frame: CGRect(x: 0, y: 20, width: 100, height: 40)
        )
        let results = ScrollResultRecorder()
        let anchor = ChatSemanticAnchor(semanticID: "semantic", renderedID: "row", layoutEpoch: coordinator.layoutEpoch, viewportOffsetY: 20)
        let began = coordinator.beginPrepend(
            anchor: anchor,
            load: { nil },
            completion: { results.record($0) }
        )
        #expect(began)
        let repeated = coordinator.beginPrepend(anchor: anchor, load: { nil }, completion: { _ in })
        #expect(!repeated)
        coordinator.cancel()
        #expect(results.values == [.cancelled])
    }

    @Test("prepend passively waits for newer exact-epoch semantic samples after every correction")
    func prependEpochAndLateCorrection() async throws {
        try await withTestWatchdog { @MainActor in
            let coordinator = ChatScrollCoordinator()
            coordinator.geometryChanged(previous: away, current: away)
            coordinator.semanticFrameChanged(
                renderedID: "old-row",
                layoutEpoch: coordinator.layoutEpoch,
                frame: CGRect(x: 0, y: 20, width: 100, height: 40)
            )
            let anchor = ChatSemanticAnchor(
                semanticID: "semantic",
                renderedID: "old-row",
                layoutEpoch: coordinator.layoutEpoch,
                viewportOffsetY: 20
            )
            let results = ScrollResultRecorder()
            let oldEpoch = coordinator.layoutEpoch
            let began = coordinator.beginPrepend(anchor: anchor, load: {
                let installedLayout = coordinator.beginInstalledPageLayoutEpoch()
                return ChatPrependPage(
                    renderedAnchorID: "new-row",
                    installedLayout: installedLayout
                )
            }, completion: { results.record($0) })
            #expect(began)

            try await coordinator.hostedWaitForPrependSemanticSample()
            #expect(coordinator.isWaitingForPrependSemanticFrame)
            coordinator.semanticFrameChanged(
                renderedID: "new-row",
                layoutEpoch: oldEpoch,
                frame: CGRect(x: 0, y: 220, width: 100, height: 40)
            )
            #expect(coordinator.command == nil)

            let installedEpoch = coordinator.layoutEpoch
            let unchangedFrame = CGRect(x: 0, y: 220, width: 100, height: 40)
            #expect(ChatSemanticFrameObservation(layoutEpoch: oldEpoch, frame: unchangedFrame)
                != ChatSemanticFrameObservation(layoutEpoch: installedEpoch, frame: unchangedFrame))
            coordinator.semanticFrameChanged(
                renderedID: "new-row",
                layoutEpoch: installedEpoch,
                frame: unchangedFrame
            )
            let first = try await coordinator.hostedNextCommand()
            #expect(first.destination == .offsetY(500))
            coordinator.commandApplied(first)
            #expect(coordinator.command == nil)
            #expect(coordinator.isWaitingForPrependSemanticFrame)

            coordinator.geometryChanged(
                previous: away,
                current: ChatTranscriptGeometry(offsetY: 500, contentHeight: 1_000, containerHeight: 400)
            )
            coordinator.semanticFrameChanged(
                renderedID: "new-row",
                layoutEpoch: oldEpoch,
                frame: CGRect(x: 0, y: 20, width: 100, height: 40)
            )
            #expect(coordinator.command == nil)
            coordinator.semanticFrameChanged(
                renderedID: "new-row",
                layoutEpoch: installedEpoch,
                frame: CGRect(x: 0, y: 25, width: 100, height: 40)
            )
            let late = try await coordinator.hostedNextCommand()
            #expect(late.destination == .offsetY(505))
            coordinator.commandApplied(late)
            #expect(coordinator.command == nil)
            #expect(coordinator.isWaitingForPrependSemanticFrame)

            coordinator.geometryChanged(
                previous: ChatTranscriptGeometry(offsetY: 500, contentHeight: 1_000, containerHeight: 400),
                current: ChatTranscriptGeometry(offsetY: 505, contentHeight: 1_000, containerHeight: 400)
            )
            coordinator.semanticFrameChanged(
                renderedID: "new-row",
                layoutEpoch: installedEpoch,
                frame: CGRect(x: 0, y: 20.5, width: 100, height: 40)
            )
            try await results.waitForValue()
            #expect(results.values == [.success])
        }
    }

    @Test("prepend admits an exact sample that arrives before the page continuation returns")
    func prependSampleBeforePageReturn() async throws {
        try await withTestWatchdog { @MainActor in
            let coordinator = ChatScrollCoordinator()
            coordinator.geometryChanged(previous: away, current: away)
            coordinator.semanticFrameChanged(
                renderedID: "old-row",
                layoutEpoch: coordinator.layoutEpoch,
                frame: CGRect(x: 0, y: 20, width: 100, height: 40)
            )
            let anchor = ChatSemanticAnchor(
                semanticID: "semantic",
                renderedID: "old-row",
                layoutEpoch: coordinator.layoutEpoch,
                viewportOffsetY: 20
            )
            let began = coordinator.beginPrepend(anchor: anchor, load: {
                let installedLayout = coordinator.beginInstalledPageLayoutEpoch()
                coordinator.semanticFrameChanged(
                    renderedID: "new-row",
                    layoutEpoch: installedLayout.value,
                    frame: CGRect(x: 0, y: 220, width: 100, height: 40)
                )
                return ChatPrependPage(
                    renderedAnchorID: "new-row",
                    installedLayout: installedLayout
                )
            }, completion: { _ in })
            #expect(began)

            let command = try await coordinator.hostedNextCommand()
            #expect(command.destination == .offsetY(500))
            coordinator.cancel()
        }
    }

    @Test("semantic anchor correction preserves viewport offset without total-height input")
    func semanticAnchorCorrection() {
        #expect(ChatScrollCoordinator.prependCorrectionOffset(
            currentOffsetY: 300,
            capturedViewportOffsetY: 20,
            installedFrameMinY: 220
        ) == 500)
    }

    @Test("gesture interruption synchronously suppresses pending prepend commands")
    func gestureInterruptsPrepend() {
        let coordinator = ChatScrollCoordinator()
        coordinator.geometryChanged(previous: away, current: away)
        coordinator.semanticFrameChanged(
            renderedID: "row",
            layoutEpoch: coordinator.layoutEpoch,
            frame: CGRect(x: 0, y: 10, width: 100, height: 40)
        )
        let completed = ScrollResultRecorder()
        let began = coordinator.beginPrepend(
            anchor: ChatSemanticAnchor(semanticID: "semantic", renderedID: "row", layoutEpoch: coordinator.layoutEpoch, viewportOffsetY: 10),
            load: { nil },
            completion: { completed.record($0) }
        )
        #expect(began)
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: away)
        #expect(coordinator.command == nil)
        coordinator.cancel()
        #expect(completed.values == [.cancelled])
    }

    private func detachedCoordinator(
        at geometry: ChatTranscriptGeometry,
        withUnread: Bool = true,
        frames: ManualScrollFrameScheduler? = nil
    ) -> ChatScrollCoordinator {
        let coordinator = ChatScrollCoordinator(frameScheduler: frames?.scheduler ?? .displayLink)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(previous: bottom, current: geometry)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle, finalGeometry: geometry)
        if withUnread { coordinator.semanticResponseArrived() }
        return coordinator
    }
}

@MainActor
private final class ScrollCounter {
    var value = 0
}

@MainActor
private final class ScrollResultRecorder {
    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<Void, Error>
    }
    private(set) var values: [PerformanceResult] = []
    private var waiters: [Waiter] = []
    private var nextWaiterID = 0

    func record(_ value: PerformanceResult) {
        values.append(value)
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.continuation.resume() }
    }

    func waitForValue() async throws {
        guard values.isEmpty else { return }
        let id = nextWaiterID
        nextWaiterID &+= 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append(.init(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id: id) }
        }
    }

    private func cancel(id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

@MainActor
private final class ManualScrollFrameScheduler {
    private struct RequestWaiter {
        let id: Int
        let targetCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var nextContinuationID = 0
    private var requestWaiters: [RequestWaiter] = []
    private var nextRequestWaiterID = 0
    private(set) var requestCount = 0

    lazy var scheduler = DisplayFrameScheduler { [weak self] in
        guard let self else { throw CancellationError() }
        try await self.wait()
    }

    private func wait() async throws {
        let id = nextContinuationID
        nextContinuationID &+= 1
        requestCount &+= 1
        let ready = requestWaiters.filter { $0.targetCount <= requestCount }
        requestWaiters.removeAll { $0.targetCount <= requestCount }
        ready.forEach { $0.continuation.resume() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { continuations[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id: id) }
        }
    }

    func waitForRequest(count: Int) async {
        guard requestCount < count else { return }
        let id = nextRequestWaiterID
        nextRequestWaiterID &+= 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() }
                else {
                    requestWaiters.append(.init(
                        id: id,
                        targetCount: count,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelRequestWaiter(id: id) }
        }
    }

    func releaseNext() {
        guard let id = continuations.keys.min(), let continuation = continuations.removeValue(forKey: id) else { return }
        continuation.resume()
    }

    private func cancel(id: Int) {
        continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func cancelRequestWaiter(id: Int) {
        guard let index = requestWaiters.firstIndex(where: { $0.id == id }) else { return }
        requestWaiters.remove(at: index).continuation.resume()
    }
}
